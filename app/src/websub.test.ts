import { describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";

// The pure helpers only; the database-backed flow runs in app/tests/websubHarness.ts.
import {
  callbackUrlFor, isChannelId, normaliseCallbackBase, parseNotification, planWebSub, retryDelayMs, topicFor, verifyHubSignature,
} from "./websubCore";

const CHANNEL = "UC" + "a".repeat(22);
const OTHER = "UC" + "b".repeat(22);
const NOW = Date.parse("2026-11-16T12:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();
const row = (channelId: string, overrides: Record<string, unknown> = {}) => ({
  channel_id: channelId, secret: "s", callback_url: callbackUrlFor("https://tube.example.com", channelId), state: "active",
  requested_at: iso(NOW - 3_600_000), verified_at: iso(NOW - 3_600_000), lease_expires_at: iso(NOW + 8 * 86_400_000),
  retry_after: null, last_notification_at: null, last_error: null, ...overrides,
}) as any;

describe("WebSub addresses", () => {
  test("accepts only http(s) bases and drops a trailing slash", () => {
    expect(normaliseCallbackBase("https://tube.example.com/")).toBe("https://tube.example.com");
    expect(normaliseCallbackBase(" https://example.com/ytzero/ ")).toBe("https://example.com/ytzero");
    expect(normaliseCallbackBase("ftp://example.com")).toBe(null);
    expect(normaliseCallbackBase("https://example.com/?a=1")).toBe(null);
    expect(normaliseCallbackBase("https://user:pw@example.com")).toBe(null);
    expect(normaliseCallbackBase("")).toBe(null);
  });

  test("builds the hub topic and the per-channel callback", () => {
    expect(topicFor(CHANNEL)).toBe(`https://www.youtube.com/xml/feeds/videos.xml?channel_id=${CHANNEL}`);
    expect(callbackUrlFor("https://tube.example.com", CHANNEL)).toBe(`https://tube.example.com/api/websub/callback/${CHANNEL}`);
    expect(isChannelId(CHANNEL)).toBe(true);
    expect(isChannelId("UC123")).toBe(false);
  });
});

describe("hub signatures", () => {
  const body = "<feed>hello</feed>";
  const sign = (algorithm: string, secret: string) => `${algorithm}=${createHmac(algorithm, secret).update(body).digest("hex")}`;

  test("accepts a correct sha1 or sha256 signature", () => {
    expect(verifyHubSignature(body, sign("sha1", "secret"), "secret")).toBe(true);
    expect(verifyHubSignature(body, sign("sha256", "secret"), "secret")).toBe(true);
  });

  test("rejects a wrong secret, a changed body or a missing header", () => {
    expect(verifyHubSignature(body, sign("sha1", "other"), "secret")).toBe(false);
    expect(verifyHubSignature(body + " ", sign("sha1", "secret"), "secret")).toBe(false);
    expect(verifyHubSignature(body, undefined, "secret")).toBe(false);
    expect(verifyHubSignature(body, "md5=abc", "secret")).toBe(false);
  });
});

describe("notifications", () => {
  test("reads the announced uploads and skips deleted entries", () => {
    const xml = `<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:at="http://purl.org/atompub/tombstones/1.0">
      <at:deleted-entry ref="yt:video:zzzzzzzzzzz" when="2026-11-16T10:00:00+00:00"/>
      <entry><id>yt:video:abcdefghijk</id><yt:videoId>abcdefghijk</yt:videoId><yt:channelId>${CHANNEL}</yt:channelId><title>New</title></entry>
      <entry><yt:videoId>abcdefghijk</yt:videoId><yt:channelId>${CHANNEL}</yt:channelId></entry>
    </feed>`;
    expect(parseNotification(xml)).toEqual({ channelId: CHANNEL, videoIds: ["abcdefghijk"] });
    expect(parseNotification(`<feed><at:deleted-entry ref="yt:video:zzzzzzzzzzz"/></feed>`)).toBe(null);
  });
});

describe("planning subscriptions", () => {
  const base = "https://tube.example.com";

  test("subscribes new channels and unsubscribes unfollowed ones", () => {
    expect(planWebSub([CHANNEL], [row(OTHER)], base, NOW)).toEqual([
      { kind: "unsubscribe", channelId: OTHER },
      { kind: "subscribe", channelId: CHANNEL },
    ]);
  });

  test("leaves a fresh lease alone and renews one about to lapse", () => {
    expect(planWebSub([CHANNEL], [row(CHANNEL)], base, NOW)).toEqual([]);
    expect(planWebSub([CHANNEL], [row(CHANNEL, { lease_expires_at: iso(NOW + 86_400_000) })], base, NOW))
      .toEqual([{ kind: "subscribe", channelId: CHANNEL }]);
  });

  test("resubscribes when the public address changed", () => {
    expect(planWebSub([CHANNEL], [row(CHANNEL)], "https://new.example.com", NOW)).toEqual([{ kind: "subscribe", channelId: CHANNEL }]);
  });

  test("waits out a failed subscription's backoff and an unanswered request", () => {
    expect(planWebSub([CHANNEL], [row(CHANNEL, { state: "failed", retry_after: iso(NOW + 60_000) })], base, NOW)).toEqual([]);
    expect(planWebSub([CHANNEL], [row(CHANNEL, { state: "failed", retry_after: iso(NOW - 60_000) })], base, NOW)).toHaveLength(1);
    expect(planWebSub([CHANNEL], [row(CHANNEL, { state: "pending", requested_at: iso(NOW - 60_000) })], base, NOW)).toEqual([]);
    expect(planWebSub([CHANNEL], [row(CHANNEL, { state: "pending", requested_at: iso(NOW - 2 * 3_600_000) })], base, NOW)).toHaveLength(1);
  });

  test("turned off, everything is unsubscribed", () => {
    expect(planWebSub([CHANNEL], [row(CHANNEL), row(OTHER)], null, NOW)).toEqual([
      { kind: "unsubscribe", channelId: CHANNEL },
      { kind: "unsubscribe", channelId: OTHER },
    ]);
  });

  test("spreads a large library over several passes", () => {
    const many = Array.from({ length: 60 }, (_, i) => "UC" + String(i).padStart(22, "x"));
    expect(planWebSub(many, [], base, NOW)).toHaveLength(25);
  });

  test("backs off from 15 minutes, doubling, up to a day", () => {
    expect(retryDelayMs(null, null)).toBe(15 * 60_000);
    expect(retryDelayMs(iso(NOW + 30 * 60_000), iso(NOW))).toBe(60 * 60_000);
    expect(retryDelayMs(iso(NOW + 20 * 3_600_000), iso(NOW))).toBe(24 * 3_600_000);
  });
});
