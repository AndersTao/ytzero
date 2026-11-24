import { useState } from "react";

/*
 * Subscriptions in the sidebar can be folded into one menu item, so the
 * channel list does not take up the side. Remembered in this browser.
 */
const KEY = "sidebar_subs_collapsed";

function stored(): boolean {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

export function useSubsCollapsed(): [boolean, () => void] {
  const [collapsed, setCollapsed] = useState(stored);
  const toggle = () => {
    const next = !collapsed;
    setCollapsed(next);
    try {
      localStorage.setItem(KEY, next ? "1" : "0");
    } catch {
      // Not remembered; it still folds for now.
    }
  };
  return [collapsed, toggle];
}
