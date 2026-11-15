import type { Context, Hono } from "hono";
import { AUTH_SESSION_TTL_SECONDS, authSessionCookie, createSession, requestOrigin } from "../auth";
import { database } from "../database";
import {
  approveDeviceAuthorization,
  beginDeviceAuthorization,
  exchangeDeviceAuthorization,
  inspectDeviceAuthorization,
  normalizeDeviceUserCode,
} from "../deviceAuth";
import { log } from "../logger";

type ApiEnvironment = { Variables: { userId: number; sessionAdmin?: boolean; profileAdmin?: boolean } };
type Api = Hono<ApiEnvironment>;
type ApiContext = Context<ApiEnvironment>;

interface DeviceAuthRouteAccess {
  canSwitchProfiles: () => boolean;
  currentUserId: (context: ApiContext) => number;
}

/** A JSON fetch from this instance's own origin: forms cannot send JSON, and other origins differ. */
function isSameOriginJsonRequest(c: ApiContext): boolean {
  if (!(c.req.header("content-type") ?? "").toLowerCase().startsWith("application/json")) return false;
  const fetchSite = c.req.header("sec-fetch-site");
  if (fetchSite && fetchSite !== "same-origin") return false;
  const origin = c.req.header("origin");
  return Boolean(origin) && origin === requestOrigin(c);
}

export function registerDeviceAuthRoutes(api: Api, access: DeviceAuthRouteAccess): void {
  api.post("/auth/device/code", async (c) => {
    c.header("Cache-Control", "no-store");
    const { device_name } = await c.req.json().catch(() => ({}));
    const authorization = await beginDeviceAuthorization(device_name);
    const verificationUri = `${requestOrigin(c)}/tv/pair`;
    return c.json({
      device_code: authorization.deviceCode,
      user_code: authorization.userCode,
      verification_uri: verificationUri,
      verification_uri_complete: `${verificationUri}#code=${encodeURIComponent(authorization.userCode.replace(/-/g, ""))}`,
      expires_in: authorization.expiresIn,
      interval: authorization.interval,
    });
  });

  api.get("/auth/device/verification", async (c) => {
    c.header("Cache-Control", "no-store");
    const uid = access.currentUserId(c);
    if (!uid) return c.json({ error: "unauthenticated" }, 401);
    const userCode = normalizeDeviceUserCode(c.req.query("user_code"));
    const authorization = await inspectDeviceAuthorization(userCode);
    if (!authorization) return c.json({ error: "invalid or expired device code" }, 404);
    const profile = await database.prepare("SELECT name FROM users WHERE id = ?").get<{ name: string }>(uid);
    return c.json({
      user_code: userCode,
      device_name: authorization.deviceName,
      approved: authorization.approved,
      profile_name: profile?.name ?? "",
    });
  });

  api.post("/auth/device/authorize", async (c) => {
    c.header("Cache-Control", "no-store");
    const uid = access.currentUserId(c);
    if (!uid) return c.json({ error: "unauthenticated" }, 401);
    const { user_code } = await c.req.json().catch(() => ({}));
    const normalized = normalizeDeviceUserCode(user_code);
    if (!normalized) return c.json({ error: "invalid or expired device code" }, 404);
    const approved = await approveDeviceAuthorization(normalized, uid);
    if (!approved) return c.json({ error: "invalid, expired, or already approved device code" }, 404);
    log.info("auth.device_approved", { profileId: uid });
    return c.json({ ok: true });
  });

  api.post("/auth/device/token", async (c) => {
    c.header("Cache-Control", "no-store");
    const { device_code, set_cookie } = await c.req.json().catch(() => ({}));
    // Cookie mode is only for the instance's own TV login page. Without this a
    // cross-site form (enctype=text/plain) could plant a session the attacker
    // approved in someone else's browser (login CSRF). Checked before the code
    // is exchanged, so a refused request does not use it up.
    if (set_cookie === true && !isSameOriginJsonRequest(c)) return c.json({ error: "forbidden_origin" }, 403);
    const authorization = await exchangeDeviceAuthorization(device_code);
    if (authorization.kind === "pending") return c.json({ error: "authorization_pending" }, 428);
    if (authorization.kind === "expired") return c.json({ error: "expired_token" }, 400);
    const scope = access.canSwitchProfiles() ? "account" : "profile";
    const accessToken = await createSession(authorization.userId, scope);
    log.info("auth.device_login", { scope, id: authorization.userId, cookie: set_cookie === true });
    // A browser on the instance's own origin (the TV login page) asks for the
    // session as the same HttpOnly cookie a normal sign-in sets, so the token
    // never passes through page JavaScript.
    if (set_cookie === true) {
      c.header("Set-Cookie", authSessionCookie(accessToken));
      return c.json({ token_type: "cookie", expires_in: AUTH_SESSION_TTL_SECONDS });
    }
    return c.json({ access_token: accessToken, token_type: "Bearer", expires_in: AUTH_SESSION_TTL_SECONDS });
  });
}
