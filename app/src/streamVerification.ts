import { database } from "./database";
import { getSetting, setSetting } from "./db";
import { log } from "./logger";
import { fetchVideoInfo, type VideoInfo } from "./youtube";
import { isYouTubeRefusalError } from "./youtubeRateLimit";

/*
 * A channel's Live tab is not a list of streams. YouTube files premieres there
 * too, and a channel that premieres every upload has all of them on it. The
 * full sync read that tab as "these were streams" and marked every entry
 * was_live, so ordinary uploads went about with a Livestream badge — and,
 * for a profile hiding streams, out of the feed.
 *
 * The watch page says it directly (videoDetails.isLiveContent), so a video
 * the tab lists is asked once before it is marked. Asked only when the mark
 * would change something, and remembered for the life of the process, so a
 * channel full of premieres costs one lookup per video, not one per sync.
 */

type InfoFetcher = (videoId: string) => Promise<VideoInfo>;
const verdicts = new Map<string, boolean>();

/**
 * Whether a video the Live tab lists should be marked as a recorded stream.
 * False when it is already marked something else, or when its page says it
 * was not a stream. An unanswered lookup leaves it unmarked; the next sync
 * asks again.
 */
export async function isRecordedStream(videoId: string, fetchInfo: InfoFetcher = (id) => fetchVideoInfo(id)): Promise<boolean> {
  const row = await database.prepare("SELECT live_status FROM videos WHERE video_id = ?").get(videoId) as { live_status: string } | null;
  if (row && row.live_status !== "none") return false;
  const known = verdicts.get(videoId);
  if (known !== undefined) return known;
  try {
    const recorded = (await fetchInfo(videoId)).liveStatus === "was_live";
    verdicts.set(videoId, recorded);
    return recorded;
  } catch (error) {
    log.warn("stream.verify_failed", { videoId, error: error instanceof Error ? error.message : String(error) });
    return false;
  }
}

/** For tests. */
export function forgetStreamVerdicts(): void {
  verdicts.clear();
}

const REPAIR_KEY = "stream_badge_repair_v1";
const REPAIR_DAYS = 120;
const REPAIR_GAP_MS = 3_000;

/**
 * Once: ask the watch page about every recent video already marked as a
 * recorded stream, and clear the mark on the ones that were not. Runs slowly
 * in the background; a refusal from YouTube stops it, and it picks up again
 * on the next start until it has been through the list.
 */
export async function repairStreamBadges(options: { fetchInfo?: InfoFetcher; gapMs?: number } = {}): Promise<{ checked: number; cleared: number; done: boolean }> {
  if (getSetting(REPAIR_KEY) === "done") return { checked: 0, cleared: 0, done: true };
  const fetchInfo = options.fetchInfo ?? ((id: string) => fetchVideoInfo(id));
  const gapMs = options.gapMs ?? REPAIR_GAP_MS;
  const rows = await database.prepare(
    `SELECT video_id FROM videos
     WHERE live_status = 'was_live' AND COALESCE(published_at, created_at) >= datetime('now', ?)
     ORDER BY COALESCE(published_at, created_at) DESC`
  ).all(`-${REPAIR_DAYS} days`) as { video_id: string }[];
  const clear = database.prepare("UPDATE videos SET live_status = 'none' WHERE video_id = ? AND live_status = 'was_live'");
  let checked = 0;
  let cleared = 0;
  for (const { video_id: videoId } of rows) {
    let info: VideoInfo;
    try {
      info = await fetchInfo(videoId);
    } catch (error) {
      if (isYouTubeRefusalError(error)) {
        log.warn("stream.repair_paused", { checked, cleared, remaining: rows.length - checked });
        return { checked, cleared, done: false };
      }
      checked++;
      continue;
    }
    checked++;
    if (info.liveStatus === "none") {
      await clear.run(videoId);
      cleared++;
    }
    if (gapMs > 0) await Bun.sleep(gapMs);
  }
  await setSetting(REPAIR_KEY, "done");
  log.info("stream.repair_complete", { checked, cleared });
  return { checked, cleared, done: true };
}
