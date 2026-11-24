import { createHash } from "node:crypto";
import { getUserSetting } from "./db";
import { log } from "./logger";

/**
 * SponsorBlock for the players that are not the web's: the iPhone, iPad and
 * Apple TV apps and the LG page.
 *
 * The web player asks SponsorBlock itself, from the browser. These ask the
 * server instead, which answers by the profile's own settings (Settings →
 * Privacy → SponsorBlock: on or off, and which kinds to skip), so the TV skips
 * what the web skips without a settings screen of its own.
 *
 * Asked the way DeArrow is asked here: by the first four characters of the
 * video id's SHA-256, which SponsorBlock answers with every video sharing them.
 * The service learns a bucket of thousands of videos, not which one is played.
 */
const API = "https://sponsor.ajay.app/api/skipSegments";
const CACHE_TTL_MS = 30 * 60_000;
const CACHE_LIMIT = 2_000;

export const SKIP_CATEGORIES = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic", "filler"] as const;

export interface SkipSegment {
  category: string;
  start: number;
  end: number;
  uuid: string;
}

interface ApiSegment {
  category?: string;
  actionType?: string;
  segment?: [number, number];
  UUID?: string;
}

const cache = new Map<string, { expiresAt: number; value: Promise<Record<string, ApiSegment[]>> }>();

export function skipHashPrefix(videoId: string): string {
  return createHash("sha256").update(videoId).digest("hex").slice(0, 4);
}

/** The kinds this profile has SponsorBlock skip, or nothing when it is off. */
export function profileSkipCategories(userId: number): string[] {
  if (getUserSetting(userId, "sponsorblock_enabled") !== "1") return [];
  try {
    const chosen = JSON.parse(getUserSetting(userId, "sponsorblock_categories") || '["sponsor"]');
    return Array.isArray(chosen) ? chosen.filter((c): c is string => (SKIP_CATEGORIES as readonly string[]).includes(c)) : [];
  } catch {
    return [];
  }
}

/** What a player skips: only "skip" segments of the chosen kinds, in order, each with a stable id. */
export function selectSkipSegments(videoId: string, segments: ApiSegment[] | undefined, categories: string[]): SkipSegment[] {
  const wanted = new Set(categories);
  return (segments ?? []).flatMap((segment, index) => {
    const start = Number(segment.segment?.[0]);
    const end = Number(segment.segment?.[1]);
    const category = segment.category ?? "";
    if (segment.actionType !== "skip" || !wanted.has(category) || !Number.isFinite(start) || !Number.isFinite(end) || end <= start) return [];
    return [{ category, start, end, uuid: segment.UUID || `${videoId}:${category}:${start}:${end}:${index}` }];
  }).sort((a, b) => a.start - b.start);
}

function segmentsForPrefix(prefix: string): Promise<Record<string, ApiSegment[]>> {
  const now = Date.now();
  const cached = cache.get(prefix);
  if (cached && cached.expiresAt > now) return cached.value;
  if (cache.size >= CACHE_LIMIT) {
    for (const [key, entry] of cache) if (entry.expiresAt <= now) cache.delete(key);
    if (cache.size >= CACHE_LIMIT) cache.delete(cache.keys().next().value!);
  }
  // Every kind at once: the profile's choice is applied here, so one answer serves them all.
  const query = new URLSearchParams({ categories: JSON.stringify(SKIP_CATEGORIES), actionTypes: JSON.stringify(["skip"]) });
  const value = fetch(`${API}/${prefix}?${query}`, {
    headers: { "X-Client-Name": "YTZero" },
    signal: AbortSignal.timeout(8_000),
  }).then(async (response) => {
    if (response.status === 404) return {};
    if (!response.ok) throw new Error(`SponsorBlock returned ${response.status}`);
    const list = await response.json() as Array<{ videoID?: string; segments?: ApiSegment[] }>;
    return Object.fromEntries(list.filter((entry) => entry.videoID).map((entry) => [entry.videoID!, entry.segments ?? []]));
  }).catch((error) => {
    log.warn("sponsorblock.fetch_failed", { prefix, error: error instanceof Error ? error.message : String(error) });
    cache.delete(prefix); // not remembered: the next video asks again
    return {};
  });
  cache.set(prefix, { expiresAt: now + CACHE_TTL_MS, value });
  return value;
}

export async function skipSegmentsFor(videoId: string, categories: string[]): Promise<SkipSegment[]> {
  if (categories.length === 0) return [];
  const byVideo = await segmentsForPrefix(skipHashPrefix(videoId));
  return selectSkipSegments(videoId, byVideo[videoId], categories);
}
