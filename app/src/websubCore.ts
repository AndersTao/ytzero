import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * The parts of WebSub support that need neither the database nor the network:
 * addresses, signatures, notification parsing and what to ask the hub next.
 * See websub.ts for the feature as a whole.
 */

export const WEBSUB_HUB_URL = "https://pubsubhubbub.appspot.com/subscribe";
export const WEBSUB_ENABLED_SETTING = "websub_enabled";
export const WEBSUB_CALLBACK_BASE_SETTING = "websub_callback_base";
export const WEBSUB_CALLBACK_PREFIX = "/api/websub/callback/";
/** The hub caps leases at about ten days; ask for that and renew ahead of it. */
export const WEBSUB_LEASE_SECONDS = 10 * 24 * 60 * 60;
const RENEW_BEFORE_MS = 2 * 24 * 60 * 60 * 1000;
const PENDING_RETRY_MS = 60 * 60 * 1000;
const MAX_REQUESTS_PER_PASS = 25;
const CHANNEL_ID = /^UC[A-Za-z0-9_-]{22}$/;

export type WebSubState = "pending" | "active" | "failed" | "unsubscribing";

export interface WebSubRow {
  channel_id: string;
  secret: string;
  callback_url: string;
  state: WebSubState;
  requested_at: string | null;
  verified_at: string | null;
  lease_expires_at: string | null;
  retry_after: string | null;
  last_notification_at: string | null;
  last_error: string | null;
}

// ---------- Pure helpers ----------

export function isChannelId(value: string | undefined | null): value is string {
  return typeof value === "string" && CHANNEL_ID.test(value);
}

export function topicFor(channelId: string): string {
  return `https://www.youtube.com/xml/feeds/videos.xml?channel_id=${channelId}`;
}

/** A usable public base address: http(s), no query or fragment, no trailing slash. */
export function normaliseCallbackBase(value: string | null | undefined): string | null {
  const raw = (value ?? "").trim();
  if (!raw) return null;
  let url: URL;
  try { url = new URL(raw); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (url.search || url.hash || url.username || url.password) return null;
  return `${url.origin}${url.pathname}`.replace(/\/+$/, "");
}

export function callbackUrlFor(base: string, channelId: string): string {
  return `${base}${WEBSUB_CALLBACK_PREFIX}${channelId}`;
}

/** Check `X-Hub-Signature: sha1=<hex>` (or sha256=…) against the subscription secret. */
export function verifyHubSignature(body: string, header: string | null | undefined, secret: string): boolean {
  const match = /^(sha1|sha256)=([0-9a-f]+)$/i.exec((header ?? "").trim());
  if (!match) return false;
  const expected = createHmac(match[1].toLowerCase(), secret).update(body, "utf8").digest();
  const given = Buffer.from(match[2], "hex");
  return given.length === expected.length && timingSafeEqual(given, expected);
}

export interface WebSubNotification {
  channelId: string;
  videoIds: string[];
}

/** The uploads an Atom notification announces. Deleted entries are left out. */
export function parseNotification(body: string): WebSubNotification | null {
  const entries = body.match(/<entry[\s>][\s\S]*?<\/entry>/g) ?? [];
  let channelId: string | null = null;
  const videoIds: string[] = [];
  for (const entry of entries) {
    const video = /<yt:videoId>([A-Za-z0-9_-]{11})<\/yt:videoId>/.exec(entry)?.[1];
    const channel = /<yt:channelId>(UC[A-Za-z0-9_-]{22})<\/yt:channelId>/.exec(entry)?.[1];
    if (!video || !channel) continue;
    channelId ??= channel;
    if (channel === channelId && !videoIds.includes(video)) videoIds.push(video);
  }
  return channelId ? { channelId, videoIds } : null;
}

const parseTime = (value: string | null | undefined) => {
  if (!value) return null;
  const parsed = Date.parse(value.endsWith("Z") ? value : `${value}Z`);
  return Number.isFinite(parsed) ? parsed : null;
};

export type WebSubAction = { kind: "subscribe"; channelId: string } | { kind: "unsubscribe"; channelId: string };

/**
 * What one maintenance pass should ask the hub, given the followed channels,
 * the stored subscriptions and the callback base in effect (null when push is
 * off or has no public address). Bounded, so a large library is spread over a
 * few passes rather than sent to the hub at once.
 */
export function planWebSub(
  followed: readonly string[],
  rows: readonly WebSubRow[],
  base: string | null,
  nowMs: number,
  limit = MAX_REQUESTS_PER_PASS,
): WebSubAction[] {
  const actions: WebSubAction[] = [];
  const byChannel = new Map(rows.map((row) => [row.channel_id, row]));
  const wanted = base ? new Set(followed.filter(isChannelId)) : new Set<string>();

  for (const row of rows) {
    if (!wanted.has(row.channel_id) && row.state !== "unsubscribing") actions.push({ kind: "unsubscribe", channelId: row.channel_id });
  }
  if (base) {
    for (const channelId of wanted) {
      const row = byChannel.get(channelId);
      if (!row || row.callback_url !== callbackUrlFor(base, channelId)) {
        actions.push({ kind: "subscribe", channelId });
        continue;
      }
      const retryAfter = parseTime(row.retry_after);
      if (row.state === "failed" || row.state === "unsubscribing") {
        if (retryAfter === null || retryAfter <= nowMs) actions.push({ kind: "subscribe", channelId });
      } else if (row.state === "pending") {
        const requested = parseTime(row.requested_at);
        if (requested === null || nowMs - requested >= PENDING_RETRY_MS) actions.push({ kind: "subscribe", channelId });
      } else {
        const expires = parseTime(row.lease_expires_at);
        if (expires === null || expires - nowMs <= RENEW_BEFORE_MS) actions.push({ kind: "subscribe", channelId });
      }
    }
  }
  return actions.slice(0, Math.max(0, limit));
}

/** Backoff for a subscription the hub refused: 15 min, doubling, at most a day. */
export function retryDelayMs(previousRetryAfter: string | null, previousRequestedAt: string | null): number {
  const after = parseTime(previousRetryAfter);
  const requested = parseTime(previousRequestedAt);
  const last = after !== null && requested !== null ? Math.max(0, after - requested) : 0;
  return Math.min(24 * 60 * 60 * 1000, Math.max(15 * 60 * 1000, last * 2));
}
