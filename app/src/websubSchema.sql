-- Push notifications from YouTube (WebSub / PubSubHubbub), kept to itself.
--
-- Its own file, like the other optional features: nothing here references
-- users, videos or channels, so the feature can be removed by deleting this
-- file, dropping its line from the canonical list and one migration that drops
-- the table.
--
-- One row per channel this instance has asked the hub to push. The secret is
-- what the hub signs each notification with; it has to be kept as is, because
-- the signature is checked against it, but it only ever authenticates the hub
-- to this instance.

CREATE TABLE IF NOT EXISTS websub_subscriptions (
  channel_id           TEXT NOT NULL PRIMARY KEY,
  secret               TEXT NOT NULL,
  -- The exact callback the hub was given, so a changed public address is
  -- noticed and the subscription renewed under the new one.
  callback_url         TEXT NOT NULL,
  -- pending (asked, not yet verified), active (verified by the hub),
  -- failed (the hub refused or could not be reached), unsubscribing.
  state                TEXT NOT NULL DEFAULT 'pending',
  requested_at         TEXT,
  verified_at          TEXT,
  lease_expires_at     TEXT,
  retry_after          TEXT,
  last_notification_at TEXT,
  last_error           TEXT
);

CREATE INDEX IF NOT EXISTS idx_websub_subscriptions_state ON websub_subscriptions(state);
