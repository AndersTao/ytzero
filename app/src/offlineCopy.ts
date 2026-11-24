import { existsSync, mkdirSync, readdirSync, renameSync, rmSync, statSync, utimesSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { DB_PATH } from "./db";
import { cacheableVideoId, cachedEntry, pendingFetch, startFetch, type MediaKind, type PendingFetch } from "./compat/invidious/mediaCache";
import { log } from "./logger";
import { RELAY_HLS_HEIGHT } from "./relayHls";

/*
 * A copy of a video for an iPhone or iPad to keep and watch offline.
 *
 * The apps stream the relay's full quality: H.264 up to 1080p and AAC, fetched
 * by yt-dlp as two files into the Invidious cache. Those are exactly what
 * AVPlayer plays, so a copy for the device is the two put into one MP4 — the
 * streams copied, not converted, which takes seconds. The device picks the
 * height (480, 720 or 1080): the video track is fetched no higher than that,
 * the audio is the same for all three. The profile's own
 * Downloads archive is not involved: it keeps whatever quality the profile
 * chose (4K AV1, say), which a device would have to have converted first.
 *
 * Copies are made on request, kept for a while for the device to fetch, and
 * the oldest are removed beyond a size limit.
 */

const KEEP_MS = 48 * 60 * 60 * 1000;
const LIMIT_BYTES = Math.max(1, Number(process.env.YTZERO_OFFLINE_COPIES_MB) || 8192) * 1024 * 1024;
/** How long a failed copy is reported before asking makes it try again. */
const FAILURE_MS = 60_000;
/** How long to wait for one of the cache's fetch slots to be free. */
const SLOT_WAIT_MS = 10 * 60_000;

export type OfflineCopy =
  | { kind: "ready"; path: string; size: number }
  | { kind: "pending"; progress: number | null }
  | { kind: "failed"; error: string };

function directory(): string {
  return process.env.YTZERO_OFFLINE_COPIES_DIR ?? resolve(dirname(DB_PATH), "../offline-copies");
}

/** The heights a device may ask for; anything else is the highest. */
export const OFFLINE_HEIGHTS = [480, 720, 1080] as const;

export function offlineHeight(value: unknown): number {
  const height = Math.trunc(Number(value));
  return (OFFLINE_HEIGHTS as readonly number[]).includes(height) ? height : RELAY_HLS_HEIGHT;
}

export function offlineCopyPath(videoId: string, height: number = RELAY_HLS_HEIGHT): string {
  return join(directory(), `${videoId}.${offlineHeight(height)}.mp4`);
}

const building = new Map<string, Promise<void>>();
const progressOf = new Map<string, () => number | null>();
const failures = new Map<string, { error: string; at: number }>();

/** Where the copy of a video is: ready, being made (with how far), or failed. Asking starts it. */
export function offlineCopy(userId: number, videoId: string, asked: number = RELAY_HLS_HEIGHT): OfflineCopy {
  if (!cacheableVideoId(videoId)) return { kind: "failed", error: "not a video id" };
  const height = offlineHeight(asked);
  const key = `${videoId}:${height}`;
  const path = offlineCopyPath(videoId, height);
  if (!building.has(key) && existsSync(path)) {
    const now = new Date();
    // Fetched again: kept from now on.
    try { utimesSync(path, now, now); } catch {}
    return { kind: "ready", path, size: statSync(path).size };
  }
  const failed = failures.get(key);
  if (failed && Date.now() - failed.at < FAILURE_MS) return { kind: "failed", error: failed.error };
  if (!building.has(key)) start(userId, videoId, height, path);
  return { kind: "pending", progress: progressOf.get(key)?.() ?? null };
}

function start(userId: number, videoId: string, height: number, path: string): void {
  const key = `${videoId}:${height}`;
  failures.delete(key);
  const startedAt = Date.now();
  const job = (async () => {
    const [video, audio] = await Promise.all([
      complete(userId, videoId, "hls-video", height, key),
      // The same sound whatever the picture: the relay's own audio track.
      complete(userId, videoId, "hls-audio", RELAY_HLS_HEIGHT, key),
    ]);
    if (!video || !audio) throw new Error("the video could not be fetched");
    await joinTracks(video, audio, path);
    log.info("offline_copy.ready", { videoId, height, bytes: statSync(path).size, ms: Date.now() - startedAt });
    prune(path);
  })()
    .catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      failures.set(key, { error: message, at: Date.now() });
      log.warn("offline_copy.failed", { videoId, height, error: message.slice(0, 300) });
    })
    .finally(() => {
      building.delete(key);
      progressOf.delete(key);
    });
  building.set(key, job);
}

/** One of the two tracks, whole: the cache's own copy, or one fetched for it now. */
async function complete(userId: number, videoId: string, kind: MediaKind, height: number, key: string): Promise<string | null> {
  const deadline = Date.now() + SLOT_WAIT_MS;
  while (Date.now() < deadline) {
    const kept = cachedEntry(videoId, kind, height);
    // The line yt-dlp printed is written beside a track once it is whole.
    if (kept && existsSync(`${kept.path}.txt`)) return kept.path;
    const entry = pendingFetch(videoId, kind, height) ?? startFetch(userId, videoId, kind, height);
    if (entry) {
      // The video is nearly all of the bytes: its share is the progress shown.
      if (kind === "hls-video") progressOf.set(key, fraction(entry));
      return await entry.done;
    }
    // Every fetch slot is taken: wait for one.
    await Bun.sleep(2_000);
  }
  return null;
}

function fraction(entry: PendingFetch): () => number | null {
  let total: number | null = null;
  void entry.total.then((value) => { total = value; }, () => {});
  return () => {
    if (!total) return null;
    try {
      return Math.min(1, statSync(entry.path).size / total);
    } catch {
      return null;
    }
  };
}

/** The two tracks in one MP4, copied as they are, its index at the front. */
async function joinTracks(video: string, audio: string, path: string): Promise<void> {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp.mp4`;
  const child = Bun.spawn([
    process.env.FFMPEG_PATH ?? "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-i", video, "-i", audio, "-map", "0:v:0", "-map", "1:a:0",
    "-c", "copy", "-movflags", "+faststart", temporary,
  ], { stdout: "ignore", stderr: "pipe" });
  const [said, code] = await Promise.all([new Response(child.stderr as ReadableStream<Uint8Array>).text(), child.exited]);
  if (code !== 0 || !existsSync(temporary)) {
    rmSync(temporary, { force: true });
    throw new Error(`ffmpeg: ${said.trim().split(/\r?\n/).slice(-1)[0] || `exit ${code}`}`);
  }
  renameSync(temporary, path);
}

/** Copies not fetched for a while go, and the oldest go beyond the limit. */
export function prune(keep?: string, now = Date.now(), limit = LIMIT_BYTES): void {
  let names: string[];
  try {
    names = readdirSync(directory()).filter((name) => name.endsWith(".mp4") && !name.includes(".tmp."));
  } catch {
    return;
  }
  const files = names
    .map((name) => {
      const path = join(directory(), name);
      try {
        const stats = statSync(path);
        return { path, size: stats.size, used: Math.max(stats.atimeMs, stats.mtimeMs) };
      } catch {
        return null;
      }
    })
    .filter((file): file is { path: string; size: number; used: number } => file !== null)
    .sort((a, b) => a.used - b.used);
  let total = files.reduce((sum, file) => sum + file.size, 0);
  for (const file of files) {
    if (file.path === keep) continue;
    if (now - file.used > KEEP_MS || total > limit) {
      rmSync(file.path, { force: true });
      total -= file.size;
    }
  }
}
