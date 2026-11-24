const { api } = await import("../src/routes");
const { DEVICE_SESSION_TTL_SECONDS, createSession } = await import("../src/auth");
const { database } = await import("../src/database");
const { setSetting } = await import("../src/db");

await setSetting("auth_method", "shared");
await setSetting("auth_shared_username", "");
await setSetting("auth_shared_password_hash", await Bun.password.hash("device-flow-password"));

const begin = await api.request("http://localhost/auth/device/code", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ device_name: "Living room", device_kind: "phone" }),
});
const authorization = await begin.json() as any;
const pairingUrl = new URL(authorization.verification_uri_complete);
if (pairingUrl.search || pairingUrl.hash !== `#code=${authorization.user_code.replace(/-/g, "")}`
  || `${pairingUrl.origin}${pairingUrl.pathname}` !== authorization.verification_uri) {
  throw new Error("TV pairing link must carry the compact user code in its fragment");
}

const pending = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ device_code: authorization.device_code }),
});
const unauthenticatedVerification = await api.request(
  `http://localhost/auth/device/verification?user_code=${encodeURIComponent(authorization.user_code)}`,
);

const login = await api.request("http://localhost/auth/password/login", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ password: "device-flow-password" }),
});
const cookie = login.headers.get("set-cookie")?.split(";", 1)[0] ?? "";
const verification = await api.request(
  `http://localhost/auth/device/verification?user_code=${encodeURIComponent(authorization.user_code)}`,
  { headers: { Cookie: cookie } },
);
const verificationBody = await verification.clone().json() as any;
const approval = await api.request("http://localhost/auth/device/authorize", {
  method: "POST",
  headers: { Cookie: cookie, "Content-Type": "application/json" },
  // Named as the person approving calls it.
  body: JSON.stringify({ user_code: authorization.user_code, device_name: "Kitchen iPhone" }),
});
const tokenResponse = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ device_code: authorization.device_code }),
});
const tokenBody = await tokenResponse.json() as any;
const token = tokenBody.access_token ?? "";
const bearer = `Bearer ${token}`;
// Kept as named, and for half a year from its last use rather than 30 days.
const named = await database.prepare("SELECT device_name, device_kind, expires_at FROM auth_sessions WHERE token = ?")
  .get<{ device_name: string | null; device_kind: string | null; expires_at: string }>(token);
const longLived = new Date(named?.expires_at ?? 0).getTime() >= Date.now() + (DEVICE_SESSION_TTL_SECONDS - 60) * 1000;
// Settings → Devices: listed, renamed, and another device signed out.
const owner = (await database.prepare("SELECT user_id FROM auth_sessions WHERE token = ?").get<{ user_id: number }>(token))?.user_id ?? 1;
const otherDevice = await createSession(owner, "profile", false, null, { name: "Old tablet", kind: "tablet" });
const listed = await (await api.request("http://localhost/auth/devices", { headers: { Authorization: bearer } })).json() as any;
const self = listed.devices?.find((device: any) => device.current);
const other = listed.devices?.find((device: any) => device.name === "Old tablet");
const renamed = await api.request(`http://localhost/auth/devices/${self?.id}`, {
  method: "PUT",
  headers: { Authorization: bearer, "Content-Type": "application/json" },
  body: JSON.stringify({ name: "Kitchen phone" }),
});
const signedOut = await api.request(`http://localhost/auth/devices/${other?.id}`, { method: "DELETE", headers: { Authorization: bearer } });
const signedOutAgain = await api.request(`http://localhost/auth/devices/${other?.id}`, { method: "DELETE", headers: { Authorization: bearer } });
const afterSignOut = await (await api.request("http://localhost/auth/devices", { headers: { Authorization: bearer } })).json() as any;
const otherGone = await database.prepare("SELECT token FROM auth_sessions WHERE token = ?").get(otherDevice);
const nearlyExpiredAt = new Date(Date.now() + 60_000).toISOString();
await database.prepare("UPDATE auth_sessions SET expires_at = ? WHERE token = ?").run(nearlyExpiredAt, token);
const renewalStartedAt = Date.now();
const feed = await api.request("http://localhost/feed?limit=1", { headers: { Authorization: bearer } });
const renewedSession = await database.prepare("SELECT expires_at FROM auth_sessions WHERE token = ?")
  .get<{ expires_at: string }>(token);
const renewedExpiresAt = new Date(renewedSession?.expires_at ?? 0).getTime();
const renewalObservedAt = Date.now();
const status = await api.request("http://localhost/auth/status", { headers: { Authorization: bearer } });
const statusBody = await status.json() as any;
const createdProfileResponse = await api.request("http://localhost/profiles", {
  method: "POST",
  headers: { Authorization: bearer, "Content-Type": "application/json" },
  body: JSON.stringify({ name: "TV profile", avatar_color: "#336699" }),
});
const createdProfile = await createdProfileResponse.json() as any;
const switched = await api.request("http://localhost/profiles/switch", {
  method: "POST",
  headers: { Authorization: bearer, "Content-Type": "application/json" },
  body: JSON.stringify({ id: createdProfile.profile?.id }),
});
const switchedBody = await switched.json() as any;
const switchedProfiles = await api.request("http://localhost/profiles", { headers: { Authorization: bearer } });
const switchedProfilesBody = await switchedProfiles.json() as any;
const deviceSession = await database.prepare("SELECT user_id, scope FROM auth_sessions WHERE token = ?")
  .get<{ user_id: number | null; scope: string }>(token);
const pinnedToken = await createSession(1, "profile");
await setSetting("auth_method", "per_profile");
const pinnedStatus = await api.request("http://localhost/auth/status", { headers: { Authorization: `Bearer ${pinnedToken}` } });
const pinnedStatusBody = await pinnedStatus.json() as any;
const pinnedSwitch = await api.request("http://localhost/profiles/switch", {
  method: "POST",
  headers: { Authorization: `Bearer ${pinnedToken}`, "Content-Type": "application/json" },
  body: JSON.stringify({ id: createdProfile.profile?.id }),
});
const pinnedSwitchBody = await pinnedSwitch.json() as any;
await setSetting("auth_method", "shared");
const legacyDeviceToken = await createSession(1, "profile");
const legacyStatus = await api.request("http://localhost/auth/status", { headers: { Authorization: `Bearer ${legacyDeviceToken}` } });
const legacyStatusBody = await legacyStatus.json() as any;
const legacySwitch = await api.request("http://localhost/profiles/switch", {
  method: "POST",
  headers: { Authorization: `Bearer ${legacyDeviceToken}`, "Content-Type": "application/json" },
  body: JSON.stringify({ id: createdProfile.profile?.id }),
});
const upgradedLegacySession = await database.prepare("SELECT user_id, scope FROM auth_sessions WHERE token = ?")
  .get<{ user_id: number | null; scope: string }>(legacyDeviceToken);
const browserToken = decodeURIComponent(cookie.slice(cookie.indexOf("=") + 1));
const browserExpiry = new Date(Date.now() + 60_000).toISOString();
await database.prepare("UPDATE auth_sessions SET expires_at = ? WHERE token = ?").run(browserExpiry, browserToken);
const browserFeed = await api.request("http://localhost/feed?limit=1", { headers: { Cookie: cookie } });
const browserSession = await database.prepare("SELECT expires_at FROM auth_sessions WHERE token = ?")
  .get<{ expires_at: string }>(browserToken);
const expiredToken = await createSession(1, "profile");
await database.prepare("UPDATE auth_sessions SET expires_at = ? WHERE token = ?")
  .run(new Date(Date.now() - 60_000).toISOString(), expiredToken);
const expiredBearer = await api.request("http://localhost/feed?limit=1", {
  headers: { Authorization: `Bearer ${expiredToken}` },
});
const expiredSession = await database.prepare("SELECT token FROM auth_sessions WHERE token = ?").get(expiredToken);
const replay = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ device_code: authorization.device_code }),
});
const logout = await api.request("http://localhost/auth/logout", {
  method: "POST",
  headers: { Authorization: bearer },
});
const revoked = await api.request("http://localhost/feed?limit=1", { headers: { Authorization: bearer } });

if (
  begin.status !== 200
  || pending.status !== 428
  || unauthenticatedVerification.status !== 401
  || login.status !== 200
  || verification.status !== 200
  || approval.status !== 200
  || tokenResponse.status !== 200
  || tokenBody.token_type !== "Bearer"
  || tokenBody.expires_in !== DEVICE_SESSION_TTL_SECONDS
  || verificationBody.device_kind !== "phone"
  || named?.device_name !== "Kitchen iPhone"
  || named.device_kind !== "phone"
  || !longLived
  || !self || self.kind !== "phone" || JSON.stringify(self).includes(token)
  || renamed.status !== 200
  || signedOut.status !== 200
  || signedOutAgain.status !== 404
  || otherGone !== null
  || afterSignOut.devices?.length !== 1
  || afterSignOut.devices[0].name !== "Kitchen phone"
  || feed.status !== 200
  // Used, a device's session runs on for its own time from now.
  || renewedExpiresAt < renewalStartedAt + (DEVICE_SESSION_TTL_SECONDS - 5) * 1000
  || renewedExpiresAt > renewalObservedAt + DEVICE_SESSION_TTL_SECONDS * 1000
  || status.status !== 200
  || statusBody.authenticated !== true
  || statusBody.scope !== "account"
  || statusBody.can_switch !== true
  || statusBody.hide_other_profiles !== false
  || createdProfileResponse.status !== 200
  || switched.status !== 200
  || switchedBody.active_id !== createdProfile.profile?.id
  || switchedProfiles.status !== 200
  || switchedProfilesBody.active_id !== createdProfile.profile?.id
  || deviceSession?.scope !== "account"
  || deviceSession.user_id !== createdProfile.profile?.id
  || pinnedStatusBody.can_switch !== false
  || pinnedStatusBody.hide_other_profiles !== true
  || pinnedSwitchBody.requires_relogin !== true
  || legacyStatusBody.can_switch !== true
  || legacySwitch.status !== 200
  || upgradedLegacySession?.scope !== "account"
  || upgradedLegacySession.user_id !== createdProfile.profile?.id
  || browserFeed.status !== 200
  || browserSession?.expires_at !== browserExpiry
  || expiredBearer.status !== 401
  || expiredSession !== null
  || replay.status !== 400
  || logout.status !== 200
  || revoked.status !== 401
) throw new Error("TV device authorization assertion failed");

// Cookie mode: the TV login page on the instance's own origin asks the server to
// set the session as the usual HttpOnly cookie instead of handing out a token.
// A second password login is deliberately slowed down, so approve with a session made directly.
const approverCookie = `ytzero_session=${await createSession(1, "account")}`;
const cookieBegin = await api.request("http://localhost/auth/device/code", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ device_name: "LG TV" }),
});
const cookieAuthorization = await cookieBegin.json() as any;
const cookieApproval = await api.request("http://localhost/auth/device/authorize", {
  method: "POST",
  headers: { Cookie: approverCookie, "Content-Type": "application/json" },
  body: JSON.stringify({ user_code: cookieAuthorization.user_code }),
});
const cookieBody = JSON.stringify({ device_code: cookieAuthorization.device_code, set_cookie: true });
// Refused before the code is used: a cross-site form post, another origin, no Origin at all.
const crossSiteForm = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "text/plain", Origin: "https://attacker.example", "Sec-Fetch-Site": "cross-site" },
  body: cookieBody,
});
const otherOrigin = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "application/json", Origin: "https://attacker.example" },
  body: cookieBody,
});
const noOrigin = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: cookieBody,
});
const cookieToken = await api.request("http://localhost/auth/device/token", {
  method: "POST",
  headers: { "Content-Type": "application/json", Origin: "http://localhost", "Sec-Fetch-Site": "same-origin" },
  body: cookieBody,
});
const cookieTokenBody = await cookieToken.json() as any;
const setCookie = cookieToken.headers.get("set-cookie") ?? "";
const tvCookie = setCookie.split(";", 1)[0];
const tvStatus = await api.request("http://localhost/auth/status", { headers: { Cookie: tvCookie } });
const tvStatusBody = await tvStatus.json() as any;

if (
  cookieApproval.status !== 200
  || crossSiteForm.status !== 403
  || otherOrigin.status !== 403
  || noOrigin.status !== 403
  || crossSiteForm.headers.get("set-cookie")
  || cookieToken.status !== 200
  || "access_token" in cookieTokenBody
  || cookieTokenBody.token_type !== "cookie"
  || !tvCookie.startsWith("ytzero_session=")
  || !/;\s*HttpOnly/i.test(setCookie)
  || tvStatus.status !== 200
  || tvStatusBody.authenticated !== true
) throw new Error("TV device authorization cookie-mode assertion failed");
