import { useEffect, useMemo } from "react";
import { useLocation } from "react-router-dom";
import { Undo2 } from "lucide-react";
import { useI18n } from "../../i18n";
import { Button } from "../ui";
import { noteYouTubeRedirect, withoutYouTubeRedirectMarker, youTubeReturnUrl } from "../../youtubeUrl";

/**
 * "Back to YouTube" for a video the browser extension sent here from YouTube
 * (it marks the address with #ytRedirected). Goes back at the position
 * reached; other videos show nothing.
 */
export function WatchBackToYouTube({ videoId, currentPlaybackSeconds }: { videoId: string; currentPlaybackSeconds: () => number }) {
  const { t } = useI18n();
  const { hash } = useLocation();
  const cameFromYouTube = useMemo(() => noteYouTubeRedirect(hash, videoId), [hash, videoId]);
  useEffect(() => {
    // Keep the marker out of addresses that get copied or bookmarked.
    if (!cameFromYouTube) return;
    const current = window.location;
    const rest = withoutYouTubeRedirectMarker(current.hash);
    if (rest !== current.hash) window.history.replaceState(window.history.state, "", `${current.pathname}${current.search}${rest}`);
  }, [cameFromYouTube, videoId]);
  if (!cameFromYouTube) return null;
  return <Button
    className="watch-back-to-youtube"
    title={t("backToYouTube")}
    onClick={() => window.location.assign(youTubeReturnUrl(videoId, currentPlaybackSeconds()))}
  >
    <Undo2 />
    <span className="btn-label">{t("backToYouTube")}</span>
  </Button>;
}
