import { createHash } from "node:crypto";
import { durationSeconds } from "../../shortClassification";

/**
 * Videos as Jellyfin items.
 *
 * Jellyfin clients understand films, series and episodes; a "Video" is shown
 * but cannot be played from their home screens. So every video is a film in
 * one film library, its channel standing where a film's studio would. The
 * thumbnail is both poster and backdrop: that is what puts it in the large
 * pictures at the top of the home screen too.
 */

/** The one library: Main. */
export const LIBRARY_ID = "ytzeromain";

const TICKS_PER_SECOND = 10_000_000;

export interface ApiVideo {
  video_id: string;
  title?: string | null;
  description?: string | null;
  channel_id?: string | null;
  channel_title?: string | null;
  thumbnail?: string | null;
  published_at?: string | null;
  found_at?: string | null;
  duration?: string | null;
  watched?: number | null;
  watch_position?: number | null;
  watch_duration?: number | null;
  status?: string | null;
}

export function ticks(seconds: number): number {
  return Math.round(seconds * TICKS_PER_SECOND);
}

export function seconds(ticksValue: unknown): number {
  const value = Number(ticksValue);
  return Number.isFinite(value) && value > 0 ? value / TICKS_PER_SECOND : 0;
}

/** Jellyfin's date form: always fractions and a zone, which its clients parse strictly. */
export function jellyfinDate(raw: string | null | undefined): string | undefined {
  if (!raw) return undefined;
  const text = raw.trim();
  const normalized = /[zZ]|[+-]\d\d:?\d\d$/.test(text) ? text.replace(" ", "T") : `${text.replace(" ", "T")}Z`;
  const date = new Date(normalized);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString().replace(/\.(\d{3})Z$/, (_, ms: string) => `.${ms}0000Z`);
}

/** Changes when the picture does, so a client's image cache follows it. */
export function imageTag(video: ApiVideo): string {
  return createHash("sha1").update(video.thumbnail || video.video_id).digest("hex").slice(0, 16);
}

/** Where a video's picture is fetched from. */
export function thumbnailUrl(videoId: string, thumbnail: string | null | undefined): string {
  return thumbnail || `https://i.ytimg.com/vi/${encodeURIComponent(videoId)}/hqdefault.jpg`;
}

export function runTimeSeconds(video: ApiVideo): number | null {
  return durationSeconds(video.duration ?? null) ?? (video.watch_duration && video.watch_duration > 0 ? video.watch_duration : null);
}

export function videoItem(video: ApiVideo, serverId: string): Record<string, unknown> {
  const runtime = runTimeSeconds(video);
  const tag = imageTag(video);
  const published = jellyfinDate(video.published_at);
  const position = video.watch_position && video.watch_position > 0 ? video.watch_position : 0;
  const played = video.watched === 1;
  return {
    Id: video.video_id,
    ServerId: serverId,
    Name: video.title || video.video_id,
    SortName: (video.title || video.video_id).toLowerCase(),
    Type: "Movie",
    MediaType: "Video",
    IsFolder: false,
    ParentId: LIBRARY_ID,
    Overview: video.description || undefined,
    PremiereDate: published,
    DateCreated: jellyfinDate(video.found_at) ?? published,
    ProductionYear: published ? Number(published.slice(0, 4)) : undefined,
    RunTimeTicks: runtime ? ticks(runtime) : undefined,
    Studios: video.channel_title ? [{ Name: video.channel_title, Id: video.channel_id ?? "" }] : [],
    Genres: [],
    ProviderIds: {},
    MediaSourceCount: 1,
    ImageTags: { Primary: tag },
    BackdropImageTags: [tag],
    UserData: {
      PlaybackPositionTicks: played ? 0 : ticks(position),
      PlayedPercentage: runtime && position && !played ? Math.min(100, (position / runtime) * 100) : undefined,
      Played: played,
      PlayCount: played ? 1 : 0,
      IsFavorite: false,
      Key: video.video_id,
    },
  };
}

export function libraryView(serverId: string, name: string): Record<string, unknown> {
  return {
    Id: LIBRARY_ID,
    ServerId: serverId,
    Name: name,
    Type: "CollectionFolder",
    CollectionType: "movies",
    IsFolder: true,
    ImageTags: {},
    BackdropImageTags: [],
  };
}

export function queryResult(items: unknown[], total?: number, startIndex = 0): Record<string, unknown> {
  return { Items: items, TotalRecordCount: total ?? items.length, StartIndex: startIndex };
}
