import type { Context, Hono } from "hono";
import { bearerSessionToken } from "../deviceSessionAuth";
import { log } from "../logger";
import { MEDIA_TICKET_TTL_MS, mediaTicketPath } from "../mediaTickets";
import { mediaTickets, nativePlaybackAccess, nativePlaybackSource } from "../nativePlayback";
import { ytdlpStatus } from "../downloader";
import { answerMedia } from "../compat/invidious/mediaRoutes";
import { BEST_HEIGHT, cacheableVideoId } from "../compat/invidious/mediaCache";
import { RELAY_HLS_HEIGHT, relayHlsPlaylist, relayHlsReadiness, relayHlsTailResponse } from "../relayHls";
import { offlineCopy, offlineCopyPath } from "../offlineCopy";
import { localFileResponse } from "../compat/invidious/media";

type Environment = { Variables: { userId: number; sessionAdmin?: boolean; profileAdmin?: boolean } };

export function registerNativePlaybackRoutes(api: Hono<Environment>, currentUserId: (c: Context<Environment>) => number) {
  api.post("/videos/:id/playback-ticket", async (c) => {
    c.header("Cache-Control", "private, no-store");
    const sessionToken = bearerSessionToken(c.req.header("authorization"));
    if (!sessionToken) return c.json({ error: "device session required" }, 401);
    const userId = currentUserId(c);
    const videoId = c.req.param("id");
    const { source: asked, start } = await c.req.json().catch(() => ({}));
    // A copy for an iPhone or iPad to keep: the relay's H.264 and AAC in one
    // MP4. 202 with how far it is while the server fetches the two tracks.
    if (asked === "offline") {
      const access = await nativePlaybackAccess(userId, videoId);
      if ("error" in access) return c.json({ error: access.error }, access.status);
      if (access.child.is_child) return c.json({ error: "playback restricted" }, 403);
      const video = access.video;
      if (video.live_status === "live" || video.live_status === "upcoming" || video.members_only || video.is_private || video.is_unavailable) {
        return c.json({ error: "this video cannot be kept offline" }, 409);
      }
      if (!cacheableVideoId(videoId) || !await ytdlpStatus()) return c.json({ error: "offline copies unavailable" }, 503);
      const copy = offlineCopy(userId, videoId);
      if (copy.kind === "failed") return c.json({ error: copy.error }, 502);
      if (copy.kind === "pending") {
        c.header("Retry-After", "3");
        return c.json({ preparing: true, progress: copy.progress }, 202);
      }
      const ticket = mediaTickets.issue({ userId, videoId, sessionToken, kind: "offline" });
      return c.json({ ticket, url: `${mediaTicketPath({ videoId, kind: "offline" })}?media_ticket=${ticket}`, content_type: "progressive", size: copy.size, expires_in: MEDIA_TICKET_TTL_MS / 1000 });
    }
    // A client whose direct stream was refused by YouTube asks for the relay:
    // this server fetches the video with yt-dlp and serves it as it arrives.
    // "relay-hls" is the same in full quality, for a player that reads HLS.
    if (asked === "relay" || asked === "relay-hls") {
      const access = await nativePlaybackAccess(userId, videoId);
      if ("error" in access) return c.json({ error: access.error }, access.status);
      if (access.child.is_child) return c.json({ error: "playback restricted" }, 403);
      if (!cacheableVideoId(videoId) || !await ytdlpStatus()) return c.json({ error: "relay unavailable" }, 503);
      if (asked === "relay-hls") {
        const readiness = await relayHlsReadiness(userId, videoId, Number(start) || 0, 8_000);
        if (readiness === "failed") return c.json({ error: "relay stream unavailable" }, 502);
        if (readiness === "pending") {
          c.header("Retry-After", "2");
          return c.json({ preparing: true }, 202);
        }
      }
      const kind = asked === "relay" ? "relay" : "relay-hls";
      const ticket = mediaTickets.issue({ userId, videoId, sessionToken, kind });
      return c.json({ ticket, url: `${mediaTicketPath({ videoId, kind })}?media_ticket=${ticket}`, content_type: kind === "relay" ? "progressive" : "hls", expires_in: MEDIA_TICKET_TTL_MS / 1000 });
    }
    const source = await nativePlaybackSource(userId, videoId);
    if ("error" in source) return c.json({ error: source.error }, source.status);
    if ("preparing" in source) {
      c.header("Retry-After", "2");
      return c.json({ preparing: true }, 202);
    }
    const ticket = mediaTickets.issue({ userId, videoId, sessionToken, kind: source.kind });
    const path = mediaTicketPath({ videoId, kind: source.kind });
    return c.json({ ticket, url: `${path}${path.includes("?") ? "&" : "?"}media_ticket=${ticket}`, content_type: source.kind === "hls" || source.kind === "direct-hls" || source.kind === "live-hls" ? "hls" : "progressive", expires_in: MEDIA_TICKET_TTL_MS / 1000 });
  });

  api.put("/videos/:id/playback-ticket", async (c) => {
    c.header("Cache-Control", "private, no-store");
    const sessionToken = bearerSessionToken(c.req.header("authorization"));
    const { ticket } = await c.req.json().catch(() => ({}));
    const access = await nativePlaybackAccess(currentUserId(c), c.req.param("id"));
    if ("error" in access) return c.json({ error: access.error }, access.status);
    if (!sessionToken || typeof ticket !== "string" || !mediaTickets.renew(ticket, currentUserId(c), c.req.param("id"), sessionToken)) {
      return c.json({ error: "expired media ticket" }, 401);
    }
    return c.json({ expires_in: MEDIA_TICKET_TTL_MS / 1000 });
  });

  api.delete("/videos/:id/playback-ticket", async (c) => {
    c.header("Cache-Control", "private, no-store");
    const sessionToken = bearerSessionToken(c.req.header("authorization"));
    const { ticket, reason } = await c.req.json().catch(() => ({}));
    const entry = typeof ticket === "string" ? mediaTickets.read(ticket) : null;
    // A player that gave up on this stream says why, which is otherwise only
    // on the device: what AVPlayer reported, and the request it failed on.
    if (typeof reason === "string" && reason) {
      log.warn("native.stream_failed", { videoId: c.req.param("id"), kind: entry?.kind ?? null, userId: currentUserId(c), reason: reason.slice(0, 600) });
    }
    if (entry && entry.userId === currentUserId(c) && entry.videoId === c.req.param("id") && entry.sessionToken === sessionToken) mediaTickets.revoke(ticket);
    return c.json({ ok: true });
  });

  // Reached only with a relay media ticket: the ticket middleware has already
  // checked the ticket, its session and access, and set the user.
  api.get("/videos/:id/relay", async (c) => {
    if (c.req.query("media_ticket") === undefined) return c.json({ error: "media ticket required" }, 401);
    // Unbounded: AVPlayer refuses an answer shorter than the range it asked for.
    return answerMedia(c, currentUserId(c), c.req.param("id"), "muxed", BEST_HEIGHT, { bounded: false });
  });

  // Reached only with an offline media ticket: the copy made for a device.
  api.get("/videos/:id/offline.mp4", async (c) => {
    if (c.req.query("media_ticket") === undefined) return c.json({ error: "media ticket required" }, 401);
    return localFileResponse(offlineCopyPath(c.req.param("id")), c.req.header("range"), "video/mp4", false)
      ?? c.json({ error: "no offline copy" }, 404);
  });

  // Also reached only with a relay media ticket (see above).
  api.get("/videos/:id/relay-hls/:file", async (c) => {
    if (c.req.query("media_ticket") === undefined) return c.json({ error: "media ticket required" }, 401);
    const videoId = c.req.param("id");
    const file = c.req.param("file");
    if (file === "video.mp4" || file === "audio.mp4") {
      const kind = file === "video.mp4" ? "hls-video" : "hls-audio";
      return await relayHlsTailResponse(videoId, kind, c.req.header("range"))
        ?? answerMedia(c, currentUserId(c), videoId, kind, RELAY_HLS_HEIGHT, { bounded: false, quiet: true });
    }
    if (file !== "index.m3u8" && file !== "video.m3u8" && file !== "audio.m3u8") return c.json({ error: "not found" }, 404);
    const playlist = await relayHlsPlaylist(currentUserId(c), videoId, file);
    if (!playlist) return c.json({ error: "relay stream unavailable" }, 502);
    return new Response(playlist, { headers: { "Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store" } });
  });
}
