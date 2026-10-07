-- Seed data for micro-admin workspace
-- Run after migrations and seed-permissions.sql. Operator password: Admin@123.
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
INSERT INTO roles (code, name, status, remark, is_super) VALUES
('super_admin', 'Super Administrator', 1, 'All permissions', true),
('admin', 'Administrator', 1, 'Standard admin', true)
ON CONFLICT (code) DO UPDATE SET is_super=EXCLUDED.is_super;

-- Admin visibility follows is_super, independent of the role code.
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id FROM users u, roles r
WHERE u.username = 'admin' AND r.code = 'admin'
ON CONFLICT DO NOTHING;

-- Super roles do not materialize a concrete permission list.
DELETE FROM role_permissions WHERE role_id IN
    (SELECT id FROM roles WHERE code IN ('admin','super_admin'));

-- Casbin uses the external UUID from the JWT, not the numeric database id.
INSERT INTO casbin_rule (ptype, v0, v1, v2)
SELECT 'g', u.uuid, r.code, ''
FROM users u, roles r
WHERE u.username = 'admin' AND r.code = 'admin'
ON CONFLICT DO NOTHING;

-- Super roles have wildcard policies (including permissions added later).
DELETE FROM casbin_rule WHERE ptype='p' AND v0 IN ('admin','super_admin');
INSERT INTO casbin_rule (ptype,v0,v1,v2) VALUES
('p','admin','*','*'),('p','super_admin','*','*');

-- Restricted sample: user/role/menu/permission reads only, no mutations.
INSERT INTO roles (code,name,status,remark,is_super) VALUES
('operator','Read-only Operator',1,'Restricted RBAC example',false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO users (uuid,username,password_hash,nickname,status)
SELECT '00000000-0000-7000-8000-000000000002','operator',password_hash,'Operator',1
FROM users WHERE username='admin' ON CONFLICT (username) DO NOTHING;
INSERT INTO user_roles (user_id,role_id)
SELECT u.id,r.id FROM users u,roles r WHERE u.username='operator' AND r.code='operator'
ON CONFLICT DO NOTHING;
INSERT INTO role_permissions (role_id,permission_id)
SELECT r.id,p.id FROM roles r,permissions p WHERE r.code='operator'
AND p.code IN ('dashboard:view','system:view','system:user','system:role','system:permission',
'user:read','role:read','permission:read','menu:read') ON CONFLICT DO NOTHING;
INSERT INTO casbin_rule (ptype,v0,v1,v2)
SELECT 'g',u.uuid,'operator','' FROM users u WHERE u.username='operator'
AND NOT EXISTS (SELECT 1 FROM casbin_rule WHERE ptype='g' AND v0=u.uuid AND v1='operator');
INSERT INTO casbin_rule (ptype,v0,v1,v2)
SELECT DISTINCT 'p','operator',p.code,'execute' FROM permissions p
WHERE p.code IN ('user:read','role:read','permission:read','menu:read')
AND NOT EXISTS (SELECT 1 FROM casbin_rule WHERE ptype='p' AND v0='operator' AND v1=p.code AND v2='execute');
-- Dedicated machine account: no usable password; the BFF checks AGENT_TOKEN.
INSERT INTO users(uuid,username,password_hash,nickname,status) VALUES
('00000000-0000-7000-8000-000000000003','agent_worker','!disabled','Agent Worker',1)
ON CONFLICT(username) DO NOTHING;
INSERT INTO roles(code,name,status,is_super) VALUES ('agent_worker','Agent Worker',1,false)
ON CONFLICT(code) DO NOTHING;
INSERT INTO permissions(code,name,type,path,method,status) VALUES
('agent:stream','Agent stream','api','/api/v1/agent/stream','GET',1),
('agent:publish','Publish agent event','api','/internal/v1/agent-events','POST',1)
ON CONFLICT(code,type) DO NOTHING;
INSERT INTO user_roles(user_id,role_id) SELECT u.id,r.id FROM users u,roles r
WHERE u.username='agent_worker' AND r.code='agent_worker' ON CONFLICT DO NOTHING;
INSERT INTO role_permissions(role_id,permission_id) SELECT r.id,p.id FROM roles r,permissions p
WHERE r.code='agent_worker' AND p.code IN ('agent:stream','agent:publish') ON CONFLICT DO NOTHING;
INSERT INTO casbin_rule(ptype,v0,v1,v2) SELECT 'g',u.uuid,'agent_worker','' FROM users u
WHERE u.username='agent_worker' AND NOT EXISTS (SELECT 1 FROM casbin_rule WHERE ptype='g' AND v0=u.uuid AND v1='agent_worker');
INSERT INTO casbin_rule(ptype,v0,v1,v2) SELECT 'p','agent_worker',p.code,'execute' FROM permissions p
WHERE p.code IN ('agent:stream','agent:publish') AND NOT EXISTS (SELECT 1 FROM casbin_rule WHERE ptype='p' AND v0='agent_worker' AND v1=p.code);
COMMIT;
