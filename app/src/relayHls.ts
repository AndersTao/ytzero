import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { cachedEntry, pendingFetch, startFetch, type MediaKind, type PendingFetch } from "./compat/invidious/mediaCache";
import { log } from "./logger";
import { parseMediaSidx, type MediaSidxIndex } from "./mediaSidx";
import { createVideoVodPresentation, type VideoVodPresentation } from "./videoVodPlaylist";
import { startTail, tailCovers, tailResponse } from "./relayHlsTail";

/*
 * Full quality for AVPlayer without the direct path.
 *
 * The relay serves YouTube's one muxed file, and YouTube keeps that at 360p.
 * Everything better exists only as separate video and audio, which AVPlayer
 * will play together only as HLS. The direct HLS presentation does exactly
 * that, but by proxying the addresses yt-dlp printed, and on an instance
 * without a PO token YouTube refuses those (403).
 *
 * So the two tracks are fetched the way that works — yt-dlp downloading them,
 * into the same cache the Invidious clients use — and the presentation points
 * into those files by the byte ranges of their own index (sidx), which is at
 * the front and arrives first. Every range is answered as soon as its bytes
 * are on disk, so playback starts while the rest is still coming in.
 */

export const RELAY_HLS_HEIGHT = 1080;
const INDEX_WAIT_MS = 60_000;
const FIRST_INDEX_BYTES = 4 * 1024;
const MAX_INDEX_BYTES = 4 * 1024 * 1024;
const KEPT_PRESENTATIONS = 32;

interface Track {
  /** yt-dlp's line: size, height, vcodec, acodec, width, fps, tbr, channels. */
  described: string;
  total: number;
  prefix: (bytes: number, signal: AbortSignal) => Promise<Uint8Array | null>;
}

/** What a tail needs to fetch the same file: the format and its full length. */
type Pinned = { formatId: string | null; total: number };
type Built = { presentation: VideoVodPresentation; generation: string; video: Pinned; audio: Pinned };
const presentations = new Map<string, Built>();
const building = new Map<string, Promise<Built | null>>();

function fromFile(path: string, described: string): Track {
  return {
    described,
    total: statSync(path).size,
    prefix: async (bytes) => new Uint8Array(await Bun.file(path).slice(0, bytes).arrayBuffer()),
  };
}

function fromFetch(entry: PendingFetch, described: string, total: number): Track {
  let finished: string | null | undefined;
  void entry.done.then((path) => { finished = path; }, () => { finished = null; });
  return {
    described,
    total,
    prefix: async (bytes, signal) => {
      const deadline = Date.now() + INDEX_WAIT_MS;
      while (Date.now() < deadline && !signal.aborted) {
        if (finished === null) return null;
        const path = finished ?? entry.path;
        let size = 0;
        try {
          size = statSync(path).size;
        } catch {
          size = 0;
        }
        if (size >= bytes || (finished && size > 0)) {
          return new Uint8Array(await Bun.file(path).slice(0, Math.min(bytes, size)).arrayBuffer());
        }
        await Bun.sleep(100);
      }
      return null;
    },
  };
}

async function track(userId: number, videoId: string, kind: MediaKind): Promise<Track | null> {
  const kept = cachedEntry(videoId, kind, RELAY_HLS_HEIGHT);
  if (kept && existsSync(`${kept.path}.txt`)) return fromFile(kept.path, readFileSync(`${kept.path}.txt`, "utf8"));
  const entry = pendingFetch(videoId, kind, RELAY_HLS_HEIGHT) ?? startFetch(userId, videoId, kind, RELAY_HLS_HEIGHT);
  if (!entry?.described) return null;
  const [described, total] = await Promise.all([entry.described, entry.total]);
  // Without a size there is nothing to index against while the file grows.
  if (!described || total === null) return null;
  return fromFetch(entry, described, total);
}

async function indexOf(source: Track, signal: AbortSignal): Promise<MediaSidxIndex | null> {
  let bytes = Math.min(FIRST_INDEX_BYTES, source.total);
  while (!signal.aborted) {
    const prefix = await source.prefix(bytes, signal);
    if (!prefix) return null;
    const parsed = parseMediaSidx(prefix, source.total);
    if (parsed.kind === "ok") return parsed.index;
    if (parsed.kind === "unsupported" || parsed.minimumBytes <= bytes || parsed.minimumBytes > MAX_INDEX_BYTES) return null;
    bytes = parsed.minimumBytes;
  }
  return null;
}

function field(line: string, position: number): number | null {
  const value = Number(line.trim().split(/\s+/)[position]);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function seconds(index: MediaSidxIndex): number {
  return index.references.reduce((sum, reference) => sum + reference.durationTicks, 0) / index.timescale;
}

/** Bits per second: what yt-dlp said, or else what the file works out to. */
function bitrate(line: string, total: number, index: MediaSidxIndex): number {
  const said = field(line, 6);
  return said ? Math.round(said * 1000) : Math.max(1, Math.round(total * 8 / Math.max(1, seconds(index))));
}

async function build(userId: number, videoId: string, signal: AbortSignal): Promise<Built | null> {
  const [video, audio] = await Promise.all([track(userId, videoId, "hls-video"), track(userId, videoId, "hls-audio")]);
  if (!video || !audio) return null;
  const [videoIndex, audioIndex] = await Promise.all([indexOf(video, signal), indexOf(audio, signal)]);
  if (!videoIndex || !audioIndex) {
    log.warn("relay_hls.index_failed", { videoId, video: Boolean(videoIndex), audio: Boolean(audioIndex) });
    return null;
  }
  const words = (line: string) => line.trim().split(/\s+/);
  const generation = createHash("sha256").update(`${video.described}\n${audio.described}\n${video.total}:${audio.total}`).digest("hex").slice(0, 24);
  const result = createVideoVodPresentation({
    videoId,
    resourcePath: "relay-hls",
    resourceVersion: generation,
    video: videoIndex,
    audio: audioIndex,
    metadata: {
      videoCodec: words(video.described)[2] ?? "",
      audioCodec: words(audio.described)[3] ?? "",
      width: field(video.described, 4) ?? 0,
      height: field(video.described, 1) ?? 0,
      fps: field(video.described, 5) ?? 0,
      videoBitrate: bitrate(video.described, video.total, videoIndex),
      audioBitrate: bitrate(audio.described, audio.total, audioIndex),
      audioChannels: field(audio.described, 7),
    },
  });
  if (result.kind !== "ok") {
    log.warn("relay_hls.unsupported", { videoId, reason: result.reason });
    return null;
  }
  const pinned = (track: Track): Pinned => ({ formatId: words(track.described)[8] ?? null, total: track.total });
  return { presentation: result.presentation, generation, video: pinned(video), audio: pinned(audio) };
}

/** The presentation for this video, built once and shared by everyone asking. */
async function presentationFor(userId: number, videoId: string): Promise<Built | null> {
  // Only while the file it indexes is still there: a refetch is another file.
  const kept = presentations.get(videoId);
  if (kept && (cachedEntry(videoId, "hls-video", RELAY_HLS_HEIGHT) || pendingFetch(videoId, "hls-video", RELAY_HLS_HEIGHT))) return kept;
  const running = building.get(videoId);
  if (running) return running;
  const startedAt = Date.now();
  // Shared by every request for it, so no one request's disconnect ends it.
  const work = build(userId, videoId, AbortSignal.timeout(2 * INDEX_WAIT_MS)).then((built) => {
    if (built) {
      presentations.delete(videoId);
      presentations.set(videoId, built);
      while (presentations.size > KEPT_PRESENTATIONS) presentations.delete(presentations.keys().next().value!);
      log.info("relay_hls.ready", { videoId, ms: Date.now() - startedAt, segments: built.presentation.segmentCount });
    }
    return built;
  }).finally(() => building.delete(videoId));
  building.set(videoId, work);
  return work;
}

/** Bytes of this track on disk now: all of a kept file, so far of one arriving. */
function arrived(videoId: string, kind: MediaKind): number {
  if (cachedEntry(videoId, kind, RELAY_HLS_HEIGHT)) return Number.POSITIVE_INFINITY;
  const entry = pendingFetch(videoId, kind, RELAY_HLS_HEIGHT);
  try {
    return entry ? statSync(entry.path).size : 0;
  } catch {
    return 0;
  }
}

/** Where the segment holding `start` seconds begins, and where the one after it ends. */
function neededRange(segments: VideoVodPresentation["videoSegments"], start: number): { from: number; to: number } {
  let elapsed = 0;
  let position = segments.length - 1;
  for (let index = 0; index < segments.length; index++) {
    elapsed += segments[index].durationSeconds;
    if (elapsed > start) {
      position = index;
      break;
    }
  }
  const next = segments[Math.min(position + 1, segments.length - 1)];
  return { from: segments[position].offset, to: next.offset + next.length };
}

/** How far behind the head may be before a tail is worth starting (MB). */
function tailAfterBytes(): number {
  const megabytes = Number(process.env.YTZERO_RELAY_HLS_TAIL_AFTER_MB ?? 32);
  return (Number.isFinite(megabytes) && megabytes >= 0 ? megabytes : 32) * 1024 * 1024;
}

/**
 * Whether a player starting at `start` seconds will find its first segments.
 *
 * AVPlayer gives a segment seven seconds to start arriving and then gives up
 * on the item for good. So the client is told to wait (202, which it already
 * retries) until those bytes are here. When the place is far ahead of the
 * fetch from the start, a second fetch begins right there (relayHlsTail), so
 * a resume forty minutes in waits seconds, not the minute or two the first
 * fetch takes to get there. Waits up to `waitMs` before answering "pending".
 */
export async function relayHlsReadiness(userId: number, videoId: string, start: number, waitMs: number): Promise<"ready" | "pending" | "failed"> {
  const deadline = Date.now() + waitMs;
  const built = await Promise.race([presentationFor(userId, videoId), Bun.sleep(waitMs).then(() => undefined)]);
  if (built === undefined) return "pending";
  if (built === null) return "failed";
  const at = Math.max(0, Number.isFinite(start) ? start : 0);
  const tracks = [
    { kind: "hls-video" as const, pinned: built.video, range: neededRange(built.presentation.videoSegments, at) },
    { kind: "hls-audio" as const, pinned: built.audio, range: neededRange(built.presentation.audioSegments, at) },
  ];
  for (const { kind, pinned, range } of tracks) {
    if (pinned.formatId && range.from - arrived(videoId, kind) > tailAfterBytes()) {
      startTail(userId, videoId, kind, pinned.formatId, range.from, pinned.total, () => arrived(videoId, kind));
    }
  }
  for (;;) {
    if (tracks.every(({ kind, range }) => arrived(videoId, kind) >= range.to || tailCovers(videoId, kind, range.from, range.to))) return "ready";
    if (!pendingFetch(videoId, "hls-video", RELAY_HLS_HEIGHT) && !cachedEntry(videoId, "hls-video", RELAY_HLS_HEIGHT)) return "failed";
    if (Date.now() >= deadline) return "pending";
    await Bun.sleep(150);
  }
}

/** A range a tail can answer that the head has not reached yet, or null. */
export function relayHlsTailResponse(videoId: string, kind: "hls-video" | "hls-audio", range: string | undefined): Promise<Response | null> {
  return tailResponse(videoId, kind, range, arrived(videoId, kind));
}

export type RelayHlsPlaylist = "index.m3u8" | "video.m3u8" | "audio.m3u8";

/**
 * One of the three playlists, or null when this video cannot be played this
 * way (the client then falls back to the plain relay).
 */
export async function relayHlsPlaylist(userId: number, videoId: string, file: RelayHlsPlaylist): Promise<string | null> {
  const built = await presentationFor(userId, videoId);
  if (!built) return null;
  const { presentation } = built;
  return file === "index.m3u8" ? presentation.masterPlaylist : file === "video.m3u8" ? presentation.videoPlaylist : presentation.audioPlaylist;
}

/** For tests. */
export function forgetRelayHlsPresentations(): void {
  presentations.clear();
  building.clear();
}
