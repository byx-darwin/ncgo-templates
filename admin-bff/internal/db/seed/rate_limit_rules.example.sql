-- Example seed data for the generated rate_limit_rules table.
-- Run manually in development or copy into your own bootstrap workflow.

-- Anonymous / invalid request fallback rule before auth.
INSERT INTO rate_limit_rules (
    service, phase, method, match_kind, path, path_pattern, app_key, priority,
    enabled, key_by, strategy, window_seconds, max_requests,
    requests_per_second, burst, client_ttl_seconds
) VALUES (
    'order-api', 'pre_auth', 'POST', 'exact', '/v1/orders', NULL, NULL, 100,
    TRUE, ARRAY['ip'], 'fixed_window', 60, 120, 120, 120, 300
);

-- App-specific exact rule after auth.
INSERT INTO rate_limit_rules (
    service, phase, method, match_kind, path, path_pattern, app_key, priority,
    enabled, key_by, strategy, window_seconds, max_requests,
    requests_per_second, burst, client_ttl_seconds
) VALUES (
    'order-api', 'post_auth', 'POST', 'exact', '/v1/orders', NULL, 'demo-app', 200,
    TRUE, ARRAY['ak_path'], 'fixed_window', 60, 30, 30, 60, 300
);

-- Fallback prefix rule for nested order resources.
INSERT INTO rate_limit_rules (
    service, phase, method, match_kind, path, path_pattern, app_key, priority,
    enabled, key_by, strategy, window_seconds, max_requests,
    requests_per_second, burst, client_ttl_seconds
) VALUES (
    'order-api', 'post_auth', 'GET', 'prefix', NULL, '/v1/orders/', NULL, 50,
    TRUE, ARRAY['ak_user_uuid'], 'fixed_window', 60, 100, 100, 100, 300
);

-- App-specific glob rule that overrides the fallback prefix rule.
INSERT INTO rate_limit_rules (
    service, phase, method, match_kind, path, path_pattern, app_key, priority,
    enabled, key_by, strategy, window_seconds, max_requests,
    requests_per_second, burst, client_ttl_seconds
) VALUES (
    'order-api', 'post_auth', 'GET', 'glob', NULL, '/v1/orders/*/items', 'demo-app', 150,
    TRUE, ARRAY['ak_path'], 'fixed_window', 60, 40, 40, 80, 300
);

-- Regex rule for detail-style order paths; use sparingly because regex is harder to index and maintain.
INSERT INTO rate_limit_rules (
    service, phase, method, match_kind, path, path_pattern, app_key, priority,
    enabled, key_by, strategy, window_seconds, max_requests,
    requests_per_second, burst, client_ttl_seconds
) VALUES (
    'order-api', 'post_auth', 'GET', 'regex', NULL, '^/v1/orders/[0-9]+$', NULL, 120,
    TRUE, ARRAY['ak_user_uuid'], 'fixed_window', 60, 25, 25, 50, 300
);