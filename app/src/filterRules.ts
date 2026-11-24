import { database } from "./database";

interface FilterRule {
  id: number;
  pattern: string;
  match_type: "contains" | "regex";
  field: "title" | "description" | "both";
  action: "reject" | "whitelist";
  channel_id: string | null;
  user_id: number | null;
}

function matches(rule: FilterRule, title: string, description: string): boolean {
  const haystacks: string[] = [];
  if (rule.field === "title" || rule.field === "both") haystacks.push(title);
  if (rule.field === "description" || rule.field === "both") haystacks.push(description);
  if (rule.match_type === "regex") {
    try {
      const re = new RegExp(rule.pattern, "i");
      return haystacks.some((h) => re.test(h));
    } catch {
      return false;
    }
  }
  const needle = rule.pattern.toLowerCase();
  return haystacks.some((h) => h.toLowerCase().includes(needle));
}

// Archive for one profile, but only if the video is still in their inbox.
const archiveForUser = database.prepare(
  `INSERT INTO user_videos (user_id, video_id, status) VALUES (?, ?, 'archived')
   ON CONFLICT(user_id, video_id) DO UPDATE SET status = 'archived' WHERE user_videos.status = 'inbox'`
);

/**
 * Apply every profile's filter rules to a single new video. Each rule carries
 * its owner (user_id), so rules are grouped per profile and evaluated in order;
 * the video is archived for that profile on the first reject hit (or the first
 * whitelist miss), exactly as in the single-user version — just per user.
 */
export async function applyFilterRules(videoId: string, channelId: string, title: string, description: string) {
  const rules = await database
    .prepare("SELECT * FROM filter_rules WHERE channel_id IS NULL OR channel_id = ?")
    .all(channelId) as FilterRule[];
  const byUser = new Map<number, FilterRule[]>();
  for (const r of rules) {
    if (r.user_id == null) continue;
    const list = byUser.get(r.user_id);
    if (list) list.push(r);
    else byUser.set(r.user_id, [r]);
  }
  for (const [userId, userRules] of byUser) {
    for (const rule of userRules) {
      const hit = matches(rule, title, description);
      if ((rule.action === "reject" && hit) || (rule.action === "whitelist" && !hit)) {
        await archiveForUser.run(userId, videoId);
        break;
      }
    }
  }
}

/** Apply a single rule to all of its owner's inbox videos. Returns count archived. */
export async function applyFilterRuleToAll(ruleId: number): Promise<number> {
  const rule = await database.prepare("SELECT * FROM filter_rules WHERE id = ?").get(ruleId) as FilterRule | null;
  if (!rule || rule.user_id == null) return 0;

  const where = rule.channel_id
    ? "COALESCE(uv.status, 'inbox') = 'inbox' AND v.channel_id = ?"
    : "COALESCE(uv.status, 'inbox') = 'inbox'";
  const args = rule.channel_id ? [rule.user_id, rule.channel_id] : [rule.user_id];
  const videos = await database.prepare(
    `SELECT v.video_id, v.channel_id, v.title, v.description
     FROM videos v
     LEFT JOIN user_videos uv ON uv.video_id = v.video_id AND uv.user_id = ?
     WHERE ${where}`
  ).all(...args) as { video_id: string; channel_id: string; title: string; description: string }[];

  let count = 0;
  for (const v of videos) {
    const hit = matches(rule, v.title, v.description);
    const shouldArchive = rule.action === "reject" ? hit : !hit;
    if (shouldArchive) {
      await archiveForUser.run(rule.user_id, v.video_id);
      count++;
    }
  }
  return count;
}

/*
 * A video is filtered once, when it arrives, by the words it had then. Those
 * can change later: a live stream announced under one title goes out under
 * another ("… | 2 Players Live"), a feed title is swapped for the channel
 * page's, a description fills in. Without a second look, a reject rule that
 * fits the words the video ended up with never sees them.
 *
 * So a write that may change them is wrapped: when a video that was already
 * here comes out of it with other words, the reject rules run on it again.
 * Only reject rules, and only for a video still in a profile's inbox: a later
 * title can still keep a video out of a feed, but it never takes away one a
 * whitelist let in, and nothing the profile already sorted is touched.
 */
type VideoWords = { channel_id: string; title: string; title_original: string | null; description: string };

const wordsOf = database.prepare("SELECT channel_id, title, title_original, description FROM videos WHERE video_id = ?");

async function videoWords(videoId: string): Promise<VideoWords | null> {
  return ((await wordsOf.get(videoId)) as VideoWords | null) ?? null;
}

// An uploader's title filled in with what was shown all along is no new word.
function sameWords(a: VideoWords, b: VideoWords): boolean {
  return a.title === b.title && (a.title_original || a.title) === (b.title_original || b.title) && a.description === b.description;
}

/** The reject rules again, on the words a video has now: the shown title and the uploader's own. */
export async function refilterVideo(videoId: string): Promise<void> {
  const words = await videoWords(videoId);
  if (!words) return;
  const rules = await database
    .prepare("SELECT * FROM filter_rules WHERE action = 'reject' AND user_id IS NOT NULL AND (channel_id IS NULL OR channel_id = ?)")
    .all(words.channel_id) as FilterRule[];
  const titles = [words.title, words.title_original ?? ""].filter((title, k, all) => title && all.indexOf(title) === k);
  if (!titles.length) titles.push(""); // a description rule still has something to look at
  const archived = new Set<number>();
  for (const rule of rules) {
    const userId = rule.user_id as number;
    if (archived.has(userId)) continue;
    if (titles.some((title) => matches(rule, title, words.description))) {
      await archiveForUser.run(userId, videoId);
      archived.add(userId);
    }
  }
}

type Statement = { run: (...params: any[]) => Promise<unknown> };

/**
 * A statement that writes a video's words, which runs the reject rules again
 * when it changed them. `videoIdAt` is where the video id is in its parameters.
 * A video it creates is left alone: arriving, it is filtered where it arrives.
 */
export function refilteringWrites<T extends Statement>(statement: T, videoIdAt = 0): T {
  const run = async (...params: unknown[]) => {
    const videoId = String(params[videoIdAt]);
    const before = await videoWords(videoId);
    const result = await statement.run(...params);
    if (before) {
      const after = await videoWords(videoId);
      if (after && !sameWords(before, after)) await refilterVideo(videoId);
    }
    return result;
  };
  return { ...statement, run } as T;
}
