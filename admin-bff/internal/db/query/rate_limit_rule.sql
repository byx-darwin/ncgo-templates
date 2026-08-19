-- Exact rule for a specific app_key.
-- name: GetRateLimitExactRuleByAppKey :one
SELECT
    enabled,
    key_by,
    strategy,
    window_seconds,
    max_requests,
    requests_per_second,
    burst,
    client_ttl_seconds
FROM rate_limit_rules
WHERE service = $1
  AND phase = $2
  AND (method = $3 OR method = '*')
  AND match_kind = 'exact'
  AND (path = $4 OR path = '*')
  AND app_key = $5
ORDER BY priority DESC, updated_at DESC, id DESC
LIMIT 1;

-- Exact fallback rule when app_key is absent or no app-specific override exists.
-- name: GetRateLimitExactRuleFallback :one
SELECT
    enabled,
    key_by,
    strategy,
    window_seconds,
    max_requests,
    requests_per_second,
    burst,
    client_ttl_seconds
FROM rate_limit_rules
WHERE service = $1
  AND phase = $2
  AND (method = $3 OR method = '*')
  AND match_kind = 'exact'
  AND (path = $4 OR path = '*')
  AND app_key IS NULL
ORDER BY priority DESC, updated_at DESC, id DESC
LIMIT 1;

-- Pattern rule for a specific app_key. Exact rules are evaluated first in repository code.
-- Ordering policy for pattern rules:
--   1. higher priority first
--   2. matcher class rank: prefix > glob > regex
--   3. higher specificity score first
--      - prefix: longer prefix wins
--      - glob: more literal characters wins
--      - regex: more literal-ish characters wins
--   4. raw pattern length, then updated_at/id as stable tie-breakers
-- name: GetRateLimitPatternRuleByAppKey :one
SELECT
    enabled,
    key_by,
    strategy,
    window_seconds,
    max_requests,
    requests_per_second,
    burst,
    client_ttl_seconds
FROM rate_limit_rules
WHERE service = $1
  AND phase = $2
  AND (method = $3 OR method = '*')
  AND app_key = $5
  AND (
        path_pattern = '*'
     OR (match_kind = 'prefix' AND $4 LIKE path_pattern || '%')
     OR (match_kind = 'glob' AND $4 LIKE REPLACE(REPLACE(REPLACE(REPLACE(path_pattern, E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_'), '*', '%') ESCAPE E'\\')
     OR (match_kind = 'regex' AND $4 ~ path_pattern)
  )
ORDER BY
    priority DESC,
    CASE match_kind
        WHEN 'prefix' THEN 3
        WHEN 'glob' THEN 2
        WHEN 'regex' THEN 1
        ELSE 0
    END DESC,
    CASE match_kind
        WHEN 'prefix' THEN CHAR_LENGTH(path_pattern)
        WHEN 'glob' THEN CHAR_LENGTH(REPLACE(path_pattern, '*', ''))
        WHEN 'regex' THEN CHAR_LENGTH(REGEXP_REPLACE(path_pattern, '[^A-Za-z0-9/_-]+', '', 'g'))
        ELSE 0
    END DESC,
    CHAR_LENGTH(path_pattern) DESC,
    updated_at DESC,
    id DESC
LIMIT 1;

-- Pattern fallback rule when app_key is absent or no app-specific override exists.
-- name: GetRateLimitPatternRuleFallback :one
SELECT
    enabled,
    key_by,
    strategy,
    window_seconds,
    max_requests,
    requests_per_second,
    burst,
    client_ttl_seconds
FROM rate_limit_rules
WHERE service = $1
  AND phase = $2
  AND (method = $3 OR method = '*')
  AND app_key IS NULL
  AND (
        path_pattern = '*'
     OR (match_kind = 'prefix' AND $4 LIKE path_pattern || '%')
     OR (match_kind = 'glob' AND $4 LIKE REPLACE(REPLACE(REPLACE(REPLACE(path_pattern, E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_'), '*', '%') ESCAPE E'\\')
     OR (match_kind = 'regex' AND $4 ~ path_pattern)
  )
ORDER BY
    priority DESC,
    CASE match_kind
        WHEN 'prefix' THEN 3
        WHEN 'glob' THEN 2
        WHEN 'regex' THEN 1
        ELSE 0
    END DESC,
    CASE match_kind
        WHEN 'prefix' THEN CHAR_LENGTH(path_pattern)
        WHEN 'glob' THEN CHAR_LENGTH(REPLACE(path_pattern, '*', ''))
        WHEN 'regex' THEN CHAR_LENGTH(REGEXP_REPLACE(path_pattern, '[^A-Za-z0-9/_-]+', '', 'g'))
        ELSE 0
    END DESC,
    CHAR_LENGTH(path_pattern) DESC,
    updated_at DESC,
    id DESC
LIMIT 1;