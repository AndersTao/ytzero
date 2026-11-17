import type { Hono } from "hono";
import { database } from "../database";

/**
 * Per profile: leave one channel's livestreams — on now, announced or
 * recorded — out of the feed and the Live page (see channelLiveHiddenSql).
 * They stay on the channel's own page.
 */
export function registerChannelLiveFeedRoutes(api: Hono<any>): void {
  api.put("/channels/:id/live-feed", async (c) => {
    const { visibility } = await c.req.json<{ visibility: unknown }>();
    if (visibility !== "default" && visibility !== "hidden") {
      return c.json({ error: "visibility must be default or hidden" }, 400);
    }
    await database.prepare(
      `INSERT INTO user_channels (user_id, channel_id, followed, live_feed_visibility) VALUES (?, ?, 0, ?)
       ON CONFLICT(user_id, channel_id) DO UPDATE SET live_feed_visibility = excluded.live_feed_visibility`
    ).run(c.get("userId") as number, c.req.param("id"), visibility);
    return c.json({ ok: true, visibility });
  });
}
