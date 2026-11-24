import { createHash } from "node:crypto";
import { database } from "./database";
import { sanitizeDeviceName } from "./deviceAuthInput";

/*
 * The phones, tablets and TVs signed in to a profile with a code, as
 * Settings → Devices lists them: the name given when it was approved, what it
 * is, and when it was last used. Signing one out ends its session at once.
 *
 * A session's token is what lets a device in, so it never leaves the server:
 * a device is named on the page by a hash of it.
 */

export interface DeviceSession {
  id: string;
  name: string;
  kind: string;
  created_at: string;
  last_seen: string | null;
  /** The device asking is this one. */
  current: boolean;
}

function idOf(token: string): string {
  return createHash("sha256").update(`device-session:${token}`).digest("hex").slice(0, 24);
}

interface Row {
  token: string;
  device_name: string;
  device_kind: string | null;
  created_at: string;
  last_seen: string | null;
}

async function rows(userId: number): Promise<Row[]> {
  return await database.prepare(
    "SELECT token, device_name, device_kind, created_at, last_seen FROM auth_sessions WHERE user_id = ? AND device_name IS NOT NULL AND expires_at > ? ORDER BY COALESCE(last_seen, created_at) DESC",
  ).all(userId, new Date().toISOString()) as Row[];
}

export async function listDeviceSessions(userId: number, currentToken?: string): Promise<DeviceSession[]> {
  return (await rows(userId)).map((row) => ({
    id: idOf(row.token),
    name: row.device_name,
    kind: row.device_kind ?? "tv",
    created_at: row.created_at,
    last_seen: row.last_seen,
    current: row.token === currentToken,
  }));
}

async function tokenFor(userId: number, id: string): Promise<string | null> {
  return (await rows(userId)).find((row) => idOf(row.token) === id)?.token ?? null;
}

/** Signs one of the profile's devices out. False when it has no such device. */
export async function revokeDeviceSession(userId: number, id: string): Promise<boolean> {
  const token = await tokenFor(userId, id);
  if (!token) return false;
  await database.prepare("DELETE FROM auth_sessions WHERE token = ? AND user_id = ?").run(token, userId);
  return true;
}

export async function renameDeviceSession(userId: number, id: string, name: unknown): Promise<boolean> {
  const token = await tokenFor(userId, id);
  if (!token || typeof name !== "string" || !name.trim()) return false;
  await database.prepare("UPDATE auth_sessions SET device_name = ? WHERE token = ? AND user_id = ?").run(sanitizeDeviceName(name), token, userId);
  return true;
}
