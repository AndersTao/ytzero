import type { Context, Hono } from "hono";
import { publishAppEvent } from "../appEvents";
import { authSessionCookie, validateSession } from "../auth";
import { checkLeavingChildProfile } from "../childLockPin";
import { database } from "../database";
import { bearerSessionToken, isSameOriginJsonRequest } from "../deviceSessionAuth";
import { deviceSessionFor, listDeviceProfiles, removeDeviceProfile } from "../deviceProfiles";
import { log } from "../logger";

type ApiEnvironment = { Variables: { userId: number; sessionAdmin?: boolean; profileAdmin?: boolean } };
type Api = Hono<ApiEnvironment>;
type ApiContext = Context<ApiEnvironment>;

interface DeviceProfileRouteAccess {
  canSwitchProfiles: () => boolean;
  sessionToken: (context: ApiContext) => string | undefined;
}

/*
 * The profiles a TV paired, one session each (see deviceProfiles.ts). The LG
 * page has its session as an HttpOnly cookie, so the server swaps the cookie
 * for it; the Apple TV app keeps its sessions itself and asks here only so the
 * child lock is checked by the server. Both may enter only a profile paired on
 * this device, and leaving a child profile needs the child lock PIN.
 */
export function registerDeviceProfileRoutes(api: Api, access: DeviceProfileRouteAccess): void {
  /** The caller's session. A cookie only counts on a change asked by the instance's own page. */
  async function pinnedSession(c: ApiContext, change = false) {
    if (change && !bearerSessionToken(c.req.header("authorization")) && !isSameOriginJsonRequest(c)) return null;
    const token = access.sessionToken(c);
    const session = token ? await validateSession(token) : null;
    return token && session?.user_id ? { token, session } : null;
  }

  api.get("/auth/device/profiles", async (c) => {
    c.header("Cache-Control", "no-store");
    const current = await pinnedSession(c);
    if (!current) return c.json({ error: "unauthenticated" }, 401);
    const canSwitch = access.canSwitchProfiles();
    const profiles = current.session.scope === "profile" ? await listDeviceProfiles(current.token) : [];
    return c.json({ can_switch: canSwitch, active_id: current.session.user_id, profiles });
  });

  api.post("/auth/device/profiles/switch", async (c) => {
    c.header("Cache-Control", "no-store");
    const current = await pinnedSession(c, true);
    if (!current) return c.json({ error: "unauthenticated" }, 401);
    const { id, child_lock_pin } = await c.req.json().catch(() => ({}));
    const targetId = Number(id);
    if (!Number.isSafeInteger(targetId) || targetId < 1) return c.json({ error: "invalid profile id" }, 400);
    const target = current.session.scope === "profile" ? await deviceSessionFor(current.token, targetId) : null;
    if (!target) return c.json({ error: "not paired on this device" }, 404);
    const activeId = current.session.user_id ?? 0;
    const leaving = await database.prepare("SELECT id, is_child FROM users WHERE id = ?")
      .get<{ id: number; is_child: number }>(activeId);
    const check = await checkLeavingChildProfile(leaving ?? null, targetId, child_lock_pin);
    if (!check.ok) {
      if (check.pinRequired) return c.json({ error: "child lock PIN required", pin_required: true }, 401);
      publishAppEvent("child-status");
      publishAppEvent("child-watching");
      return c.json({ error: "invalid PIN", pin_locked: check.pinLocked }, 401);
    }
    log.info("auth.device_profile_switched", { from: activeId, to: targetId });
    // A bearer client holds its own session for the profile; a browser gets it as its cookie.
    if (!bearerSessionToken(c.req.header("authorization"))) c.header("Set-Cookie", authSessionCookie(target));
    return c.json({ ok: true, active_id: targetId });
  });

  api.delete("/auth/device/profiles/:id", async (c) => {
    c.header("Cache-Control", "no-store");
    const current = await pinnedSession(c, true);
    if (!current) return c.json({ error: "unauthenticated" }, 401);
    const targetId = Number(c.req.param("id"));
    if (!Number.isSafeInteger(targetId) || targetId < 1) return c.json({ error: "invalid profile id" }, 400);
    const result = current.session.scope === "profile" ? await removeDeviceProfile(current.token, targetId) : "not_found";
    if (result === "not_found") return c.json({ error: "not paired on this device" }, 404);
    if (result === "active") return c.json({ error: "the profile in use is removed by signing out" }, 409);
    log.info("auth.device_profile_removed", { id: targetId });
    return c.json({ ok: true });
  });
}
