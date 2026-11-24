import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { database } from "../../database";
import { log } from "../../logger";
import { mediaSecret } from "./media";

/**
 * How a client proves whose library it is asking about.
 *
 * The dialect authenticates the way Invidious does: a form post of an email
 * and a password, answered with a session cookie the client sends back. Here
 * the email is the profile's name and the password is a token generated for
 * it — nobody's real password crosses the wire, and a token can be revoked
 * without touching the account it belongs to.
 *
 * The token is also the cookie. Invidious's `SID` is a bearer credential
 * already, so minting a second one to stand for the first would be a second
 * thing to expire, revoke and store for no gain: revoking a token turns away
 * every device holding it, at once. A profile holds one per app or device,
 * each under its own name, so revoking one leaves the others signed in.
 *
 * What is stored is a keyed hash. The key is the one that signs media links,
 * so a stolen database yields neither playable links nor usable tokens, and
 * the hash is deterministic — which is what lets a presented token find its
 * profile without trying every profile in turn.
 */
const PREFIX = "ytz_";

export function looksLikeToken(value: string | undefined | null): boolean {
  return typeof value === "string" && /^ytz_[0-9a-f]{64}$/.test(value);
}

async function hashOf(token: string): Promise<string> {
  return createHmac("sha256", await mediaSecret()).update(token).digest("hex");
}

/** How many a profile may hold at once: one per app or device is a handful. */
export const MAX_TOKENS_PER_PROFILE = 20;
const NAME_LIMIT = 80;

function cleanName(name: unknown): string {
  return typeof name === "string" ? name.trim().replace(/\s+/g, " ").slice(0, NAME_LIMIT) : "";
}

/** A new token for this profile, beside the ones it has. Shown once, never again. */
export async function mintToken(userId: number, name: unknown = ""): Promise<{ id: number; token: string }> {
  const token = PREFIX + randomBytes(32).toString("hex");
  const row = await database
    .prepare("INSERT INTO client_tokens (user_id, name, token_hash) VALUES (?, ?, ?) RETURNING id")
    .get(userId, cleanName(name), await hashOf(token)) as { id: number };
  log.info("invidious.token_minted", { userId, tokenId: row.id });
  return { id: Number(row.id), token };
}

/** How many tokens the profile holds now. */
export async function tokenCount(userId: number): Promise<number> {
  const row = await database.prepare("SELECT COUNT(*) AS n FROM client_tokens WHERE user_id = ?").get(userId) as { n: number };
  return Number(row.n);
}

/** Signs out every app holding this one token; the profile's others go on working. */
export async function revokeToken(userId: number, tokenId: number): Promise<boolean> {
  const result = await database.prepare("DELETE FROM client_tokens WHERE id = ? AND user_id = ?").run(tokenId, userId);
  log.info("invidious.token_revoked", { userId, tokenId });
  return result.changes > 0;
}

export async function renameToken(userId: number, tokenId: number, name: unknown): Promise<boolean> {
  const result = await database.prepare("UPDATE client_tokens SET name = ? WHERE id = ? AND user_id = ?").run(cleanName(name), tokenId, userId);
  return result.changes > 0;
}

export interface TokenState {
  id: number;
  name: string;
  createdAt: string;
  lastUsedAt: string | null;
}

/** What the settings screen can say about a profile's tokens, never the tokens. Newest first. */
export async function tokenStates(userId: number): Promise<TokenState[]> {
  const rows = await database
    .prepare("SELECT id, name, created_at, last_used_at FROM client_tokens WHERE user_id = ? ORDER BY created_at DESC, id DESC")
    .all(userId) as { id: number; name: string; created_at: string; last_used_at: string | null }[];
  return rows.map((row) => ({ id: Number(row.id), name: row.name, createdAt: row.created_at, lastUsedAt: row.last_used_at }));
}

/** A short, stable mark of which token this is, for the sign-ins made with it. */
export async function tokenStamp(token: string): Promise<string> {
  return (await hashOf(token)).slice(0, 16);
}

/** Whether the profile still holds the token a stamp was taken from. */
export async function stampStands(userId: number, stamp: string): Promise<boolean> {
  if (!/^[0-9a-f]{16}$/.test(stamp)) return false;
  return Boolean(await database
    .prepare("SELECT 1 FROM client_tokens WHERE user_id = ? AND substr(token_hash, 1, 16) = ?")
    .get(userId, stamp));
}

/**
 * Whose token this is, or nothing.
 *
 * The comparison is constant-time even though the lookup is by hash: the row
 * is found by the hash of what was presented, and the stored hash is then
 * checked against it, so a partial match cannot be walked towards a whole one.
 */
export async function profileForToken(token: string | undefined | null): Promise<number | null> {
  if (!looksLikeToken(token)) return null;
  const hash = await hashOf(token!);
  const row = await database
    .prepare("SELECT id, user_id, token_hash FROM client_tokens WHERE token_hash = ?")
    .get(hash) as { id: number; user_id: number; token_hash: string } | null;
  if (!row) return null;
  const presented = Buffer.from(hash, "hex");
  const stored = Buffer.from(row.token_hash, "hex");
  if (presented.length !== stored.length || !timingSafeEqual(presented, stored)) return null;
  await database
    .prepare("UPDATE client_tokens SET last_used_at = ? WHERE id = ?")
    .run(new Date().toISOString().slice(0, 19).replace("T", " "), row.id);
  return row.user_id;
}

/**
 * A profile named and proved in one go.
 *
 * Both halves are checked. A token finds its own profile, so the name adds
 * nothing to the lookup — but it means a token pasted against the wrong
 * profile is refused instead of quietly opening the library it does belong to,
 * which is the mistake somebody sharing an instance would actually make.
 */
export async function profileForNameAndToken(name: string, token: string): Promise<number | null> {
  const userId = await profileForToken(token);
  if (userId === null) return null;
  const profile = await database.prepare("SELECT name FROM users WHERE id = ?").get(userId) as { name: string } | null;
  if (!profile || profile.name.toLowerCase() !== name.trim().toLowerCase()) return null;
  return userId;
}

/** The `SID` a client sends back on every account request. */
export function sidFrom(cookieHeader: string | undefined): string | null {
  const match = cookieHeader?.match(/(?:^|;\s*)SID=([^;]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}
