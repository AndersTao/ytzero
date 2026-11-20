import type { Context } from "hono";

/**
 * Set a header on the response a handler has already returned, in place.
 *
 * Hono's `c.header()` after `await next()` builds a new Response around the
 * old one's body. For a file range (`Bun.file().slice()`), Bun then streams
 * from the start of the slice to the end of the *file*: the headers still
 * say 160 KB, the body is the rest of a 24 MB file, and Content-Length is
 * gone. Newer AVPlayer reads what it asked for and ignores the rest; iOS 17's
 * stops (CoreMedia -16041, or a black picture once a fetch completes).
 */
export function setResponseHeader(c: Context, name: string, value: string): void {
  try {
    c.res.headers.set(name, value);
  } catch {
    // A response with immutable headers (one passed through from fetch).
    c.header(name, value);
  }
}
