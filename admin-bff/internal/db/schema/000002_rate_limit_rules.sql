CREATE TABLE IF NOT EXISTS rate_limit_rules (
    id BIGSERIAL PRIMARY KEY,
    service TEXT NOT NULL,
    phase TEXT NOT NULL,
    method TEXT NOT NULL,
    match_kind TEXT NOT NULL DEFAULT 'exact',
    path TEXT,
    path_pattern TEXT,
    app_key TEXT,
    priority INTEGER NOT NULL DEFAULT 100,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    key_by TEXT[] NOT NULL DEFAULT ARRAY['ip']::text[],
    strategy TEXT NOT NULL DEFAULT 'fixed_window',
    window_seconds INTEGER NOT NULL DEFAULT 60,
    max_requests INTEGER NOT NULL DEFAULT 100,
    requests_per_second DOUBLE PRECISION NOT NULL DEFAULT 100,
    burst INTEGER NOT NULL DEFAULT 200,
    client_ttl_seconds INTEGER NOT NULL DEFAULT 300,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT rate_limit_rules_strategy_check CHECK (strategy IN ('fixed_window', 'token_bucket')),
    CONSTRAINT rate_limit_rules_window_seconds_check CHECK (window_seconds > 0),
    CONSTRAINT rate_limit_rules_max_requests_check CHECK (max_requests > 0),
    CONSTRAINT rate_limit_rules_rps_check CHECK (requests_per_second > 0),
    CONSTRAINT rate_limit_rules_burst_check CHECK (burst > 0),
    CONSTRAINT rate_limit_rules_client_ttl_seconds_check CHECK (client_ttl_seconds > 0),
    CONSTRAINT rate_limit_rules_match_kind_check CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex')),
    CONSTRAINT rate_limit_rules_priority_check CHECK (priority >= 0),
    CONSTRAINT rate_limit_rules_path_shape_check CHECK (
        (match_kind = 'exact' AND path IS NOT NULL AND path_pattern IS NULL)
        OR
        (match_kind IN ('prefix', 'glob', 'regex') AND path IS NULL AND path_pattern IS NOT NULL)
    )
);

COMMENT ON TABLE rate_limit_rules IS 'Default dynamic rate-limit rules for Hertz monolith scaffolds, with exact/prefix/glob/regex support.';
COMMENT ON COLUMN rate_limit_rules.service IS 'Rule namespace / service identifier used to isolate lookups across services.';
COMMENT ON COLUMN rate_limit_rules.phase IS 'Execution stage label, typically pre_auth or post_auth.';
COMMENT ON COLUMN rate_limit_rules.method IS 'Normalized HTTP method used for rule lookup.';
COMMENT ON COLUMN rate_limit_rules.match_kind IS 'Match mode used during lookup: exact, prefix, glob, or regex.';
COMMENT ON COLUMN rate_limit_rules.path IS 'Exact request path; used only when match_kind=exact.';
COMMENT ON COLUMN rate_limit_rules.path_pattern IS 'Pattern path; used for prefix, glob, or regex matching.';
COMMENT ON COLUMN rate_limit_rules.app_key IS 'Optional app-specific override dimension; NULL means fallback rule.';
COMMENT ON COLUMN rate_limit_rules.priority IS 'Higher priority wins among matching pattern rules.';
COMMENT ON COLUMN rate_limit_rules.enabled IS 'Whether this dynamic rule is enabled.';
COMMENT ON COLUMN rate_limit_rules.key_by IS 'Runtime enforcement dimensions, such as ip, ak_path, or ak_user_uuid.';
COMMENT ON COLUMN rate_limit_rules.strategy IS 'Supported strategies in the template: fixed_window or token_bucket.';
COMMENT ON COLUMN rate_limit_rules.window_seconds IS 'Window size for fixed-window enforcement.';
COMMENT ON COLUMN rate_limit_rules.max_requests IS 'Maximum requests allowed within the fixed window.';
COMMENT ON COLUMN rate_limit_rules.requests_per_second IS 'Steady refill rate for token-bucket style enforcement.';
COMMENT ON COLUMN rate_limit_rules.burst IS 'Maximum burst size for token-bucket style enforcement.';
COMMENT ON COLUMN rate_limit_rules.client_ttl_seconds IS 'Suggested local limiter state TTL for this rule.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_rate_limit_rules_exact
    ON rate_limit_rules (service, phase, method, path, app_key)
    WHERE app_key IS NOT NULL AND match_kind = 'exact';

CREATE UNIQUE INDEX IF NOT EXISTS ux_rate_limit_rules_fallback
    ON rate_limit_rules (service, phase, method, path)
    WHERE app_key IS NULL AND match_kind = 'exact';

CREATE UNIQUE INDEX IF NOT EXISTS ux_rate_limit_rules_pattern_app
    ON rate_limit_rules (service, phase, method, match_kind, path_pattern, app_key, priority)
    WHERE app_key IS NOT NULL AND match_kind <> 'exact';

CREATE UNIQUE INDEX IF NOT EXISTS ux_rate_limit_rules_pattern_fallback
    ON rate_limit_rules (service, phase, method, match_kind, path_pattern, priority)
    WHERE app_key IS NULL AND match_kind <> 'exact';