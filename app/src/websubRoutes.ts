import type { Context, Hono } from "hono";
import { log } from "./logger";
import {
  handleNotification,
  handleVerification,
  maintainWebSub,
  saveWebSubConfig,
  WEBSUB_CALLBACK_PREFIX,
  webSubStatus,
} from "./websub";

const MAX_NOTIFICATION_BYTES = 1_000_000;

/**
 * The address Google's hub calls. It sits outside the authenticated API (the
 * hub has no session) and proves itself instead: verification requests must
 * match a subscription this instance asked for, and notifications must carry
 * the HMAC signature made with that subscription's secret.
 */
export function registerWebSubCallback(app: Hono<any>): void {
  app.get(`${WEBSUB_CALLBACK_PREFIX}:channelId`, async (c) => {
    const challenge = await handleVerification(c.req.param("channelId"), {
      mode: c.req.query("hub.mode"),
      topic: c.req.query("hub.topic"),
      challenge: c.req.query("hub.challenge"),
      leaseSeconds: c.req.query("hub.lease_seconds"),
    });
    return challenge === null ? c.text("not found", 404) : c.text(challenge, 200);
  });

  app.post(`${WEBSUB_CALLBACK_PREFIX}:channelId`, async (c) => {
    if (Number(c.req.header("content-length") ?? 0) > MAX_NOTIFICATION_BYTES) return c.body(null, 413);
    const body = await c.req.text();
    if (body.length > MAX_NOTIFICATION_BYTES) return c.body(null, 413);
    // Answer 2xx either way: the hub retries anything else, and an unsigned
    // or unknown notification is simply not acted on.
    await handleNotification(c.req.param("channelId"), body, c.req.header("x-hub-signature"))
      .catch((error) => log.warn("websub.notification_failed", { error: error instanceof Error ? error.message : String(error) }));
    return c.body(null, 204);
  });
}

/** Settings for administrators, inside the authenticated API. */
export function registerWebSubAdminRoutes(api: Hono<any>, access: { isAdmin: (c: Context<any>) => boolean }): void {
  api.get("/websub", async (c) => {
    if (!access.isAdmin(c)) return c.json({ error: "admin only" }, 403);
    return c.json(await webSubStatus());
  });

  api.put("/websub", async (c) => {
    if (!access.isAdmin(c)) return c.json({ error: "admin only" }, 403);
    const body = await c.req.json().catch(() => null) as { enabled?: unknown; callbackBase?: unknown } | null;
    if (!body || typeof body.enabled !== "boolean" || typeof body.callbackBase !== "string") {
      return c.json({ error: "expected { enabled: boolean, callbackBase: string }" }, 400);
    }
    try {
      await saveWebSubConfig({ enabled: body.enabled, callbackBase: body.callbackBase });
    } catch (error) {
      return c.json({ error: error instanceof Error ? error.message : String(error) }, 400);
    }
    return c.json(await webSubStatus());
  });
}

/** Keep subscriptions in step with the followed channels; renew leases before they lapse. */
export function startWebSubMaintenance(): void {
  const run = () => maintainWebSub().catch((error) => log.warn("websub.maintenance_failed", { error: error instanceof Error ? error.message : String(error) }));
  setTimeout(run, 30_000);
  setInterval(run, 15 * 60_000);
}
