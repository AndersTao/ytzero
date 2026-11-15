/**
 * TV mode: move focus with the remote's arrow keys.
 *
 * The web client is built for a mouse and touch. On a television (an LG webOS
 * app, a TV browser) the remote sends arrow keys, and a page without spatial
 * navigation leaves them with nowhere to go. In TV mode an arrow moves focus to
 * the nearest focusable element in that direction and scrolls it into view; OK
 * activates it. On the watch page Left/Right stay with the player (seek), and
 * Up/Down leave it.
 */

export type Direction = "up" | "down" | "left" | "right";

export interface Box {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

const TV_MODE_KEY = "ytzero.tvMode";

const KEY_DIRECTIONS: Record<string, Direction> = {
  ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right",
  Up: "up", Down: "down", Left: "left", Right: "right",
};
const KEYCODE_DIRECTIONS: Record<number, Direction> = { 37: "left", 38: "up", 39: "right", 40: "down" };

const FOCUSABLE = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type=hidden])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
  "[role='button']",
  "[role='link']",
  "[role='menuitem']",
  "[role='menuitemradio']",
  "[role='menuitemcheckbox']",
  "[role='option']",
  "[role='tab']",
  "[contenteditable='true']",
].join(",");

/** Where the player owns Left/Right (seeking) while it, or nothing, has focus. */
const PLAYER_AREA = ".watch-player-shell, .cinema-player-wrap, .lp-root";
/** The players themselves (tabindex=-1), so Up/Down can come back to them. */
const PLAYER_TARGETS = ".watch-player-yt, .lp-video";

export function isTvUserAgent(userAgent: string): boolean {
  return /Web0S|webOS|NetCast|SMART-TV|SmartTV|Tizen|AFT[A-Z]|BRAVIA|HbbTV/i.test(userAgent);
}

export function keyDirection(event: Pick<KeyboardEvent, "key" | "keyCode">): Direction | null {
  return KEY_DIRECTIONS[event.key] ?? KEYCODE_DIRECTIONS[event.keyCode] ?? null;
}

const center = (box: Box) => ({ x: (box.left + box.right) / 2, y: (box.top + box.bottom) / 2 });
const gapBetween = (aStart: number, aEnd: number, bStart: number, bEnd: number) =>
  Math.max(0, bStart - aEnd, aStart - bEnd);

/**
 * The index of the best candidate in a direction, or -1.
 *
 * A candidate's centre must lie beyond the source's edge in that direction, so
 * a wide or narrow neighbour that merely overlaps it does not count. Among those,
 * the gap along the direction counts once and the sideways gap five times plus a
 * fixed step, so the next control in the same row or column wins over a closer one
 * in a neighbouring column; the centre offset only breaks ties between equally
 * aligned targets.
 */
export function pickNext(from: Box, candidates: readonly Box[], direction: Direction): number {
  const origin = center(from);
  let best = -1;
  let bestScore = Infinity;
  candidates.forEach((box, index) => {
    const target = center(box);
    let primary: number;
    let sideways: number;
    let offset: number;
    switch (direction) {
      case "down":
        if (target.y <= from.bottom) return;
        primary = Math.max(0, box.top - from.bottom);
        sideways = gapBetween(from.left, from.right, box.left, box.right);
        offset = Math.abs(target.x - origin.x);
        break;
      case "up":
        if (target.y >= from.top) return;
        primary = Math.max(0, from.top - box.bottom);
        sideways = gapBetween(from.left, from.right, box.left, box.right);
        offset = Math.abs(target.x - origin.x);
        break;
      case "right":
        if (target.x <= from.right) return;
        primary = Math.max(0, box.left - from.right);
        sideways = gapBetween(from.top, from.bottom, box.top, box.bottom);
        offset = Math.abs(target.y - origin.y);
        break;
      case "left":
        if (target.x >= from.left) return;
        primary = Math.max(0, from.left - box.right);
        sideways = gapBetween(from.top, from.bottom, box.top, box.bottom);
        offset = Math.abs(target.y - origin.y);
        break;
    }
    // Leaving the current row or column (sideways > 0) costs a fixed step on top.
    const score = primary + sideways * 5 + (sideways > 0 ? 60 : 0) + offset * 0.05;
    if (score < bestScore) {
      bestScore = score;
      best = index;
    }
  });
  return best;
}

function storedTvMode(): string | null {
  try { return window.localStorage.getItem(TV_MODE_KEY); } catch { return null; }
}

/**
 * TV mode is on for television user agents, and can be forced either way with
 * ?tv=1 / ?tv=0 (remembered on this device).
 */
export function resolveTvMode(): boolean {
  try {
    const param = new URLSearchParams(window.location.search).get("tv");
    if (param === "1" || param === "0") window.localStorage.setItem(TV_MODE_KEY, param);
  } catch {}
  const stored = storedTvMode();
  if (stored === "1") return true;
  if (stored === "0") return false;
  return isTvUserAgent(navigator.userAgent);
}

function isVisible(element: HTMLElement): boolean {
  const rect = element.getBoundingClientRect();
  if (rect.width < 2 || rect.height < 2) return false;
  if (element.closest("[inert], [aria-hidden='true']")) return false;
  const style = window.getComputedStyle(element);
  return style.visibility !== "hidden" && style.display !== "none";
}

function navigationScope(): ParentNode {
  const dialogs = document.querySelectorAll<HTMLElement>("[role='dialog'][aria-modal='true'], dialog[open]");
  return dialogs.length ? dialogs[dialogs.length - 1] : document;
}

function candidatesFor(active: Element | null): HTMLElement[] {
  return Array.from(navigationScope().querySelectorAll<HTMLElement>(`${FOCUSABLE},${PLAYER_TARGETS}`)).filter((element) =>
    element !== active
    && element.tagName !== "IFRAME"
    && !(active && (element.contains(active) || active.contains(element)))
    && isVisible(element));
}

function isTextField(element: Element): element is HTMLInputElement | HTMLTextAreaElement {
  if (element instanceof HTMLTextAreaElement) return true;
  if (!(element instanceof HTMLInputElement)) return false;
  return !["button", "checkbox", "radio", "range", "submit", "reset", "color", "file", "image"].includes(element.type);
}

/** Whether an arrow key belongs to the focused element itself (caret, slider). */
function elementKeepsKey(element: Element, direction: Direction): boolean {
  if ((element as HTMLElement).isContentEditable) return true;
  if (element instanceof HTMLInputElement && element.type === "range") return direction === "left" || direction === "right";
  if (isTextField(element)) {
    if (element instanceof HTMLTextAreaElement && (direction === "up" || direction === "down")) return true;
    if (direction === "up" || direction === "down") return false;
    try {
      const start = element.selectionStart ?? 0;
      const end = element.selectionEnd ?? 0;
      if (start !== end) return true;
      return direction === "left" ? start > 0 : end < element.value.length;
    } catch {
      return false; // inputs without a caret (email, number) throw on selectionStart
    }
  }
  return false;
}

function reducedMotion(): boolean {
  try { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch { return false; }
}

function focusAndReveal(element: HTMLElement): void {
  element.focus({ preventScroll: true });
  element.scrollIntoView({ block: "center", inline: "nearest", behavior: reducedMotion() ? "auto" : "smooth" });
}

function scrollPage(direction: Direction): void {
  if (direction !== "up" && direction !== "down") return;
  window.scrollBy({ top: (direction === "down" ? 1 : -1) * window.innerHeight * 0.6, behavior: reducedMotion() ? "auto" : "smooth" });
}

function handleArrow(event: KeyboardEvent, direction: Direction): void {
  const active = document.activeElement instanceof HTMLElement && document.activeElement !== document.body
    ? document.activeElement
    : null;

  if (active && elementKeepsKey(active, direction)) return;

  const inPlayer = !active || Boolean(active.closest(PLAYER_AREA));
  const onWatchPage = Boolean(document.querySelector(PLAYER_AREA));
  // Left/Right seek while the player (or nothing) has focus on the watch page.
  if (onWatchPage && inPlayer && (direction === "left" || direction === "right")) return;

  const candidates = candidatesFor(active);
  let from: Box;
  if (active) {
    from = active.getBoundingClientRect();
  } else {
    // Nothing focused yet: start from the top edge of the viewport so Down
    // lands on the first thing on screen.
    from = { left: 0, top: -2, right: window.innerWidth, bottom: -1 };
    if (direction === "up") from = { left: 0, top: window.innerHeight + 1, right: window.innerWidth, bottom: window.innerHeight + 2 };
  }
  const index = pickNext(from, candidates.map((element) => element.getBoundingClientRect()), direction);

  event.preventDefault();
  event.stopImmediatePropagation();
  if (index >= 0) focusAndReveal(candidates[index]);
  else scrollPage(direction);
}

function isNativelyActivated(element: HTMLElement): boolean {
  if (element instanceof HTMLButtonElement || element instanceof HTMLAnchorElement) return true;
  if (element instanceof HTMLInputElement || element instanceof HTMLSelectElement || element instanceof HTMLTextAreaElement) return true;
  return element.isContentEditable;
}

function onKeyDown(event: KeyboardEvent): void {
  if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
  const direction = keyDirection(event);
  if (direction) {
    handleArrow(event, direction);
    return;
  }
  // OK on the remote: activate custom controls (role=button, tabindex) the way
  // Enter already activates links and buttons.
  if (event.key === "Enter" || event.keyCode === 13) {
    const active = document.activeElement;
    if (active instanceof HTMLElement && active !== document.body && !isNativelyActivated(active)) {
      event.preventDefault();
      active.click();
    }
  }
}

let installed = false;

export function installTvNavigation(): void {
  if (installed || typeof window === "undefined") return;
  installed = true;
  document.documentElement.classList.add("tv-mode");
  // Capture phase, so the page's own arrow shortcuts (seek, volume) only see
  // the keys TV navigation leaves alone.
  window.addEventListener("keydown", onKeyDown, true);
}
