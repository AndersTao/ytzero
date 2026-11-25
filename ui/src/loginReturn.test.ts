import { describe, expect, test } from "bun:test";
import { loginReturnPath, oidcLoginHref, returnAfterLogin } from "./loginReturn";

describe("login return", () => {
  test("keeps the pairing page with its code", () => {
    expect(loginReturnPath({ pathname: "/tv/pair", search: "", hash: "#code=ABCD2345" })).toBe("/tv/pair#code=ABCD2345");
  });

  test("goes to Main from the start page or an odd address", () => {
    expect(loginReturnPath({ pathname: "/", search: "?auth_error=oidc", hash: "" })).toBe("/");
    expect(loginReturnPath({ pathname: "//evil.example/x", search: "", hash: "" })).toBe("/");
  });

  test("SSO link carries the page along only when it is not Main", () => {
    expect(oidcLoginHref("/")).toBe("/api/auth/oidc/login");
    expect(oidcLoginHref("/tv/pair#code=ABCD2345")).toBe("/api/auth/oidc/login?return_to=%2Ftv%2Fpair%23code%3DABCD2345");
  });

  test("reloads when returning to the same page, replaces otherwise", () => {
    const calls: string[] = [];
    const place = (pathname: string, hash = "") =>
      ({ pathname, search: "", hash, reload: () => calls.push("reload"), replace: (to: string) => calls.push(`replace ${to}`) }) as unknown as Location;
    returnAfterLogin("/tv/pair#code=ABCD2345", place("/tv/pair", "#code=ABCD2345"));
    returnAfterLogin("/", place("/"));
    expect(calls).toEqual(["reload", "replace /"]);
  });
});
