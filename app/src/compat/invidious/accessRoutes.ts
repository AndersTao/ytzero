import type { Context, Hono } from "hono";
import { isChildUser } from "../../childTime";
import { invidiousCompatEnabled } from "./enabled";
import { MAX_TOKENS_PER_PROFILE, mintToken, renameToken, revokeToken, tokenCount, tokenStates } from "./tokens";

type ApiEnvironment = { Variables: { userId: number; sessionAdmin?: boolean; profileAdmin?: boolean } };
type Api = Hono<ApiEnvironment>;
type ApiContext = Context<ApiEnvironment>;

/**
 * Where a profile gets the tokens its apps sign in with: one per app or
 * device, each under a name, so one can be revoked without signing the
 * others out.
 *
 * These live on the authenticated API rather than beside the dialect's own
 * routes: minting a credential is something the person already signed in here
 * does, for themselves. A client never reaches them.
 */
export function registerInvidiousAccessRoutes(api: Api, currentUserId: (context: ApiContext) => number): void {
  api.get("/invidious/tokens", async (c) => {
    const tokens = await tokenStates(currentUserId(c));
    return c.json({
      enabled: invidiousCompatEnabled(),
      limit: MAX_TOKENS_PER_PROFILE,
      tokens: tokens.map((token) => ({ id: token.id, name: token.name, created_at: token.createdAt, last_used_at: token.lastUsedAt })),
    });
  });

  /*
   * The only moment the token exists in readable form. What is stored is a
   * keyed hash, so this answer cannot be produced again.
   */
  api.post("/invidious/tokens", async (c) => {
    const userId = currentUserId(c);
    /*
     * Not for a restricted profile. The dialect serves a library without any of
     * the limits this server puts on one — no local-only rule, no hidden live
     * streams, no watch-time ceiling — so a token minted here would be a way
     * around all of them, held by the person they apply to.
     */
    if (await isChildUser(userId)) return c.json({ error: "not allowed" }, 403);
    if (await tokenCount(userId) >= MAX_TOKENS_PER_PROFILE) return c.json({ error: "too many tokens" }, 409);
    const body = await c.req.json().catch(() => ({})) as { name?: unknown };
    const { id, token } = await mintToken(userId, body.name);
    return c.json({ id, token });
  });

  api.patch("/invidious/tokens/:id", async (c) => {
    const body = await c.req.json().catch(() => ({})) as { name?: unknown };
    const renamed = await renameToken(currentUserId(c), Number(c.req.param("id")), body.name);
    return renamed ? c.json({ ok: true }) : c.json({ error: "not found" }, 404);
  });

  api.delete("/invidious/tokens/:id", async (c) => {
    const revoked = await revokeToken(currentUserId(c), Number(c.req.param("id")));
    return revoked ? c.json({ ok: true }) : c.json({ error: "not found" }, 404);
  });
}
