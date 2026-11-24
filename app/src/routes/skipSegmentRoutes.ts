import type { Context, Hono } from "hono";
import { profileSkipCategories, skipSegmentsFor } from "../skipSegments";
import { validYouTubeVideoId } from "../youtubeComments";

type ApiEnvironment = { Variables: { userId: number; sessionAdmin?: boolean; profileAdmin?: boolean } };
type Api = Hono<ApiEnvironment>;
type ApiContext = Context<ApiEnvironment>;

/**
 * The parts of a video a native player skips, by the profile's SponsorBlock
 * settings. A skip is reported back on the route the web player uses
 * (POST /videos/:id/sponsorblock-skip), so Insights counts them all.
 */
export function registerSkipSegmentRoutes(api: Api, currentUserId: (context: ApiContext) => number): void {
  api.get("/videos/:id/skip-segments", async (c) => {
    const videoId = c.req.param("id");
    if (!validYouTubeVideoId(videoId)) return c.json({ error: "invalid video id" }, 400);
    const categories = profileSkipCategories(currentUserId(c));
    return c.json({ enabled: categories.length > 0, segments: await skipSegmentsFor(videoId, categories) });
  });
}
