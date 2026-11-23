import { randomBytes } from "node:crypto";
import { log } from "../../logger";
import { runTimeSeconds, ticks, type ApiVideo } from "./items";
import type { OwnApi } from "./ownApi";

/**
 * Playing a video for a Jellyfin client: this server's full-quality HLS relay,
 * the stream the Apple TV app plays, offered as Jellyfin's "transcode".
 *
 * The client gets the playlist's path under the Jellyfin address and plays it
 * in AVPlayer, which sends no credentials: the media ticket in the address is
 * the whole of the authorisation, as it is for the Apple TV app. A ticket
 * lasts a quarter of an hour, so each progress report renews it, which the
 * Apple TV app does on its own.
 */

interface Playing {
  videoId: string;
  ticket: string;
  session: string;
  runtime: number | null;
}

const playing = new Map<string, Playing>();
const MAX_PLAYING = 256;

/** How long PlaybackInfo waits for the relay to have the start of the video. */
const PREPARE_TIMEOUT_MS = 30_000;

export async function playbackInfo(
  own: OwnApi,
  session: string,
  videoId: string,
  startSeconds: number,
  runtime: number | null,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + PREPARE_TIMEOUT_MS;
  for (;;) {
    const response = await own.raw("POST", `/videos/${encodeURIComponent(videoId)}/playback-ticket`, { source: "relay-hls", start: startSeconds });
    if (response.status === 202 && Date.now() < deadline) {
      await Bun.sleep(1500);
      continue;
    }
    if (!response.ok) {
      log.warn("jellyfin.playback_unavailable", { videoId, status: response.status });
      return { MediaSources: [], ErrorCode: response.status === 403 ? "NotAllowed" : "NoCompatibleStream" };
    }
    const { ticket, url } = await response.json() as { ticket: string; url: string };
    const playSessionId = randomBytes(16).toString("hex");
    if (playing.size >= MAX_PLAYING) playing.delete(playing.keys().next().value!);
    playing.set(playSessionId, { videoId, ticket, session, runtime });
    return {
      PlaySessionId: playSessionId,
      MediaSources: [{
        Id: videoId,
        Protocol: "Http",
        Type: "Default",
        Container: "mp4",
        Name: "YouTube",
        IsRemote: false,
        RunTimeTicks: runtime ? ticks(runtime) : undefined,
        SupportsDirectPlay: false,
        SupportsDirectStream: false,
        SupportsTranscoding: true,
        // Relative to the address the client signed in to, so it lands on
        // the route below that hands it to the API.
        TranscodingUrl: url,
        TranscodingSubProtocol: "hls",
        TranscodingContainer: "mp4",
        MediaStreams: [
          { Index: 0, Type: "Video", Codec: "h264", IsDefault: true },
          { Index: 1, Type: "Audio", Codec: "aac", Channels: 2, IsDefault: true },
        ],
        DefaultAudioStreamIndex: 1,
      }],
    };
  }
}

export interface PlaybackReport {
  ItemId?: string;
  PlaySessionId?: string;
  PositionTicks?: number;
  IsPaused?: boolean;
}

/** Started: the history entry the web client's Continue watching joins on. */
export async function reportStart(own: OwnApi, report: PlaybackReport): Promise<void> {
  const videoId = report.ItemId ?? playing.get(report.PlaySessionId ?? "")?.videoId;
  if (videoId) await own.raw("POST", `/videos/${encodeURIComponent(videoId)}/watch`, {});
}

/** Where it got to, saved as the apps save it; the stream's ticket kept alive. */
export async function reportProgress(own: OwnApi, report: PlaybackReport, stopped: boolean): Promise<void> {
  const entry = playing.get(report.PlaySessionId ?? "");
  const videoId = report.ItemId ?? entry?.videoId;
  if (!videoId) return;
  const position = Number(report.PositionTicks ?? 0) / 10_000_000;
  if (position > 0) {
    // Continue watching needs the length beside the position.
    const duration = entry?.runtime ?? await lengthOf(own, videoId) ?? 0;
    await own.raw("PUT", `/videos/${encodeURIComponent(videoId)}/progress`, { position, duration });
  }
  if (!entry) return;
  if (stopped) {
    await own.raw("DELETE", `/videos/${encodeURIComponent(entry.videoId)}/playback-ticket`, { ticket: entry.ticket });
    playing.delete(report.PlaySessionId!);
  } else {
    await own.raw("PUT", `/videos/${encodeURIComponent(entry.videoId)}/playback-ticket`, { ticket: entry.ticket });
  }
}

/** A video's length, for a report that came without its playback info. */
async function lengthOf(own: OwnApi, videoId: string): Promise<number | null> {
  const response = await own.raw("GET", `/videos/${encodeURIComponent(videoId)}`);
  if (!response.ok) return null;
  const { video } = await response.json() as { video?: ApiVideo };
  return video ? runTimeSeconds(video) : null;
}

/** The ticket's session, for a stopped stream the client names only by its play session. */
export function forgetPlaySession(playSessionId: string | undefined): void {
  if (playSessionId) playing.delete(playSessionId);
}
