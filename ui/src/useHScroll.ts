import { useCallback, useRef, useState } from "react";

/** A horizontal card row: a callback ref plus whether to shade either edge. */
export function useHScroll() {
  const [shadowLeft, setShadowLeft] = useState(false);
  const [shadowRight, setShadowRight] = useState(false);
  const cleanupRef = useRef<(() => void) | null>(null);

  const ref = useCallback((el: HTMLDivElement | null) => {
    cleanupRef.current?.();
    cleanupRef.current = null;
    if (!el) return;
    const update = () => {
      setShadowLeft(el.scrollLeft > 4);
      setShadowRight(el.scrollLeft < el.scrollWidth - el.clientWidth - 4);
    };
    update();
    el.addEventListener("scroll", update, { passive: true });
    const ro = new ResizeObserver(update);
    ro.observe(el);
    const mo = new MutationObserver(update);
    mo.observe(el, { childList: true, subtree: false });
    cleanupRef.current = () => {
      el.removeEventListener("scroll", update);
      ro.disconnect();
      mo.disconnect();
    };
  }, []);

  return { ref, shadowLeft, shadowRight };
}
