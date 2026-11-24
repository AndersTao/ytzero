-- Client access, kept to itself.
--
-- Its own file, the way Dailymotion and the community posts have theirs.
-- Nothing here references users, videos or channels: a profile is named by its
-- id and nothing else, so removing the feature is deleting this file, dropping
-- its line from the canonical list, and one migration that drops this table.
--
-- What is stored is never the token. A client authenticates by presenting it,
-- and what is kept is a keyed hash of it — enough to recognise the token on
-- sight, not enough to reconstruct it. Deleting a row is what revocation is:
-- every device holding that token is turned away at once, and the profile's
-- other tokens go on working.

CREATE TABLE IF NOT EXISTS client_tokens (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  -- A profile can hold several, one per app or device, each under a name it
  -- was given so it can be told apart later ("Yattee on the iPad").
  user_id      INTEGER NOT NULL,
  name         TEXT NOT NULL DEFAULT '',
  token_hash   TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  -- When a client last presented it, so a token nobody uses can be seen.
  last_used_at TEXT
);

-- The lookup a request makes: from the hash of what was presented, to whose it
-- is. Unique because two profiles sharing a token would make that answer a
-- guess.
CREATE UNIQUE INDEX IF NOT EXISTS idx_client_tokens_hash ON client_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_client_tokens_user ON client_tokens(user_id);
