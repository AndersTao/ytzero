import { createHmac, timingSafeEqual } from "node:crypto";
import { createSession, validateSession } from "../../auth";
import { database } from "../../database";
import { mediaSecret } from "../invidious/media";
import { profileForNameAndToken, stampStands, tokenStamp } from "../invidious/tokens";
export { clientFields, presentedToken } from "./headers";

/**
 * Who a Jellyfin client is.
 *
 * Signing in takes the same pair Yattee does: the profile's name as the user
 * name and the token from Settings → Clients as the password. Nobody's real
 * password crosses the wire.
 *
 * The client gets back an access token of this dialect's own, good for the
 * `/jellyfin` routes and nothing else: signed with the server's media key and
 * naming the profile and which client token it was given for. Revoking that
 * client token ends it, as it ends Yattee's sign-in.
 *
 * Behind it the routes ask the server's own API as the profile, with a
 * profile session that is this process's and never leaves it. A client that
 * signed in here therefore reaches only what these routes translate, not the
 * whole API a session would open.
 */

export interface JellyfinUser {
  userId: number;
  name: string;
  /** The server session the routes ask the API with. Never sent to a client. */
  session: string;
}

const PREFIX = "jf1";

/** Signs a profile in with its name and client token: the access token for this dialect, or nothing. */
export async function signIn(name: string, password: string): Promise<{ accessToken: string; user: JellyfinUser } | null> {
  const userId = await profileForNameAndToken(name, password);
  if (userId === null) return null;
  const stamp = await tokenStamp(password);
  const payload = `${userId}.${stamp}`;
  return { accessToken: `${PREFIX}.${payload}.${await signature(payload)}`, user: await userFor(userId) };
}

/** The profile behind a presented access token, while its client token stands. */
export async function userForAccessToken(token: string | null): Promise<JellyfinUser | null> {
  const parts = (token ?? "").split(".");
  if (parts.length !== 4 || parts[0] !== PREFIX) return null;
  const [, id, stamp, presented] = parts;
  const expected = await signature(`${id}.${stamp}`);
  if (presented.length !== expected.length || !timingSafeEqual(Buffer.from(presented), Buffer.from(expected))) return null;
  const userId = Number(id);
  if (!Number.isInteger(userId) || userId <= 0 || !await stampStands(userId, stamp)) return null;
  return userFor(userId);
}

async function signature(payload: string): Promise<string> {
  return createHmac("sha256", await mediaSecret()).update(`jellyfin:${payload}`).digest("hex").slice(0, 43);
}

const sessions = new Map<number, string>();

/** The profile, with this process's own session for it, made when first needed. */
async function userFor(userId: number): Promise<JellyfinUser> {
  let session = sessions.get(userId);
  if (!session || !await validateSession(session, { renew: true })) {
    session = await createSession(userId, "profile");
    sessions.set(userId, session);
  }
  return { userId, name: await profileName(userId), session };
}

async function profileName(userId: number): Promise<string> {
  const row = await database.prepare("SELECT name FROM users WHERE id = ?").get(userId) as { name: string } | null;
  return row?.name ?? "";
}
