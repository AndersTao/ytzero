import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mediaTicketPath, ticketAllowsPath } from "./mediaTickets";

const root = mkdtempSync(join(tmpdir(), "ytzero-offline-copy-"));
const cache = join(root, "cache");
const copies = join(root, "copies");
mkdirSync(cache);
process.env.YTZERO_INVIDIOUS_CACHE_DIR = cache;
process.env.YTZERO_OFFLINE_COPIES_DIR = copies;
const { offlineCopy, offlineCopyPath, offlineHeight, prune } = await import("./offlineCopy");

afterAll(() => rmSync(root, { recursive: true, force: true }));

const ffmpeg = Bun.which("ffmpeg");

async function until<T>(read: () => T, done: (value: T) => boolean): Promise<T> {
  for (let attempt = 0; attempt < 200; attempt++) {
    const value = read();
    if (done(value)) return value;
    await Bun.sleep(50);
  }
  return read();
}

describe("a copy of a video for a device to keep", () => {
  test.skipIf(!ffmpeg)("is the relay's two cached tracks in one MP4, copied rather than converted", async () => {
    // As the relay leaves them: H.264 video and AAC audio, each whole with its line beside it.
    const video = join(cache, "offline0001.hls-video1080.h1080.mp4");
    const audio = join(cache, "offline0001.hls-audio1080.h1080.mp4");
    for (const [path, args] of [
      [video, ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p"]],
      [audio, ["-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:a", "aac"]],
    ] as const) {
      const child = Bun.spawn([ffmpeg!, "-loglevel", "error", "-y", ...args, path]);
      expect(await child.exited).toBe(0);
      writeFileSync(`${path}.txt`, "line");
    }

    expect(offlineCopy(1, "offline0001").kind).toBe("pending");
    const copy = await until(() => offlineCopy(1, "offline0001"), (state) => state.kind !== "pending");
    expect(copy.kind).toBe("ready");
    expect(existsSync(offlineCopyPath("offline0001"))).toBe(true);
    // Asked for lower, the copy is its own file from a track no higher than that.
    const lower = join(cache, "offline0001.hls-video720.h720.mp4");
    expect(Bun.spawnSync([ffmpeg!, "-loglevel", "error", "-y", "-i", video, "-c", "copy", lower]).exitCode).toBe(0);
    writeFileSync(`${lower}.txt`, "line");
    const at720 = await until(() => offlineCopy(1, "offline0001", 720), (state) => state.kind !== "pending");
    expect(at720.kind).toBe("ready");
    expect(existsSync(offlineCopyPath("offline0001", 720))).toBe(true);
    expect(offlineCopyPath("offline0001", 720)).not.toBe(offlineCopyPath("offline0001"));

    const probe = Bun.spawnSync([ffmpeg!.replace(/ffmpeg$/, "ffprobe"), "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", offlineCopyPath("offline0001")]);
    expect(probe.stdout.toString().trim().split("\n").sort()).toEqual(["aac", "h264"]);
  });

  test("refuses anything that is not a video id, which names a file", () => {
    expect(offlineCopy(1, "../etc").kind).toBe("failed");
  });

  test("is made at 480, 720 or 1080, and at 1080 when asked for anything else", () => {
    expect([480, 720, 1080].map(offlineHeight)).toEqual([480, 720, 1080]);
    expect([undefined, "abc", 360, 2160].map(offlineHeight)).toEqual([1080, 1080, 1080, 1080]);
  });

  test("goes once it has not been fetched for two days, or when copies outgrow the limit", () => {
    mkdirSync(copies, { recursive: true });
    const now = Date.now();
    const old = join(copies, "oldcopy0001.mp4");
    const recent = join(copies, "newcopy0001.mp4");
    const newest = join(copies, "newcopy0002.mp4");
    for (const path of [old, recent, newest]) writeFileSync(path, new Uint8Array(1_000));
    utimesSync(old, new Date(now - 3 * 86_400_000), new Date(now - 3 * 86_400_000));
    utimesSync(recent, new Date(now - 60_000), new Date(now - 60_000));
    utimesSync(newest, new Date(now), new Date(now));

    prune(undefined, now, 10_000_000);
    expect(existsSync(old)).toBe(false);
    expect(existsSync(recent)).toBe(true);

    // Over the limit, the least recently fetched goes first.
    prune(undefined, now, 1_500);
    expect(existsSync(recent)).toBe(false);
    expect(existsSync(newest)).toBe(true);
  });

  test("is fetched with a ticket good for that file only", () => {
    const ticket = { videoId: "abc123", kind: "offline" as const };
    expect(mediaTicketPath(ticket)).toBe("/api/videos/abc123/offline.mp4");
    expect(ticketAllowsPath(ticket, "/api/videos/abc123/offline.mp4", "GET")).toBe(true);
    expect(ticketAllowsPath(ticket, "/api/videos/abc123/stream", "GET")).toBe(false);
    expect(ticketAllowsPath(ticket, "/api/videos/other/offline.mp4", "GET")).toBe(false);
    expect(ticketAllowsPath(ticket, "/api/videos/abc123/offline.mp4", "DELETE")).toBe(false);
  });
});
