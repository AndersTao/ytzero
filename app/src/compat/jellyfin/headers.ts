/**
 * Reading what a Jellyfin client sends. Kept apart from sign-in so it needs
 * no database.
 */

/**
 * Where a Jellyfin client puts its token: the MediaBrowser authorization
 * header, or the token headers older clients send. Never the query string,
 * where it would end up in logs; nothing this dialect serves needs it there.
 */
export function presentedToken(headers: Headers): string | null {
  for (const name of ["authorization", "x-emby-authorization"]) {
    const value = headers.get(name) ?? "";
    const match = /\bToken="([^"]+)"/i.exec(value);
    if (/^(?:MediaBrowser|Emby)\b/i.test(value) && match) return match[1];
  }
  for (const name of ["x-emby-token", "x-mediabrowser-token"]) {
    const value = headers.get(name)?.trim();
    if (value) return value;
  }
  return null;
}

/** The fields of the MediaBrowser authorization header: Client, Device, DeviceId, Version. */
export function clientFields(headers: Headers): Record<string, string> {
  const value = headers.get("authorization") ?? headers.get("x-emby-authorization") ?? "";
  const fields: Record<string, string> = {};
  for (const match of value.matchAll(/(\w+)="([^"]*)"/g)) fields[match[1]] = decodeURIComponent(match[2]);
  return fields;
}
