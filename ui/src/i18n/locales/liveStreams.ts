const en = {
  recordedLiveBadge: "LIVESTREAM",
  channelLiveFeed: "Livestreams",
  channelLiveFeedHint: "Hidden livestreams can still be found on the channel's own page.",
  channelLiveFeedHidden: "Hide from feed and Live",
};

type LiveStreamMessages = typeof en;

const de: LiveStreamMessages = {
  recordedLiveBadge: "LIVESTREAM",
  channelLiveFeed: "Livestreams",
  channelLiveFeedHint: "Ausgeblendete Livestreams bleiben auf der Kanalseite sichtbar.",
  channelLiveFeedHidden: "In Feed und Live ausblenden",
};

export const liveStreamMessages = { en, de, pl: en, fr: en, es: en, "pt-BR": en, ru: en, ja: en, hu: en } as const;
