import { readdirSync, rmSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { YTDLP } from "./downloadConfig";
import { mediaCachePath, mediaFetchArgs, streamingRangeResponse, type MediaKind, type PendingFetch } from "./compat/invidious/mediaCache";
import { log } from "./logger";

/*
 * A second fetch of a track, starting in the middle.
 *
 * The fetch from the start reaches the forty-first minute of a long video a
 * minute or two after it begins, and a player resuming there would wait all
 * of that. yt-dlp resumes a file that is already there from its last byte, so
 * a file made exactly as long as the place to start from — sparse, nothing
 * written — has it fetch from there: measured, the first byte at 1 GB in two
 * seconds, identical to the same byte of the whole file.
 *
 * The tail is pinned to the format the head is fetching, so both are the same
 * file. It is only a stopgap: it ends once the head has caught up with it or
 * nobody has read from it for a while, and the head stays the copy that is
 * kept.
 */

interface Tail {
  offset: number;
  entry: PendingFetch;
  process: ReturnType<typeof Bun.spawn>;
  lastRead: number;
  stopped: boolean;
}

const tails = new Map<string, Tail>();
const MAX_TAILS = 4;
const IDLE_MS = 3 * 60_000;
const CHECK_MS = 2_000;
const REMOVE_AFTER_MS = 60_000;
const REUSE_BYTES = 64 * 1024 * 1024;

const keyFor = (videoId: string, kind: MediaKind) => `${videoId}:${kind}`;

/** Tails left behind by a process that ended without stopping them. */
let cleaned = false;
function cleanStale(): void {
  if (cleaned) return;
  cleaned = true;
  const directory = dirname(mediaCachePath("probe"));
  try {
    for (const name of readdirSync(directory)) if (name.endsWith(".tail")) rmSync(`${directory}/${name}`, { force: true });
  } catch {
    // Nothing to clean.
  }
}

function written(tail: Tail): number {
  try {
    return statSync(tail.entry.path).size;
  } catch {
    return 0;
  }
}

function stop(key: string, tail: Tail, reason: string): void {
  if (tail.stopped) return;
  tail.stopped = true;
  if (tails.get(key) === tail) tails.delete(key);
  try { tail.process.kill(); } catch { /* already gone */ }
  log.info("relay_hls.tail_stopped", { key, reason, offset: tail.offset, reached: written(tail) });
  // Answers still streaming from it finish or fail over to the head first.
  setTimeout(() => rmSync(tail.entry.path, { force: true }), REMOVE_AFTER_MS);
}

/**
 * Fetch `kind` of `videoId` from byte `offset` on, unless a tail that starts
 * at or before it is already running. `headArrived` says how far the fetch
 * from the start has got; the tail ends when that passes it.
 */
export function startTail(
  userId: number, videoId: string, kind: MediaKind, formatId: string, offset: number, total: number,
  headArrived: () => number,
): void {
  cleanStale();
  const key = keyFor(videoId, kind);
  const running = tails.get(key);
  // One already on its way to this place is as good as a new one.
  if (running && running.offset <= offset && offset - running.offset < REUSE_BYTES) return;
  if (running) stop(key, running, "moved");
  if (tails.size >= MAX_TAILS || !/^[\w-]+$/.test(formatId)) return;

  const path = mediaCachePath(`${videoId}.${kind}.tail`);
  rmSync(path, { force: true });
  writeFileSync(path, "");
  truncateSync(path, offset);
  const child = Bun.spawn([YTDLP, ...mediaFetchArgs(userId, videoId, kind, formatId, path)], { stdout: "ignore", stderr: "ignore" });
  const tail: Tail = {
    offset,
    process: child,
    lastRead: Date.now(),
    stopped: false,
    entry: {
      path,
      total: Promise.resolve(total),
      done: child.exited.then((code) => (code === 0 ? path : null)),
    },
  };
  tails.set(key, tail);
  log.info("relay_hls.tail_started", { videoId, kind, offset, total });

  const timer = setInterval(() => {
    if (tail.stopped) return clearInterval(timer);
    const head = headArrived();
    if (head >= total || head >= written(tail)) stop(key, tail, "head_caught_up");
    else if (Date.now() - tail.lastRead > IDLE_MS) stop(key, tail, "idle");
  }, CHECK_MS);
  void child.exited.then((code) => {
    if (code !== 0 && !tail.stopped) stop(key, tail, `exit_${code}`);
  });
}

/** Bytes from `start` up to where the tail has got, if a tail covers `start`. */
export function tailCovers(videoId: string, kind: MediaKind, start: number, end: number): boolean {
  const tail = tails.get(keyFor(videoId, kind));
  return Boolean(tail && tail.offset <= start && written(tail) >= end);
}

/**
 * The answer for a range the head has not reached but a tail has started at
 * or before, or null when it is the head's to answer.
 */
export async function tailResponse(videoId: string, kind: MediaKind, range: string | undefined, headArrived: number): Promise<Response | null> {
  const tail = tails.get(keyFor(videoId, kind));
  const start = Number(range?.match(/bytes=(\d+)-/)?.[1] ?? Number.NaN);
  if (!tail || !Number.isFinite(start) || start < tail.offset || headArrived > start) return null;
  tail.lastRead = Date.now();
  return streamingRangeResponse(tail.entry, range, kind);
}

/** For tests. */
export function stopAllTails(): void {
  for (const [key, tail] of tails) stop(key, tail, "reset");
}
