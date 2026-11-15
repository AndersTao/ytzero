/**
 * Caption defaults come from two layers: the profile preference ("auto-enable
 * captions") and an optional per-channel override that either forces one
 * language or turns captions off for that channel entirely.
 */
export interface WatchCaptionSources {
  channelMode?: "off" | "language" | null;
  channelLanguage?: string | null;
  playerCc?: string;
  playerCcLang?: string;
  playerHl?: string;
}

export interface WatchCaptions {
  /** Show a caption track as soon as playback starts. */
  defaultOn: boolean;
  language: string;
  /** The channel bans captions outright, rather than merely not auto-enabling them. */
  channelOff: boolean;
}

export function resolveWatchCaptions(sources: WatchCaptionSources): WatchCaptions {
  const channelOff = sources.channelMode === "off";
  const channelLanguage = sources.channelMode === "language" ? sources.channelLanguage || null : null;
  return {
    channelOff,
    defaultOn: !channelOff && (Boolean(channelLanguage) || sources.playerCc === "1"),
    language: channelLanguage || sources.playerCcLang || sources.playerHl || "en",
  };
}

/**
 * Never omit cc_load_policy: an embed created without it restores the caption
 * track stored in the browser's YouTube preference, so captions would come back
 * even though the profile keeps them off.
 */
export function captionPlayerVars(defaultOn: boolean, language: string): { cc_load_policy: number; cc_lang_pref?: string } {
  return defaultOn ? { cc_load_policy: 1, cc_lang_pref: language } : { cc_load_policy: 0 };
}

interface CaptionModulePlayer {
  unloadModule?: (module: string) => void;
}

/** Remove the caption track from a YouTube embed ("cc" is the module's older name). */
export function unloadCaptions(player: CaptionModulePlayer | null | undefined): void {
  try { player?.unloadModule?.("captions"); } catch {}
  try { player?.unloadModule?.("cc"); } catch {}
}

/**
 * cc_load_policy=0 is not "off": YouTube reads it as "no preference" and still
 * shows the track the embed remembers, or the one the creator marked as default.
 * Unloading the captions module is the switch that holds. YouTube loads the
 * module again when playback starts, so it is unloaded when the player is ready,
 * when it first plays, and once more shortly after. From then on the viewer's own
 * CC button decides.
 */
export function createCaptionsOffGuard(keepOff: boolean, lateMs = 1500) {
  let started = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const unload = unloadCaptions;
  return {
    ready(player: CaptionModulePlayer | null | undefined) {
      if (keepOff && !started) unload(player);
    },
    playing(player: CaptionModulePlayer | null | undefined) {
      if (!keepOff || started) return;
      started = true;
      unload(player);
      timer = setTimeout(() => unload(player), lateMs);
    },
    dispose() {
      if (timer) clearTimeout(timer);
    },
  };
}
