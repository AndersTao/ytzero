/*
 * The page a sign-in returns to: the one the login page was shown on, with
 * its #fragment (a TV's pairing code rides there). The server checks it again.
 */
type Place = { pathname: string; search: string; hash: string };

export function loginReturnPath({ pathname, search, hash }: Place): string {
  const path = `${pathname}${search}${hash}`;
  if (!path.startsWith("/") || path.startsWith("//") || pathname === "/") return "/";
  return path;
}

export function oidcLoginHref(returnTo: string): string {
  return returnTo === "/" ? "/api/auth/oidc/login" : `/api/auth/oidc/login?return_to=${encodeURIComponent(returnTo)}`;
}

// Going "back" to the same address with a #fragment would not load the page
// again, so reload it then; otherwise replace the address as before.
export function returnAfterLogin(returnTo: string, place: Location = window.location): void {
  if (returnTo === loginReturnPath(place) && returnTo !== "/") place.reload();
  else place.replace(returnTo);
}
