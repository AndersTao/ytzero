import type { Context, Hono } from "hono";
import { database } from "../database";
import { getUserSetting, setUserSetting } from "../db";
import { childLocalOnly } from "../childTime";
import { syncUserPlaylistOfflinePolicy } from "../downloader";
import { shortsUiVisibilitySql } from "../feedQuery";
import { ensureOnDemandVideo, OnDemandVideoImportError } from "../onDemandVideoImport";
import { refreshDiscoveryInBackground } from "../plugins";
import { videoExistsStmt, type VideoRow } from "../videoRoutesSupport";
import { videoSelect } from "../videoSelect";
import { validYouTubeVideoId } from "../youtubeComments";
import { normalizeLanguage, type Language } from "../../../shared/uiLanguages";

/*
 * "Save for later": videos picked from anywhere (the browser extension's
 * right-click on YouTube) go to one ordinary playlist per profile, which Main
 * shows as its own row. It stays a normal playlist, so it can be opened,
 * reordered, renamed or emptied like any other. The profile setting holds its
 * portable id, which survives a backup and restore.
 */
export const SAVED_FOR_LATER_SETTING = "saved_for_later_playlist";
const MAIN_ROW_LIMIT = 60;

const PLAYLIST_NAMES: Record<Language, string> = {
  en: "Saved for later",
  pl: "Zapisane na później",
  de: "Für später gespeichert",
  fr: "Enregistré pour plus tard",
  es: "Guardado para más tarde",
  "pt-BR": "Salvo para depois",
  ru: "Отложенное",
  ja: "後で見る",
  hu: "Későbbre mentve",
  da: "Gemt til senere",
};

export function savedForLaterPlaylistName(language: string | null | undefined): string {
  return PLAYLIST_NAMES[normalizeLanguage(language)];
}

type ApiEnvironment = { Variables: { userId: number; sessionAdmin?: boolean; profileAdmin?: boolean } };
type Api = Hono<ApiEnvironment>;
type ApiContext = Context<ApiEnvironment>;
type PlaylistRef = { id: number; portable_uuid: string; name: string };

async function existingPlaylist(uid: number): Promise<PlaylistRef | null> {
  const uuid = getUserSetting(uid, SAVED_FOR_LATER_SETTING);
  if (!uuid) return null;
  return (await database.prepare("SELECT id, portable_uuid, name FROM user_playlists WHERE portable_uuid = ? AND user_id = ?")
    .get(uuid, uid) as PlaylistRef | undefined) ?? null;
}

// Two saves at once must not each create a playlist.
const creating = new Map<number, Promise<PlaylistRef>>();
async function ensurePlaylist(uid: number): Promise<PlaylistRef> {
  const found = await existingPlaylist(uid);
  if (found) return found;
  const pending = creating.get(uid);
  if (pending) return pending;
  const created = (async () => {
    const nextOrder = await database.prepare("SELECT COALESCE(MAX(sort_order), -1) + 1 AS sort_order FROM user_playlists WHERE user_id = ?").get(uid) as { sort_order: number };
    const row = await database.prepare(
      "INSERT INTO user_playlists (name, icon, sort_order, user_id, portable_uuid) VALUES (?, ?, ?, ?, ?) RETURNING id, portable_uuid, name",
    ).get(savedForLaterPlaylistName(getUserSetting(uid, "language")), "Clock", nextOrder.sort_order, uid, crypto.randomUUID()) as PlaylistRef;
    await setUserSetting(uid, SAVED_FOR_LATER_SETTING, row.portable_uuid);
    return row;
  })();
  creating.set(uid, created);
  try {
    return await created;
  } finally {
    creating.delete(uid);
  }
}

export function registerSavedForLaterRoutes(
  api: Api,
  access: {
    currentUserId: (context: ApiContext) => number;
    attachTags: (userId: number, videos: VideoRow[]) => Promise<Array<VideoRow & Record<string, unknown>>>;
  },
): void {
  const { currentUserId, attachTags } = access;

  // The row on Main: newest first, leaving out what has been watched,
  // rejected, or can no longer be played. The playlist page still lists everything.
  api.get("/saved-for-later", async (c) => {
    const uid = currentUserId(c);
    const playlist = await existingPlaylist(uid);
    if (!playlist) return c.json({ playlist: null, videos: [] });
    const rows = await database.prepare(
      `SELECT saved.*, upv.added_at
       FROM (${videoSelect(uid)}) saved
       JOIN user_playlist_videos upv ON upv.video_id = saved.video_id
       WHERE upv.playlist_id = ?
         AND COALESCE(saved.watched, 0) = 0
         AND COALESCE(saved.status, '') <> 'archived'
         AND COALESCE(saved.is_unavailable, 0) = 0
         AND COALESCE(saved.is_private, 0) = 0
         AND ${shortsUiVisibilitySql(uid, "saved")}
       ORDER BY upv.added_at DESC, upv.position DESC
       LIMIT ${MAIN_ROW_LIMIT}`,
    ).all(playlist.id) as VideoRow[];
    return c.json({ playlist, videos: await attachTags(uid, rows) });
  });

  api.post("/saved-for-later", async (c) => {
    const uid = currentUserId(c);
    const body = await c.req.json().catch(() => null) as { video_id?: unknown } | null;
    const videoId = typeof body?.video_id === "string" ? body.video_id : "";
    if (!validYouTubeVideoId(videoId)) return c.json({ error: "invalid video_id" }, 400);
    if (!await videoExistsStmt.get(videoId)) {
      if (childLocalOnly(uid)) return c.json({ error: "restricted" }, 403);
      try {
        await ensureOnDemandVideo(videoId, uid);
      } catch (error) {
        if (error instanceof OnDemandVideoImportError) return c.json({ error: error.message }, error.status);
        throw error;
      }
    }
    // Saving is asking for it again, so an earlier rejection no longer applies.
    await database.prepare("UPDATE user_videos SET status = 'inbox' WHERE user_id = ? AND video_id = ? AND status = 'archived'").run(uid, videoId);
    const playlist = await ensurePlaylist(uid);
    // Saving again moves it back to the front of the row.
    const existing = await database.prepare("SELECT 1 FROM user_playlist_videos WHERE playlist_id = ? AND video_id = ?").get(playlist.id, videoId);
    if (existing) {
      await database.prepare("UPDATE user_playlist_videos SET added_at = datetime('now') WHERE playlist_id = ? AND video_id = ?").run(playlist.id, videoId);
    } else {
      await database.prepare(`INSERT INTO user_playlist_videos (playlist_id, video_id, position)
        SELECT ?, ?, COALESCE(MAX(position), -1) + 1 FROM user_playlist_videos WHERE playlist_id = ?`)
        .run(playlist.id, videoId, playlist.id);
    }
    await syncUserPlaylistOfflinePolicy(uid, playlist.id);
    refreshDiscoveryInBackground(uid);
    return c.json({ ok: true, playlist, already: Boolean(existing) });
  });
}
