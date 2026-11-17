import { http } from "./apiHttp";

export type ChannelLiveFeedVisibility = "default" | "hidden";

// The channel response carries it; declared here beside the call that sets it.
declare module "./apiTypes" {
  interface Channel {
    live_feed_visibility?: ChannelLiveFeedVisibility;
  }
}

/** Leave one channel's livestreams out of the feed and the Live page, or not. */
export function setChannelLiveFeedVisibility(id: string, visibility: ChannelLiveFeedVisibility) {
  return http(`/channels/${id}/live-feed`, { method: "PUT", body: JSON.stringify({ visibility }) });
}
