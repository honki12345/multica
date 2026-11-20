-- Test identity inside a restored candidate database (fork-verify.sh).
-- psql -v email=... -v ws_slug=... -v token_hash=... -v token_prefix=...
-- Creates a member-less user and an empty workspace it owns, so nothing a
-- test does touches a restored production workspace. Idempotent by email/slug.
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO "user" (name, email, onboarded_at)
VALUES ('fork-verify', :'email', now())
ON CONFLICT (email) DO UPDATE SET onboarded_at = COALESCE("user".onboarded_at, now());
INSERT INTO workspace (name, slug, description, issue_prefix)
VALUES ('fork-verify', :'ws_slug', 'fork-verify test workspace', 'FV')
ON CONFLICT (slug) DO NOTHING;
INSERT INTO member (workspace_id, user_id, role)
SELECT w.id, u.id, 'owner' FROM workspace w, "user" u
WHERE w.slug = :'ws_slug' AND u.email = :'email'
ON CONFLICT (workspace_id, user_id) DO NOTHING;
INSERT INTO personal_access_token (user_id, name, token_hash, token_prefix)
SELECT u.id, 'fork-verify', :'token_hash', :'token_prefix' FROM "user" u WHERE u.email = :'email';
COMMIT;
SELECT 'user_id=' || u.id, 'workspace_id=' || w.id
FROM "user" u, workspace w WHERE u.email = :'email' AND w.slug = :'ws_slug';
