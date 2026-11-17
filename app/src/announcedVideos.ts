import { database } from "./database";
import { applyAutoTags } from "./autotags";
import { applyFilterRules } from "./filterRules";
import { log } from "./logger";
import { notifyChannelVideos, notifyTagRuleMatches } from "./notifications";
import { backfillShorts, SHORTS_BATCH_SIZE } from "./refresher";
import { applyPlaylistRulesToVideo } from "./userPlaylists";
import { persistDirectVideoInfo } from "./videoInfoPersistence";
import { fetchVideoInfo, type VideoInfo } from "./youtube";
import { isYouTubeRateLimitError, isYouTubeRefusalError } from "./youtubeRateLimit";

const videoExists = database.prepare("SELECT 1 FROM videos WHERE video_id = ?");

export interface AnnouncedVideoOptions {
  userId?: number;
  /** Tests replace the watch-page lookup. */
  fetchInfo?: (videoId: string) => Promise<VideoInfo>;
  /** Tests replace the Shorts check. */
  classifyShort?: (videoId: string, title: string) => Promise<boolean | null>;
}

/**
 * Add uploads a push notification announced that the channel's RSS feed does
 * not list yet, by looking each one up on its own watch page.
 *
 * The hub calls within seconds of an upload, but the feed is a cached copy
 * that trails it by minutes for most channels and by days for some — one
 * large channel's feed was found a day behind, so its pushed uploads never
 * arrived at all. The notification already names the video; waiting for the
 * feed to agree is not needed to know it exists.
 *
 * Only the channel the notification was for: a video that turns out to
 * belong to another channel is not added under this one.
 */
export async function addAnnouncedVideos(channelId: string, videoIds: string[], options: AnnouncedVideoOptions = {}): Promise<string[]> {
  const fetchInfo = options.fetchInfo ?? ((videoId: string) => fetchVideoInfo(videoId, { userId: options.userId }));
  const inheritChannelTags = database.prepare(
    "INSERT OR IGNORE INTO video_tags (video_id, tag_id, source) SELECT ?, tag_id, 'channel' FROM channel_tags WHERE channel_id = ?"
  );
  const added: string[] = [];
  for (const videoId of videoIds) {
    if (await videoExists.get(videoId)) continue;
    let info: VideoInfo;
    try {
      info = await fetchInfo(videoId);
    } catch (error) {
      log.warn("websub.direct_lookup_failed", { channelId, videoId, error: error instanceof Error ? error.message : String(error) });
      if (isYouTubeRateLimitError(error) || isYouTubeRefusalError(error)) break;
      continue;
    }
    if (info.videoId !== videoId || info.channelId !== channelId) {
      log.warn("websub.direct_lookup_other_channel", { channelId, videoId, foundChannelId: info.channelId });
      continue;
    }
    // The feed may have caught up while the page was being read.
    if (await videoExists.get(videoId)) continue;
    await persistDirectVideoInfo(info);
    // That write is shared with lookups of videos nobody follows, and marks
    // the row external; this one belongs to a followed channel.
    await database.prepare("UPDATE videos SET external = 0 WHERE video_id = ?").run(videoId);
    await notifyTagRuleMatches(videoId, await applyAutoTags(videoId, info.title, info.description));
    await applyFilterRules(videoId, channelId, info.title, info.description);
    await applyPlaylistRulesToVideo(videoId);
    await inheritChannelTags.run(videoId, channelId);
    added.push(videoId);
    log.info("video.added", { source: "push", channelId, videoId, title: info.title, publishedAt: info.publishedAt });
  }
  if (added.length) {
    await backfillShorts(added, SHORTS_BATCH_SIZE, options.classifyShort);
    await notifyChannelVideos(channelId, added);
  }
  return added;
}
