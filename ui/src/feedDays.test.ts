import { describe, expect, test } from "bun:test";
import type { Video } from "./apiTypes";
import { feedDays, feedWeekday } from "./feedDays";

const video = (id: string, published: string | null, found = published): Video =>
  ({ video_id: id, published_at: published, found_at: found } as unknown as Video);

// Sunday 22 November 2026, early afternoon in Copenhagen.
const now = new Date("2026-11-22T13:00:00Z");

describe("feed days", () => {
  test("today, each of the six days before it, then everything older together", () => {
    const days = feedDays([
      video("today", "2026-11-22T08:00:00Z"),
      video("saturday", "2026-11-21T20:00:00Z"),
      video("monday", "2026-11-16T09:00:00Z"),
      video("lastSunday", "2026-11-15T12:00:00Z"),
      video("undated", null),
    ], "published", "Europe/Copenhagen", now);
    expect(days.map((day) => [day.daysAgo, day.videos.map((v) => v.video_id)])).toEqual([
      [0, ["today"]],
      [1, ["saturday"]],
      [6, ["monday"]],
      [7, ["lastSunday", "undated"]],
    ]);
  });

  test("days follow the profile's time zone, not UTC", () => {
    // 23:30 UTC on Saturday is already Sunday in Copenhagen.
    const [day] = feedDays([video("late", "2026-11-21T23:30:00Z")], "published", "Europe/Copenhagen", now);
    expect(day.daysAgo).toBe(0);
  });

  test("the arrival sort cuts by when a video arrived", () => {
    const [day] = feedDays([video("found", "2026-10-01T10:00:00Z", "2026-11-22T09:00:00Z")], "arrival", "Europe/Copenhagen", now);
    expect(day.daysAgo).toBe(0);
  });

  test("a premiere ahead counts as today", () => {
    const [day] = feedDays([video("soon", "2026-11-25T10:00:00Z")], "published", "Europe/Copenhagen", now);
    expect(day.daysAgo).toBe(0);
  });

  test("weekday names are capitalised in the interface language", () => {
    expect(feedWeekday(1, "da-DK", "Europe/Copenhagen", now)).toBe("Lørdag");
    expect(feedWeekday(6, "en-US", "Europe/Copenhagen", now)).toBe("Monday");
  });
});
