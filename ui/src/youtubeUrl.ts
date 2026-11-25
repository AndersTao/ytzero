export const YT_NO_REDIRECT_MARKER = "ytNoRedirect";
const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;

export function youtubeVideoId(value: string): string | null {
  try {
    const url = new URL(value.startsWith("www.") ? `https://${value}` : value);
    const host = url.hostname.toLowerCase().replace(/^www\./, "");
    let id: string | null | undefined;
    if (host === "youtu.be") id = url.pathname.split("/").filter(Boolean)[0];
    else if (host === "youtube.com" || host.endsWith(".youtube.com")) {
      if (url.pathname === "/watch") id = url.searchParams.get("v");
      else if (/^\/(?:shorts|live|embed)\//.test(url.pathname)) id = url.pathname.split("/")[2];
    } else if (host === "youtube-nocookie.com" || host.endsWith(".youtube-nocookie.com")) {
      if (url.pathname.startsWith("/embed/")) id = url.pathname.split("/")[2];
    }
    return id && VIDEO_ID_PATTERN.test(id) ? id : null;
  } catch {
    return null;
  }
}

export function markYouTubeUrl(value: string): string {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase().replace(/^www\./, "");
    const isYouTube = host === "youtu.be"
      || host === "youtube.com"
      || host.endsWith(".youtube.com")
      || host === "youtube-nocookie.com"
      || host.endsWith(".youtube-nocookie.com");
    if (!isYouTube || (url.protocol !== "http:" && url.protocol !== "https:")) return value;
    const fragments = url.hash.slice(1).split("&").filter(Boolean).filter((part) => part !== YT_NO_REDIRECT_MARKER);
    fragments.push(YT_NO_REDIRECT_MARKER);
    url.hash = fragments.join("&");
    return url.toString();
  } catch {
    return value;
  }
}

/*
 * The browser extension adds this fragment when it sends a video here from
 * YouTube (an automatic redirect or its YT Zero button). The watch page then
 * offers a way back, for that video only, for the rest of the tab's session.
 */
export const YT_REDIRECTED_MARKER = "ytRedirected";
const REDIRECTED_VIDEOS_KEY = "ytzero.redirectedFromYouTube";
const REDIRECTED_VIDEOS_LIMIT = 50;

type SessionStore = Pick<Storage, "getItem" | "setItem">;

function tabSession(): SessionStore | null {
  try { return window.sessionStorage; } catch { return null; }
}

export function hasYouTubeRedirectMarker(hash: string): boolean {
  return hash.replace(/^#/, "").split("&").includes(YT_REDIRECTED_MARKER);
}

/** The fragment without the redirect marker, "#" included when anything is left. */
export function withoutYouTubeRedirectMarker(hash: string): string {
  const rest = hash.replace(/^#/, "").split("&").filter((part) => part && part !== YT_REDIRECTED_MARKER);
  return rest.length ? `#${rest.join("&")}` : "";
}

/** Whether this video came here from YouTube in this tab; records it when the address says so. */
export function noteYouTubeRedirect(hash: string, videoId: string | null | undefined, store: SessionStore | null = tabSession()): boolean {
  if (!videoId) return false;
  let ids: string[] = [];
  try {
    const stored: unknown = JSON.parse(store?.getItem(REDIRECTED_VIDEOS_KEY) ?? "[]");
    if (Array.isArray(stored)) ids = stored.filter((value): value is string => typeof value === "string");
  } catch {}
  if (!hasYouTubeRedirectMarker(hash)) return ids.includes(videoId);
  if (!ids.includes(videoId)) {
    try { store?.setItem(REDIRECTED_VIDEOS_KEY, JSON.stringify([...ids, videoId].slice(-REDIRECTED_VIDEOS_LIMIT))); } catch {}
  }
  return true;
}

/** The video on YouTube at the position reached, marked so the extension lets it through. */
export function youTubeReturnUrl(videoId: string, seconds: number): string {
  const at = Number.isFinite(seconds) && seconds >= 1 ? Math.floor(seconds) : 0;
  return markYouTubeUrl(`https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}${at ? `&t=${at}s` : ""}`);
}
