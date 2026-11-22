import type { Video } from "./apiTypes";
import { addCalendarDays, appDayKey, calendarDayDifference, formatCalendarDay } from "./dateTime";

/** Today and the six days before it get a heading each; anything older shares one. */
export const FEED_DAYS = 7;

export interface FeedDay {
  /** 0 today, 1–6 the days before it, 7 everything older (or undated). */
  daysAgo: number;
  videos: Video[];
}

/**
 * The feed cut into days by the date it is sorted on — when a video came out,
 * or when it arrived here — in the profile's time zone. Days come newest
 * first, and each keeps the order its videos were given in.
 */
export function feedDays(videos: Video[], sort: "published" | "arrival", timeZone: string, now: Date = new Date()): FeedDay[] {
  const today = appDayKey(now, timeZone);
  const byDay = new Map<number, Video[]>();
  for (const video of videos) {
    const stamp = sort === "arrival" ? video.found_at : video.published_at;
    const back = stamp ? calendarDayDifference(today, appDayKey(stamp, timeZone)) : FEED_DAYS;
    const daysAgo = Number.isFinite(back) ? Math.min(FEED_DAYS, Math.max(0, back)) : FEED_DAYS;
    const list = byDay.get(daysAgo);
    if (list) list.push(video);
    else byDay.set(daysAgo, [video]);
  }
  return [...byDay.entries()].sort(([a], [b]) => a - b).map(([daysAgo, list]) => ({ daysAgo, videos: list }));
}

/** The weekday name for a day 1–6 days back, capitalised ("Lørdag", not "lørdag"). */
export function feedWeekday(daysAgo: number, locale: string, timeZone: string, now: Date = new Date()): string {
  const name = formatCalendarDay(addCalendarDays(appDayKey(now, timeZone), -daysAgo), locale, { weekday: "long" });
  return name.charAt(0).toLocaleUpperCase(locale) + name.slice(1);
}
