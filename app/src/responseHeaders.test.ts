import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Hono } from "hono";
import { setResponseHeader } from "./responseHeaders";

const dir = mkdtempSync(join(tmpdir(), "ytzero-headers-"));
const file = join(dir, "track.mp4");
writeFileSync(file, Uint8Array.from({ length: 100_000 }, (_, i) => i % 251));

// A segment from the middle of a file, as the relay-hls route answers one.
const segment = () => new Response(Bun.file(file).slice(1_000, 2_000), {
  status: 206,
  headers: { "Content-Length": "1000", "Content-Range": "bytes 1000-1999/100000" },
});

const app = new Hono();
app.use("/in-place", async (c, next) => {
  await next();
  setResponseHeader(c, "Cache-Control", "private, no-store");
});
app.get("/in-place", () => segment());
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch });
afterAll(() => server.stop(true));

test("a header added after the handler leaves a file range its length", async () => {
  // Over a real socket: app.request() does not go through Bun's writer.
  const response = await fetch(new URL("/in-place", server.url));
  const body = new Uint8Array(await response.arrayBuffer());
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  expect(response.headers.get("content-length")).toBe("1000");
  expect(body.byteLength).toBe(1000);
  expect(body[0]).toBe(1_000 % 251);
});
