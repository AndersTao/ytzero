import { randomBytes } from "node:crypto";
import { database } from "./database";
import { getSetting, setSetting } from "./db";
import { log } from "./logger";
import { syncChannelRecent } from "./refresher";
import {
  callbackUrlFor, isChannelId, normaliseCallbackBase, parseNotification, planWebSub, retryDelayMs, topicFor, verifyHubSignature,
  WEBSUB_CALLBACK_BASE_SETTING, WEBSUB_ENABLED_SETTING, WEBSUB_HUB_URL, WEBSUB_LEASE_SECONDS, type WebSubRow, type WebSubState,
} from "./websubCore";

export { WEBSUB_CALLBACK_PREFIX } from "./websubCore";

/**
 * Push notifications from YouTube over WebSub (PubSubHubbub).
 *
 * Polling a channel's RSS feed finds a new upload only when that channel's turn
 * comes round, and for a channel that has been quiet for a week that is every
 * twelve hours. YouTube also announces uploads through Google's public hub:
 * an instance subscribes once per channel, and the hub posts to it within
 * minutes of an upload. Nothing is asked of YouTube more often than before —
 * the hub calls in, and only the channel it names is then read.
 *
 * Everything that identifies an installation is configured in the app and
 * stored in its database: whether this is on, and the public address the hub
 * should call. Nothing about any particular setup lives in the code.
 *
 * Polling stays as it is. A notification that never arrives (a lapsed lease, a
 * hub outage) is then only as late as it would have been without push.
 */

// ---------- Configuration ----------

export interface WebSubConfig {
  enabled: boolean;
  /** What an administrator typed, if anything. */
  configuredBase: string | null;
  /** The base actually used: the configured one, or APP_URL when none is set. */
  base: string | null;
}

export function webSubConfig(): WebSubConfig {
  const enabled = getSetting(WEBSUB_ENABLED_SETTING) === "1";
  const configuredBase = normaliseCallbackBase(getSetting(WEBSUB_CALLBACK_BASE_SETTING));
  const base = configuredBase ?? normaliseCallbackBase(process.env.APP_URL);
  return { enabled, configuredBase, base: enabled ? base : null };
}

export async function saveWebSubConfig(input: { enabled: boolean; callbackBase: string }): Promise<WebSubConfig> {
  const trimmed = input.callbackBase.trim();
  if (trimmed && !normaliseCallbackBase(trimmed)) throw new Error("invalid callback address");
  await setSetting(WEBSUB_CALLBACK_BASE_SETTING, trimmed ? normaliseCallbackBase(trimmed)! : "");
  await setSetting(WEBSUB_ENABLED_SETTING, input.enabled ? "1" : "0");
  // Take effect now rather than at the next timer tick.
  void maintainWebSub().catch((error) => log.warn("websub.maintenance_failed", { error: errorText(error) }));
  return webSubConfig();
}

// ---------- Storage ----------

const errorText = (error: unknown) => error instanceof Error ? error.message : String(error);
const isoNow = (ms = Date.now()) => new Date(ms).toISOString();

export async function webSubRows(): Promise<WebSubRow[]> {
  return await database.prepare("SELECT * FROM websub_subscriptions").all() as WebSubRow[];
}

export async function webSubRow(channelId: string): Promise<WebSubRow | null> {
  return (await database.prepare("SELECT * FROM websub_subscriptions WHERE channel_id = ?").get(channelId) as WebSubRow | null) ?? null;
}

async function followedChannelIds(): Promise<string[]> {
  const rows = await database.prepare("SELECT DISTINCT channel_id FROM user_channels WHERE followed = 1").all() as { channel_id: string }[];
  return rows.map((row) => row.channel_id);
}

export async function isFollowed(channelId: string): Promise<boolean> {
  return Boolean(await database.prepare("SELECT 1 FROM user_channels WHERE channel_id = ? AND followed = 1 LIMIT 1").get(channelId));
}

// ---------- Talking to the hub ----------

type HubFetch = (url: string, init: RequestInit) => Promise<Response>;
let hubFetch: HubFetch = (url, init) => fetch(url, init);
/** Tests replace the network. */
export function setWebSubHubFetch(fetcher: HubFetch | null): void {
  hubFetch = fetcher ?? ((url, init) => fetch(url, init));
}

async function askHub(mode: "subscribe" | "unsubscribe", channelId: string, callback: string, secret: string): Promise<void> {
  const form = new URLSearchParams({
    "hub.mode": mode,
    "hub.topic": topicFor(channelId),
    "hub.callback": callback,
    "hub.verify": "async",
  });
  if (mode === "subscribe") {
    form.set("hub.secret", secret);
    form.set("hub.lease_seconds", String(WEBSUB_LEASE_SECONDS));
  }
  const response = await hubFetch(WEBSUB_HUB_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
    signal: AbortSignal.timeout(15_000),
  });
  if (response.status !== 202 && response.status !== 204) {
    const text = (await response.text().catch(() => "")).slice(0, 200);
    throw new Error(`hub answered ${response.status}${text ? `: ${text}` : ""}`);
  }
}

async function subscribe(channelId: string, base: string, existing: WebSubRow | undefined): Promise<void> {
  const callback = callbackUrlFor(base, channelId);
  const secret = existing?.secret ?? randomBytes(32).toString("hex");
  const now = isoNow();
  await database.prepare(`
    INSERT INTO websub_subscriptions (channel_id, secret, callback_url, state, requested_at)
    VALUES (?, ?, ?, 'pending', ?)
    ON CONFLICT(channel_id) DO UPDATE SET callback_url = excluded.callback_url, requested_at = excluded.requested_at,
      state = CASE WHEN websub_subscriptions.state = 'active' AND websub_subscriptions.callback_url = excluded.callback_url THEN 'active' ELSE 'pending' END
  `).run(channelId, secret, callback, now);
  try {
    await askHub("subscribe", channelId, callback, secret);
    await database.prepare("UPDATE websub_subscriptions SET retry_after = NULL, last_error = NULL WHERE channel_id = ?").run(channelId);
  } catch (error) {
    const delay = retryDelayMs(existing?.retry_after ?? null, existing?.requested_at ?? null);
    await database.prepare("UPDATE websub_subscriptions SET state = 'failed', last_error = ?, retry_after = ? WHERE channel_id = ?")
      .run(errorText(error), isoNow(Date.now() + delay), channelId);
    log.warn("websub.subscribe_failed", { channelId, error: errorText(error) });
  }
}

async function unsubscribe(row: WebSubRow): Promise<void> {
  await database.prepare("UPDATE websub_subscriptions SET state = 'unsubscribing' WHERE channel_id = ?").run(row.channel_id);
  try {
    await askHub("unsubscribe", row.channel_id, row.callback_url, row.secret);
  } catch (error) {
    // The lease runs out on its own within ten days; nothing to retry.
    log.info("websub.unsubscribe_failed", { channelId: row.channel_id, error: errorText(error) });
  }
  await database.prepare("DELETE FROM websub_subscriptions WHERE channel_id = ?").run(row.channel_id);
}

let maintaining = false;

/** One pass: subscribe followed channels, renew leases, drop the rest. */
export async function maintainWebSub(nowMs = Date.now()): Promise<{ subscribed: number; unsubscribed: number }> {
  if (maintaining) return { subscribed: 0, unsubscribed: 0 };
  maintaining = true;
  try {
    const config = webSubConfig();
    const rows = await webSubRows();
    if (!config.base && rows.length === 0) return { subscribed: 0, unsubscribed: 0 };
    const followed = config.base ? await followedChannelIds() : [];
    const actions = planWebSub(followed, rows, config.base, nowMs);
    const byChannel = new Map(rows.map((row) => [row.channel_id, row]));
    let subscribed = 0, unsubscribed = 0;
    for (const action of actions) {
      const row = byChannel.get(action.channelId);
      if (action.kind === "unsubscribe" && row) { await unsubscribe(row); unsubscribed++; }
      if (action.kind === "subscribe" && config.base) { await subscribe(action.channelId, config.base, row); subscribed++; }
    }
    if (subscribed || unsubscribed) log.info("websub.maintenance", { subscribed, unsubscribed, base: Boolean(config.base) });
    return { subscribed, unsubscribed };
  } finally {
    maintaining = false;
  }
}

// ---------- Callback handling ----------

export interface VerificationQuery {
  mode: string | undefined;
  topic: string | undefined;
  challenge: string | undefined;
  leaseSeconds: string | undefined;
}

/** The hub confirming a (un)subscription we asked for. Returns the challenge to echo, or null to refuse. */
export async function handleVerification(channelId: string, query: VerificationQuery, nowMs = Date.now()): Promise<string | null> {
  if (!isChannelId(channelId) || !query.challenge || query.topic !== topicFor(channelId)) return null;
  const row = await webSubRow(channelId);
  if (query.mode === "subscribe") {
    const config = webSubConfig();
    if (!row || !config.base || row.callback_url !== callbackUrlFor(config.base, channelId)) return null;
    if (row.state !== "pending" && row.state !== "active" && row.state !== "failed") return null;
    const lease = Math.max(60, Number(query.leaseSeconds) || WEBSUB_LEASE_SECONDS);
    await database.prepare("UPDATE websub_subscriptions SET state = 'active', verified_at = ?, lease_expires_at = ?, last_error = NULL, retry_after = NULL WHERE channel_id = ?")
      .run(isoNow(nowMs), isoNow(nowMs + lease * 1000), channelId);
    return query.challenge;
  }
  if (query.mode === "unsubscribe") {
    // Confirm only what nobody here wants pushed any more.
    return !row || row.state === "unsubscribing" ? query.challenge : null;
  }
  if (query.mode === "denied") {
    if (row) await database.prepare("UPDATE websub_subscriptions SET state = 'failed', last_error = 'denied by hub', retry_after = ? WHERE channel_id = ?")
      .run(isoNow(nowMs + 24 * 60 * 60 * 1000), channelId);
    return query.challenge;
  }
  return null;
}

type ChannelRefresher = (channelId: string) => Promise<unknown>;
let refreshChannelNow: ChannelRefresher = (channelId) => syncChannelRecent(channelId);
/** Tests replace the refresh. */
export function setWebSubRefresher(refresher: ChannelRefresher | null): void {
  refreshChannelNow = refresher ?? ((channelId) => syncChannelRecent(channelId));
}

/*
 * The hub often calls before the channel's RSS feed lists the new upload, so
 * the channel is read a little later, and once or twice more if the announced
 * video still has not appeared.
 */
const PUSH_DELAYS_MS = [45_000, 5 * 60_000, 15 * 60_000];
const pendingPushes = new Map<string, { videoIds: Set<string>; timer: ReturnType<typeof setTimeout>; attempt: number }>();

function schedulePushRefresh(channelId: string, videoIds: string[], attempt = 0): void {
  const existing = pendingPushes.get(channelId);
  if (existing) { videoIds.forEach((id) => existing.videoIds.add(id)); return; }
  const entry = { videoIds: new Set(videoIds), attempt, timer: setTimeout(() => void runPushRefresh(channelId), PUSH_DELAYS_MS[attempt]) };
  pendingPushes.set(channelId, entry);
}

async function runPushRefresh(channelId: string): Promise<void> {
  const entry = pendingPushes.get(channelId);
  pendingPushes.delete(channelId);
  if (!entry) return;
  try {
    await refreshChannelNow(channelId);
  } catch (error) {
    log.warn("websub.refresh_failed", { channelId, error: errorText(error) });
  }
  const missing: string[] = [];
  for (const videoId of entry.videoIds) {
    if (!await database.prepare("SELECT 1 FROM videos WHERE video_id = ?").get(videoId)) missing.push(videoId);
  }
  if (missing.length && entry.attempt + 1 < PUSH_DELAYS_MS.length) schedulePushRefresh(channelId, missing, entry.attempt + 1);
  else if (missing.length) log.info("websub.video_not_in_feed", { channelId, videoIds: missing });
}

/** A notification from the hub. Always answered with success; only a correctly signed one is acted on. */
export async function handleNotification(channelId: string, body: string, signature: string | null | undefined): Promise<"accepted" | "ignored"> {
  if (!isChannelId(channelId)) return "ignored";
  const row = await webSubRow(channelId);
  if (!row || row.state === "unsubscribing" || !webSubConfig().base) return "ignored";
  if (!verifyHubSignature(body, signature, row.secret)) {
    log.warn("websub.bad_signature", { channelId });
    return "ignored";
  }
  const notification = parseNotification(body);
  await database.prepare("UPDATE websub_subscriptions SET last_notification_at = ? WHERE channel_id = ?").run(isoNow(), channelId);
  if (!notification || notification.channelId !== channelId || notification.videoIds.length === 0) return "accepted";
  if (!await isFollowed(channelId)) return "ignored";
  log.info("websub.notification", { channelId, videoIds: notification.videoIds });
  schedulePushRefresh(channelId, notification.videoIds);
  return "accepted";
}

/** For tests: run the queued refreshes now instead of waiting for their timers. */
export async function flushWebSubRefreshes(): Promise<void> {
  const channels = [...pendingPushes.keys()];
  for (const channelId of channels) {
    clearTimeout(pendingPushes.get(channelId)!.timer);
    await runPushRefresh(channelId);
  }
}

// ---------- Status ----------

export interface WebSubStatus {
  enabled: boolean;
  callbackBase: string;
  appUrl: string | null;
  effectiveBase: string | null;
  counts: Record<WebSubState, number>;
  followed: number;
  lastNotificationAt: string | null;
  lastError: string | null;
}

export async function webSubStatus(): Promise<WebSubStatus> {
  const config = webSubConfig();
  const rows = await webSubRows();
  const counts: Record<WebSubState, number> = { pending: 0, active: 0, failed: 0, unsubscribing: 0 };
  for (const row of rows) counts[row.state] = (counts[row.state] ?? 0) + 1;
  const latest = rows.map((row) => row.last_notification_at).filter(Boolean).sort().at(-1) ?? null;
  const failed = rows.filter((row) => row.state === "failed" && row.last_error).sort((a, b) => (b.requested_at ?? "").localeCompare(a.requested_at ?? ""))[0];
  return {
    enabled: config.enabled,
    callbackBase: config.configuredBase ?? "",
    appUrl: normaliseCallbackBase(process.env.APP_URL),
    effectiveBase: config.base,
    counts,
    followed: (await followedChannelIds()).length,
    lastNotificationAt: latest,
    lastError: failed?.last_error ?? null,
  };
}
