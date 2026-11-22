const { api } = await import("../src/routes");
const { createSession } = await import("../src/auth");
const { database } = await import("../src/database");
const { setSetting } = await import("../src/db");
const { unlockChildProfile } = await import("../src/childTime");

/*
 * A TV under OIDC in mapped mode (each session pinned to one profile, other
 * profiles hidden) holds one session per profile, each paired on its own and
 * approved by that person, and moves between them.
 */
await setSetting("auth_method", "oidc");
await setSetting("auth_oidc_mode", "mapped");
await setSetting("auth_hide_other_profiles", "1");
await setSetting("child_lock_enabled", "1");
await setSetting("child_lock_pin_hash", await Bun.password.hash("135790"));

const insertUser = database.prepare("INSERT INTO users(name, avatar_color, sort_order, portable_uuid, is_child) VALUES(?, ?, ?, ?, ?) RETURNING id");
const primary = (await database.prepare("SELECT id FROM users ORDER BY id LIMIT 1").get<{ id: number }>())!.id;
const parent = (await insertUser.get<{ id: number }>("Parent", "#335577", 1, crypto.randomUUID(), 0))!.id;
const child = (await insertUser.get<{ id: number }>("Child", "#aa3355", 2, crypto.randomUUID(), 1))!.id;

function check(condition: unknown, message: string): void {
  if (!condition) throw new Error(`device profiles: ${message}`);
}

const sameOrigin = { "Content-Type": "application/json", Origin: "http://localhost", "Sec-Fetch-Site": "same-origin" };
const cookieOf = (response: Response) => (response.headers.get("set-cookie") ?? "").split(";", 1)[0];
const tokenOf = (cookie: string) => decodeURIComponent(cookie.slice(cookie.indexOf("=") + 1));

/** One TV pairing approved by `approver`, exchanged with the given headers and body. */
async function pair(approver: number, headers: Record<string, string>, body: Record<string, unknown>) {
  const begin = await api.request("http://localhost/auth/device/code", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_name: "LG TV" }),
  });
  const code = await begin.json() as { device_code: string; user_code: string };
  const approval = await api.request("http://localhost/auth/device/authorize", {
    method: "POST",
    headers: { Cookie: `ytzero_session=${await createSession(approver, "profile")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ user_code: code.user_code }),
  });
  check(approval.status === 200, "approval");
  return api.request("http://localhost/auth/device/token", {
    method: "POST",
    headers,
    body: JSON.stringify({ device_code: code.device_code, ...body }),
  });
}

const list = async (headers: Record<string, string>) => {
  const response = await api.request("http://localhost/auth/device/profiles", { headers });
  return { status: response.status, body: await response.json() as any };
};
const switchTo = (headers: Record<string, string>, body: Record<string, unknown>) =>
  api.request("http://localhost/auth/device/profiles/switch", { method: "POST", headers, body: JSON.stringify(body) });

// ---------- LG page: one HttpOnly cookie, swapped by the server ----------

const childLogin = await pair(child, sameOrigin, { set_cookie: true });
const childCookie = cookieOf(childLogin);
check(childLogin.status === 200 && childCookie.startsWith("ytzero_session="), "first pairing sets the cookie");
const alone = await list({ Cookie: childCookie });
check(alone.status === 200 && alone.body.can_switch === false && alone.body.active_id === child, "a pinned session lists itself");
check(alone.body.profiles.length === 1 && alone.body.profiles[0].id === child && alone.body.profiles[0].is_child === true, "only the child is paired");

// "Add profile": the TV pairs again with its cookie and asks to be linked.
const parentLogin = await pair(parent, { ...sameOrigin, Cookie: childCookie }, { set_cookie: true, link_session: true });
const parentCookie = cookieOf(parentLogin);
const parentLoginBody = await parentLogin.json() as any;
check(parentLogin.status === 200 && parentLoginBody.linked === true && !("access_token" in parentLoginBody), "the new profile is linked");
const both = await list({ Cookie: parentCookie });
check(both.body.active_id === parent && both.body.profiles.map((p: any) => p.id).join() === `${parent},${child}`, "both profiles are listed in profile order");
check(both.body.profiles.every((p: any) => typeof p.name === "string" && typeof p.avatar_color === "string" && "avatar" in p), "profiles carry name and avatar");

// Leaving a grown-up profile needs nothing; the server swaps the cookie.
const toChild = await switchTo({ ...sameOrigin, Cookie: parentCookie }, { id: child });
check(toChild.status === 200 && tokenOf(cookieOf(toChild)) === tokenOf(childCookie), "parent → child swaps the cookie");
check(/;\s*HttpOnly/i.test(toChild.headers.get("set-cookie") ?? ""), "the swapped cookie stays HttpOnly");

// Leaving the child profile needs the child lock PIN.
const noPin = await switchTo({ ...sameOrigin, Cookie: childCookie }, { id: parent });
const noPinBody = await noPin.json() as any;
check(noPin.status === 401 && noPinBody.pin_required === true && !noPin.headers.get("set-cookie"), "child → parent asks for the PIN");
const failuresAfterQuestion = await database.prepare("SELECT COUNT(*) AS n FROM child_pin_failures WHERE user_id = ?").get<{ n: number }>(child);
const wrongPin = await switchTo({ ...sameOrigin, Cookie: childCookie }, { id: parent, child_lock_pin: "000000" });
const wrongPinBody = await wrongPin.json() as any;
check(wrongPin.status === 401 && wrongPinBody.error === "invalid PIN" && !wrongPin.headers.get("set-cookie"), "a wrong PIN is refused");
const failuresAfterWrong = await database.prepare("SELECT COUNT(*) AS n FROM child_pin_failures WHERE user_id = ?").get<{ n: number }>(child);
check((failuresAfterQuestion?.n ?? 0) === 0 && (failuresAfterWrong?.n ?? 0) >= 1, "only a wrong PIN counts as a failure");
const rightPin = await switchTo({ ...sameOrigin, Cookie: childCookie }, { id: parent, child_lock_pin: "135790" });
check(rightPin.status === 200 && tokenOf(cookieOf(rightPin)) === tokenOf(parentCookie), "the right PIN swaps back");

// Three wrong PINs lock the child profile; then even the right one is refused.
for (let attempt = 0; attempt < 3; attempt++) {
  await switchTo({ ...sameOrigin, Cookie: childCookie }, { id: parent, child_lock_pin: "000000" });
}
const whileLocked = await switchTo({ ...sameOrigin, Cookie: childCookie }, { id: parent, child_lock_pin: "135790" });
const whileLockedBody = await whileLocked.json() as any;
check(whileLocked.status === 401 && whileLockedBody.pin_locked === true && !whileLocked.headers.get("set-cookie"), "a locked child profile takes no PIN");
await unlockChildProfile(child);

// No entering a profile this TV never paired, and no swap from another site.
const unpaired = await switchTo({ ...sameOrigin, Cookie: parentCookie }, { id: primary });
check(unpaired.status === 404 && !unpaired.headers.get("set-cookie"), "an unpaired profile is refused");
const crossSite = await switchTo({ "Content-Type": "application/json", Cookie: parentCookie, Origin: "https://attacker.example" }, { id: child });
check(crossSite.status === 401 && !crossSite.headers.get("set-cookie"), "a cross-site swap is refused");
const plainForm = await switchTo({ "Content-Type": "text/plain", Cookie: parentCookie }, { id: child });
check(plainForm.status === 401, "a form post cannot swap");

// Another TV, paired on its own, cannot reach this one's profiles.
const otherTv = cookieOf(await pair(primary, sameOrigin, { set_cookie: true }));
const otherList = await list({ Cookie: otherTv });
check(otherList.body.profiles.length === 1 && otherList.body.profiles[0].id === primary, "another TV lists only its own profile");
const otherSwitch = await switchTo({ ...sameOrigin, Cookie: otherTv }, { id: child });
check(otherSwitch.status === 404, "another TV cannot enter this TV's child profile");

// A link asked for from another origin is not made.
const foreignLink = await pair(primary, { "Content-Type": "application/json", Cookie: parentCookie }, { link_session: true });
const foreignLinkBody = await foreignLink.json() as any;
check(foreignLink.status === 200 && foreignLinkBody.linked === false, "a cookie is linked only from the instance's own page");
check((await list({ Cookie: parentCookie })).body.profiles.length === 2, "the group is unchanged");

// The profiles not in use stay alive while the TV is used.
await database.prepare("UPDATE auth_sessions SET expires_at = ? WHERE token = ?")
  .run(new Date(Date.now() + 60_000).toISOString(), tokenOf(childCookie));
await list({ Cookie: parentCookie });
const renewed = await database.prepare("SELECT expires_at FROM auth_sessions WHERE token = ?").get<{ expires_at: string }>(tokenOf(childCookie));
check(new Date(renewed?.expires_at ?? 0).getTime() > Date.now() + 29 * 24 * 60 * 60 * 1000, "listing renews the other profiles");

// Pairing a profile again replaces its older session in the group.
const parentAgain = cookieOf(await pair(parent, { ...sameOrigin, Cookie: childCookie }, { set_cookie: true, link_session: true }));
const afterRepair = await list({ Cookie: parentAgain });
check(afterRepair.body.profiles.length === 2, "a profile is in the group once");
check((await list({ Cookie: parentCookie })).status === 401, "the replaced session is gone");

// Remove: another profile goes, the one in use is signed out with logout.
const removeSelf = await api.request(`http://localhost/auth/device/profiles/${parent}`, { method: "DELETE", headers: { ...sameOrigin, Cookie: parentAgain } });
check(removeSelf.status === 409, "the profile in use is not removed here");
const removeChild = await api.request(`http://localhost/auth/device/profiles/${child}`, { method: "DELETE", headers: { ...sameOrigin, Cookie: parentAgain } });
check(removeChild.status === 200, "another profile is removed");
check((await list({ Cookie: parentAgain })).body.profiles.length === 1, "the removed profile is gone from the list");
check((await list({ Cookie: childCookie })).status === 401, "the removed profile's session no longer works");

// ---------- Apple TV app: bearer sessions it keeps itself ----------

const firstBearer = (await (await pair(child, { "Content-Type": "application/json" }, {})).json() as any).access_token as string;
const secondResponse = await pair(parent, { "Content-Type": "application/json", Authorization: `Bearer ${firstBearer}` }, { link_session: true });
const secondBody = await secondResponse.json() as any;
check(secondBody.linked === true && typeof secondBody.access_token === "string", "a bearer pairing links with the token it holds");
const bearerList = await list({ Authorization: `Bearer ${secondBody.access_token}` });
check(bearerList.body.profiles.length === 2, "the bearer group lists both");
const bearerNoPin = await switchTo({ "Content-Type": "application/json", Authorization: `Bearer ${firstBearer}` }, { id: parent });
check(bearerNoPin.status === 401, "a bearer client leaving the child profile needs the PIN");
const bearerSwitch = await switchTo({ "Content-Type": "application/json", Authorization: `Bearer ${firstBearer}` }, { id: parent, child_lock_pin: "135790" });
check(bearerSwitch.status === 200 && !bearerSwitch.headers.get("set-cookie"), "a bearer client is answered without a cookie");
const unlinkedBearer = (await (await pair(primary, { "Content-Type": "application/json" }, {})).json() as any).access_token as string;
const bearerUnpaired = await switchTo({ "Content-Type": "application/json", Authorization: `Bearer ${unlinkedBearer}` }, { id: child });
check(bearerUnpaired.status === 404, "a bearer client cannot enter a profile it did not pair");

// ---------- Methods that switch inside the session ----------

await setSetting("auth_method", "shared");
const accountToken = await createSession(primary, "account");
const accountList = await list({ Authorization: `Bearer ${accountToken}` });
check(accountList.status === 200 && accountList.body.can_switch === true && accountList.body.profiles.length === 0, "an account session uses the profile switch instead");
check((await list({})).status === 401, "the list needs a session");
