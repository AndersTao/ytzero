import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark } from "lucide-react";
import type { Video } from "../api";
import { http } from "../apiHttp";
import { useI18n } from "../i18n";
import type { PlaybackQueueContext, PlayVideo } from "../playbackQueue";
import { useHScroll } from "../useHScroll";
import VideoCard from "./VideoCard";
import { Button, RevealRegion } from "./ui";

type SavedForLater = { playlist: { id: number; portable_uuid: string; name: string } | null; videos: Video[] };

/**
 * Main's "Saved for later" row: videos saved from YouTube through the browser
 * extension's right-click menu. They live in one ordinary playlist, which the
 * heading opens. Reloads when the tab comes back into view, since saving
 * happens in another tab.
 */
export function SavedForLaterShelf({ hidden, cardWidth, gridSize, onPlay, onCountChange }: {
  hidden: boolean;
  cardWidth: number;
  gridSize: string;
  onPlay: PlayVideo;
  onCountChange: (count: number) => void;
}) {
  const { t } = useI18n();
  const [saved, setSaved] = useState<SavedForLater>({ playlist: null, videos: [] });
  const [expanded, setExpanded] = useState(false);
  const scroll = useHScroll();

  const load = useCallback(() => {
    http<SavedForLater>("/saved-for-later").then(setSaved).catch(() => {});
  }, []);
  useEffect(() => {
    load();
    const onVisible = () => { if (document.visibilityState === "visible") load(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  const visible = !hidden && saved.videos.length > 0;
  useEffect(() => onCountChange(visible ? saved.videos.length : 0), [onCountChange, saved.videos.length, visible]);

  const queue: PlaybackQueueContext | undefined = saved.playlist
    ? { version: 1, kind: "user-playlist", playlistUuid: saved.playlist.portable_uuid, sort: "added-newest" }
    : undefined;

  return (
    <RevealRegion open={visible}>
      <div className="time-section saved-for-later-section">
        <div className="time-section-header">
          <Bookmark size={16} />
          {saved.playlist ? <Link to={`/playlists/${saved.playlist.id}`}>{t("savedForLater")}</Link> : <span>{t("savedForLater")}</span>}
        </div>
        <div className={`h-scroll-wrap${scroll.shadowLeft ? " shadow-left" : ""}${scroll.shadowRight ? " shadow-right" : ""}`}>
          <div
            id="saved-for-later-list"
            className={`h-scroll-row h-scroll-row--${gridSize} mobile-preview-row${expanded ? " is-expanded" : ""}`}
            ref={scroll.ref}
          >
            {saved.videos.map((video) => (
              <div key={video.video_id} className="h-scroll-card" style={{ width: cardWidth }}>
                <VideoCard video={video} onPlay={(picked) => onPlay(picked, queue)} onChanged={load} />
              </div>
            ))}
          </div>
        </div>
        {saved.videos.length > 3 && (
          <div className="mobile-preview-toggle">
            <Button size="sm" aria-expanded={expanded} aria-controls="saved-for-later-list" onClick={() => setExpanded((value) => !value)}>
              {t(expanded ? "showLess" : "showMore")}
            </Button>
          </div>
        )}
      </div>
    </RevealRegion>
  );
}
