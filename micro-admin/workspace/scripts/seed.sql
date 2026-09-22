-- Seed data for micro-admin workspace
-- Run after migrations: psql -f scripts/seed.sql $DATABASE_URL
--
-- Default admin user: admin / Admin@123
-- Password hash generated with Argon2id: m=65536, t=3, p=4, salt=16B, key=32B

BEGIN;

-- Admin user
INSERT INTO users (uuid, username, password_hash, nickname, email, status)
VALUES (
    '00000000-0000-7000-8000-000000000001',
    'admin',
    '$argon2id$v=19$m=65536,t=3,p=4$UB+LQr6xMAdNEb+B/07sCg$TgpF26JvTuZ4Sx1MEb9Vxkom4L9FK/gnbCRSvM176JQ',
    'Administrator',
    'admin@example.com',
    1
) ON CONFLICT (username) DO NOTHING;

-- Roles
INSERT INTO roles (code, name, status, remark) VALUES
('super_admin', 'Super Administrator', 1, 'All permissions'),
('admin', 'Administrator', 1, 'Standard admin')
ON CONFLICT (code) DO NOTHING;

-- Permissions (code, type, name, path, method, sort, status)
INSERT INTO permissions (code, type, name, path, method, sort, status) VALUES
('dashboard', 'menu', 'Dashboard', '/dashboard', NULL, 0, 1),
('system', 'catalog', 'System', '/system', NULL, 1, 1),
('user', 'menu', 'User Management', '/system/user', NULL, 1, 1),
('user:list', 'api', 'List Users', '/api/v1/users', 'GET', 1, 1),
('user:read', 'api', 'Read User', '/api/v1/users/:id', 'GET', 2, 1),
('user:create', 'api', 'Create User', '/api/v1/users', 'POST', 3, 1),
('user:update', 'api', 'Update User', '/api/v1/users/:id', 'PUT', 4, 1),
('user:delete', 'api', 'Delete User', '/api/v1/users/:id', 'DELETE', 5, 1),
('role', 'menu', 'Role Management', '/system/role', NULL, 2, 1),
('role:list', 'api', 'List Roles', '/api/v1/roles', 'GET', 1, 1),
('role:read', 'api', 'Read Roles', '/api/v1/roles', 'GET', 1, 1),
('role:create', 'api', 'Create Role', '/api/v1/roles', 'POST', 2, 1),
('role:update', 'api', 'Update Role', '/api/v1/roles/:id', 'PUT', 3, 1),
('role:delete', 'api', 'Delete Role', '/api/v1/roles/:id', 'DELETE', 4, 1),
('permission', 'menu', 'Permission Management', '/system/permission', NULL, 3, 1),
('permission:list', 'api', 'List Permissions', '/api/v1/permissions', 'GET', 1, 1),
('permission:read', 'api', 'Read Permission', '/api/v1/permissions/:id', 'GET', 2, 1),
('permission:create', 'api', 'Create Permission', '/api/v1/permissions', 'POST', 3, 1),
('permission:update', 'api', 'Update Permission', '/api/v1/permissions/:id', 'PUT', 4, 1),
('permission:delete', 'api', 'Delete Permission', '/api/v1/permissions/:id', 'DELETE', 5, 1),
('menu', 'button', 'Menu Management', NULL, NULL, 4, 1),
('menu:list', 'api', 'List Menus', '/api/v1/menus', 'GET', 1, 1),
('menu:read', 'api', 'Read Menus', '/api/v1/menus', 'GET', 1, 1),
('rate_limit', 'button', 'Rate Limit Management', NULL, NULL, 5, 1),
('rate_limit:list', 'api', 'List Rate Limits', '/api/v1/rate-limit-rules', 'GET', 1, 1),
('rate_limit:create', 'api', 'Create Rate Limit', '/api/v1/rate-limit-rules', 'POST', 2, 1),
('rate_limit:update', 'api', 'Update Rate Limit', '/api/v1/rate-limit-rules/:id', 'PUT', 3, 1),
('rate_limit:delete', 'api', 'Delete Rate Limit', '/api/v1/rate-limit-rules/:id', 'DELETE', 4, 1)
ON CONFLICT DO NOTHING;

UPDATE permissions
SET parent_id = (SELECT id FROM permissions WHERE code = 'system')
WHERE code IN ('user', 'role', 'permission');

-- Assign admin role to admin user; the menu query grants full visibility to role code admin.
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id FROM users u, roles r
WHERE u.username = 'admin' AND r.code = 'admin'
ON CONFLICT DO NOTHING;

-- Assign all permissions to admin role.
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.code = 'admin'
ON CONFLICT DO NOTHING;

-- Casbin uses the external UUID from the JWT, not the numeric database id.
INSERT INTO casbin_rule (ptype, v0, v1, v2)
SELECT 'g', u.uuid, r.code, ''
FROM users u, roles r
WHERE u.username = 'admin' AND r.code = 'admin'
ON CONFLICT DO NOTHING;

-- Casbin policy rules: admin can execute all permissions.
INSERT INTO casbin_rule (ptype, v0, v1, v2)
SELECT DISTINCT 'p', 'admin', p.code, 'execute'
FROM permissions p
WHERE NOT EXISTS (
    SELECT 1 FROM casbin_rule c
    WHERE c.ptype = 'p' AND c.v0 = 'admin' AND c.v1 = p.code AND c.v2 = 'execute'
);

COMMIT;
