// The YT Zero extension's popup in Safari: on a YouTube video it saves the
// video to the profile's "Saved for later" row, or hands it to the YT Zero
// app at the position reached here. Saving goes through the extension's
// native handler, which uses the session of the profile watching in the app,
// so nothing is signed in to in Safari and the extension needs no website
// access beyond the tab it is opened on.
"use strict";

const ext = globalThis.browser ?? globalThis.chrome;
const text = (key, ...substitutions) => ext.i18n.getMessage(key, substitutions);
const element = (id) => document.getElementById(id);

// What the server accepts as a video id (`validYouTubeVideoId`).
const VIDEO_ID = /^[A-Za-z0-9_-]{6,20}$/;

/** The video a YouTube address shows, with the position it asks for. */
function videoFromUrl(address) {
  let url;
  try {
    url = new URL(address);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase();
  const path = url.pathname.split("/").filter(Boolean);
  let id = null;
  if (host === "youtu.be") {
    id = path[0] ?? null;
  } else if (/(^|\.)youtube(-nocookie)?\.com$/.test(host)) {
    if (path[0] === "watch") id = url.searchParams.get("v");
    else if (path.length >= 2 && ["shorts", "live", "embed", "v"].includes(path[0])) id = path[1];
  }
  if (!id || !VIDEO_ID.test(id)) return null;
  const start = seconds(url.searchParams.get("t") ?? url.searchParams.get("start") ?? "");
  return { id, start };
}

/** "90", "90s", "1m30s" or "1h2m3s" in seconds; null otherwise. */
function seconds(value) {
  if (!value) return null;
  if (/^\d+(\.\d+)?$/.test(value)) return Number(value);
  const match = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/i.exec(value);
  if (!match || !match[0]) return null;
  return Number(match[1] ?? 0) * 3600 + Number(match[2] ?? 0) * 60 + Number(match[3] ?? 0);
}

function appUrl(video) {
  const url = new URL("ytzero://play");
  url.searchParams.set("v", video.id);
  if (video.start > 0) url.searchParams.set("t", String(Math.floor(video.start)));
  return url.toString();
}

async function native(message) {
  // An answer that never comes must not leave the popup waiting for good.
  const timeout = new Promise((resolve) => setTimeout(() => resolve({ error: "unreachable" }), 15000));
  try {
    return await Promise.race([ext.runtime.sendNativeMessage("app.ytzero", message), timeout]);
  } catch {
    return { error: "unreachable" };
  }
}

/** Pauses YouTube's player and says how far it got; null when it cannot be read. */
async function pauseAndReadPosition(tabId) {
  try {
    const [result] = await ext.scripting.executeScript({
      target: { tabId },
      func: () => {
        const video = document.querySelector("video");
        if (!video) return null;
        video.pause();
        return Number.isFinite(video.currentTime) ? video.currentTime : null;
      },
    });
    return typeof result?.result === "number" ? result.result : null;
  } catch {
    return null;
  }
}

function showStatus(message) {
  element("status").textContent = message;
}

function errorText(answer) {
  switch (answer?.error) {
    case "signedOut": return text("signedOut");
    case "restricted": return text("restricted");
    case "unreachable": return text("unreachable");
    default: return text("failed", answer?.message || answer?.error || "?");
  }
}

async function start() {
  element("save").textContent = text("saveForLater");
  element("open").textContent = text("openInApp");
  element("openApp").textContent = text("openApp");

  const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
  const video = tab?.url ? videoFromUrl(tab.url) : null;

  element("openApp").addEventListener("click", async () => {
    await ext.tabs.update(tab.id, { url: "ytzero://" });
    window.close();
  });

  if (!video) {
    showStatus(text("notAVideo"));
    return;
  }
  if (tab.title) {
    element("title").textContent = tab.title.replace(/ - YouTube$/, "");
    element("title").hidden = false;
  }
  element("actions").hidden = false;

  element("save").addEventListener("click", async () => {
    element("save").disabled = true;
    showStatus(text("saving"));
    const answer = await native({ action: "save", videoId: video.id });
    if (answer?.ok) {
      showStatus(text(answer.already ? "alreadySaved" : "saved"));
    } else {
      element("save").disabled = false;
      showStatus(errorText(answer));
      if (answer?.error === "signedOut") element("openApp").hidden = false;
    }
  });

  element("open").addEventListener("click", async () => {
    const position = await pauseAndReadPosition(tab.id);
    // Live streams have no position to carry over: the app joins them live.
    const target = { id: video.id, start: position ?? video.start };
    // Safari asks whether to open the page in YT Zero, and closes the popup.
    await ext.tabs.update(tab.id, { url: appUrl(target) });
    window.close();
  });

  // Signed out in the app: say so before a save is tried.
  const status = await native({ action: "status" });
  if (status?.signedIn === false) {
    element("save").disabled = true;
    element("openApp").hidden = false;
    showStatus(text("signedOut"));
  }
}

start();
