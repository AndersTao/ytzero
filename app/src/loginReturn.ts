/*
 * Where a sign-in goes back to. The login page passes the page it was shown
 * on, #fragment included: a TV's pairing code rides there, so a phone that
 * scanned the TV's QR code lands on the approval page again after SSO
 * instead of on Main. Only a page on this server is accepted.
 */
export const LOGIN_RETURN_COOKIE = "ytzero_login_return";

const BASE = "http://ytzero.invalid";

export function safeReturnPath(value: unknown): string {
  if (typeof value !== "string" || value.length > 2048) return "/";
  if (!value.startsWith("/") || value.startsWith("//") || value.includes("\\")) return "/";
  if (/[\u0000-\u001f\u007f]/.test(value)) return "/";
  try {
    const url = new URL(value, BASE);
    // Check what the parser made of it too: dot segments such as "/.//host"
    // normalize to "//host", which a browser would read as another server.
    const path = `${url.pathname}${url.search}${url.hash}`;
    if (url.origin !== BASE || !/^\/(?![/\\])/.test(path) || url.pathname.startsWith("/api/")) return "/";
    return path;
  } catch {
    return "/";
  }
}

export function loginReturnCookie(path: string): string {
  return `${LOGIN_RETURN_COOKIE}=${encodeURIComponent(path)}; Path=/; Max-Age=600; SameSite=Lax; HttpOnly`;
}

export function clearLoginReturnCookie(): string {
  return `${LOGIN_RETURN_COOKIE}=; Path=/; Max-Age=0; SameSite=Lax; HttpOnly`;
}
