CREATE TABLE IF NOT EXISTS daily_quota (
  day TEXT NOT NULL,
  key TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, key)
);

CREATE INDEX IF NOT EXISTS idx_daily_quota_day ON daily_quota(day);
