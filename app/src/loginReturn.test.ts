import { afterAll, describe, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { runIsolatedTestFile } from "../tests/isolatedTestFile";
import { safeReturnPath } from "./loginReturn";

describe("the page a sign-in returns to", () => {
  test("keeps a page on this server, #fragment included", () => {
    expect(safeReturnPath("/tv/pair#code=ABCD2345")).toBe("/tv/pair#code=ABCD2345");
    expect(safeReturnPath("/settings?tab=access")).toBe("/settings?tab=access");
  });

  test("falls back to Main for anything else", () => {
    for (const bad of [undefined, "", "tv/pair", "//evil.example/x", "/\\evil.example", "https://evil.example/", "/api/auth/logout", "/a\nb", `/${"x".repeat(3000)}`]) {
      expect(safeReturnPath(bad)).toBe("/");
    }
  });
});

const ISOLATION_FLAG = "YTZERO_LOGIN_RETURN_TEST_ISOLATED";
if (process.env[ISOLATION_FLAG] !== "1") {
  test("the SSO round trip runs in an isolated application runtime", async () => {
    await runIsolatedTestFile("src/loginReturn.test.ts", ISOLATION_FLAG);
  });
} else {
  const root = mkdtempSync(resolve(tmpdir(), "ytzero-login-return-"));
  process.env.DB_PATH = resolve(root, "login.db");
  process.env.DOWNLOADS_DIR = resolve(root, "downloads");
  // The identity provider is out of reach here: stand in for its two ends.
  const auth = await import("./auth");
  mock.module("./auth", () => ({
    ...auth,
    oidcAuthUrl: async () => ({ url: "https://id.example.com/authorize?state=s", flowId: "flow-1" }),
    oidcCallback: async () => ({ user_id: 1, mode: "mapped", is_admin: false, permission_group_uuid: null }),
  }));
  const { db } = await import("./db");
  const { database } = await import("./database");
  const { api } = await import("./routes");
  afterAll(async () => { db.close(); await database.close(); rmSync(root, { recursive: true, force: true }); });

  const cookiesOf = (response: Response) => response.headers.getSetCookie().map((line) => line.split(";")[0]);

  describe("signing in with SSO from a TV's approval page", () => {
    test("comes back to that page with the TV's code", async () => {
      const start = await api.request("http://localhost/auth/oidc/login?return_to=%2Ftv%2Fpair%23code%3DABCD2345");
      expect(start.status).toBe(302);
      expect(start.headers.get("location")).toBe("https://id.example.com/authorize?state=s");
      const sent = cookiesOf(start).join("; ");
      expect(sent).toContain("ytzero_login_return=");

      const back = await api.request("http://localhost/auth/oidc/callback?code=c&state=s", { headers: { Cookie: sent } });
      expect(back.status).toBe(302);
      expect(back.headers.get("location")).toBe("/tv/pair#code=ABCD2345");
      expect(cookiesOf(back)).toContain("ytzero_login_return=");
    });

    test("without a page, or with one elsewhere, lands on Main as before", async () => {
      for (const query of ["", "?return_to=https%3A%2F%2Fevil.example%2F"]) {
        const start = await api.request(`http://localhost/auth/oidc/login${query}`);
        const back = await api.request("http://localhost/auth/oidc/callback?code=c&state=s", { headers: { Cookie: cookiesOf(start).join("; ") } });
        expect(back.headers.get("location")).toBe("/");
      }
    });
  });
}
