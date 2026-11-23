import { createSession, destroySession, validateSession } from "../../auth";
import { database } from "../../database";
import { profileForNameAndToken } from "../invidious/tokens";
export { clientFields, presentedToken } from "./headers";

/**
 * Who a Jellyfin client is.
 *
 * Signing in takes the same pair Yattee does: the profile's name as the user
 * name and the token from Settings → Clients as the password. Nobody's real
 * password crosses the wire, and regenerating the token stops new sign-ins.
 *
 * What the client gets back as its access token is an ordinary profile session
 * of this server, the kind the Apple TV app holds. That is what lets these
 * routes answer by asking the server's own API, as that profile, rather than
 * repeating its rules for the feed, progress and playback here.
 */

export interface JellyfinUser {
  userId: number;
  name: string;
  /** The server session standing for this sign-in. */
  session: string;
}

/** Signs a profile in: its name and its client token, answered with a new session. */
export async function signIn(name: string, password: string): Promise<JellyfinUser | null> {
  const userId = await profileForNameAndToken(name, password);
  if (userId === null) return null;
  const session = await createSession(userId, "profile");
  return { userId, name: await profileName(userId), session };
}

/** The profile behind a presented session, or nothing. */
export async function userForSession(session: string | null): Promise<JellyfinUser | null> {
  if (!session) return null;
  const found = await validateSession(session, { renew: true });
  if (!found || found.scope !== "profile" || !found.user_id) return null;
  return { userId: found.user_id, name: await profileName(found.user_id), session };
}

export async function signOut(session: string | null): Promise<void> {
  if (session) await destroySession(session);
}

async function profileName(userId: number): Promise<string> {
  const row = await database.prepare("SELECT name FROM users WHERE id = ?").get(userId) as { name: string } | null;
  return row?.name ?? "";
}
