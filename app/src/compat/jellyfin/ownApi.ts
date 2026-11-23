import type { Hono } from "hono";

/**
 * This server's own API, asked as the signed-in profile.
 *
 * The Jellyfin routes translate; they do not decide. What Main holds, what
 * counts as watched, where playback resumes and how a video is streamed are
 * all the API's, and it is asked the way the Apple TV app asks it: with the
 * profile's session as a bearer token. A rule changed there is a rule changed
 * here, without a second copy to forget.
 */
export class OwnApi {
  constructor(private readonly app: Hono, private readonly session: string, private readonly origin: string) {}

  async get<T>(path: string): Promise<T> {
    return this.send<T>("GET", path);
  }

  async send<T>(method: string, path: string, body?: unknown): Promise<T> {
    const response = await this.raw(method, path, body);
    if (!response.ok) throw new OwnApiError(response.status, path);
    const text = await response.text();
    return (text ? JSON.parse(text) : {}) as T;
  }

  /** The answer as it is, for callers that read its status themselves. */
  raw(method: string, path: string, body?: unknown): Promise<Response> {
    const headers = new Headers({ Authorization: `Bearer ${this.session}`, Accept: "application/json" });
    if (body !== undefined) headers.set("Content-Type", "application/json");
    return Promise.resolve(this.app.request(`${this.origin}/api${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }));
  }
}

export class OwnApiError extends Error {
  constructor(readonly status: number, path: string) {
    super(`own API ${path} answered ${status}`);
  }
}
