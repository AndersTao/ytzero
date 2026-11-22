import { AUTH_SESSION_TTL_SECONDS, validateSession } from "./auth";
import { database } from "./database";

/*
 * A TV signed in under a method that pins each session to one profile
 * (per-profile login, OIDC in mapped mode) cannot switch profile inside its
 * session. It can hold one session per profile instead, each paired with the
 * TV pairing and approved on a phone signed in as that person. The sessions a
 * TV paired share `auth_sessions.device_group`: that, and nothing else, is
 * what lets it move between them. A session without a group is on its own.
 */

export interface DeviceProfile {
  id: number;
  name: string;
  avatar: string;
  avatar_color: string;
  is_child: boolean;
}

interface GroupRow {
  token: string;
  user_id: number;
  expires_at: string;
  name: string;
  avatar: string;
  avatar_color: string;
  is_child: number;
}

const SESSION_TTL_MS = AUTH_SESSION_TTL_SECONDS * 1000;

function avatarUrl(id: number, avatar: string): string {
  return avatar ? `/api/profiles/${id}/avatar?v=${encodeURIComponent(avatar)}` : "";
}

async function groupOf(token: string): Promise<string | null> {
  const row = await database.prepare("SELECT device_group FROM auth_sessions WHERE token = ?")
    .get<{ device_group: string | null }>(token);
  return row?.device_group ?? null;
}

/** Live sessions of the group (or only this one), in the household's profile order. */
async function groupSessions(token: string): Promise<GroupRow[]> {
  const group = await groupOf(token);
  const rows = await database.prepare(`
    SELECT s.token, s.user_id, s.expires_at, u.name, u.avatar, u.avatar_color, u.is_child
    FROM auth_sessions s JOIN users u ON u.id = s.user_id
    WHERE ${group ? "s.device_group = ?" : "s.token = ?"} AND s.scope = 'profile'
    ORDER BY u.sort_order ASC, u.id ASC
  `).all<GroupRow>(group ?? token);
  const now = Date.now();
  const live = rows.filter((row) => new Date(row.expires_at).getTime() > now);
  const expired = rows.filter((row) => !live.includes(row));
  for (const row of expired) await database.prepare("DELETE FROM auth_sessions WHERE token = ?").run(row.token);
  return live;
}

/**
 * The session `newToken` (just issued by the TV pairing) joins the group of
 * the session the TV already had. Only a profile-pinned session is grouped:
 * an account session switches profile on its own. A profile paired again
 * replaces its older session in the group.
 */
export async function linkDeviceSession(currentToken: string | undefined, newToken: string): Promise<boolean> {
  if (!currentToken || currentToken === newToken) return false;
  const current = await validateSession(currentToken);
  if (!current || current.scope !== "profile" || !current.user_id) return false;
  return database.transaction(async () => {
    const fresh = await database.prepare("SELECT user_id, scope FROM auth_sessions WHERE token = ?")
      .get<{ user_id: number | null; scope: string }>(newToken);
    if (!fresh?.user_id || fresh.scope !== "profile") return false;
    let group = await groupOf(currentToken);
    if (!group) {
      group = crypto.randomUUID();
      await database.prepare("UPDATE auth_sessions SET device_group = ? WHERE token = ?").run(group, currentToken);
    }
    await database.prepare("DELETE FROM auth_sessions WHERE device_group = ? AND user_id = ? AND token != ?")
      .run(group, fresh.user_id, newToken);
    await database.prepare("UPDATE auth_sessions SET device_group = ? WHERE token = ?").run(group, newToken);
    return true;
  })();
}

/**
 * The profiles this TV holds a session for. Called whenever the TV starts,
 * so it also keeps the sessions it is not using alive: they were paired on
 * this TV and stay usable as long as it is in use.
 */
export async function listDeviceProfiles(token: string): Promise<DeviceProfile[]> {
  const rows = await groupSessions(token);
  const expires = new Date(Date.now() + SESSION_TTL_MS).toISOString();
  for (const row of rows) {
    if (row.token !== token) await database.prepare("UPDATE auth_sessions SET expires_at = ? WHERE token = ?").run(expires, row.token);
  }
  return rows.map((row) => ({
    id: row.user_id,
    name: row.name,
    avatar: avatarUrl(row.user_id, row.avatar),
    avatar_color: row.avatar_color,
    is_child: row.is_child === 1,
  }));
}

/** The session this TV holds for `profileId`, or null when it was never paired here. */
export async function deviceSessionFor(token: string, profileId: number): Promise<string | null> {
  const rows = await groupSessions(token);
  return rows.find((row) => row.user_id === profileId)?.token ?? null;
}

/** Signs the TV out of one of its other profiles. The one in use is signed out with logout. */
export async function removeDeviceProfile(token: string, profileId: number): Promise<"removed" | "active" | "not_found"> {
  const rows = await groupSessions(token);
  const target = rows.find((row) => row.user_id === profileId);
  if (!target) return "not_found";
  if (target.token === token) return "active";
  await database.prepare("DELETE FROM auth_sessions WHERE token = ?").run(target.token);
  return "removed";
}
