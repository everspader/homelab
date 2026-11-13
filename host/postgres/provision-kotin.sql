-- Provision databases + roles for the kotin tenant (Nest renamed to Kotin) on the
-- host Postgres 17. Same isolation pattern as provision-nestapp.sql: one login role
-- per database, owner of its DB, CONNECT revoked from PUBLIC so roles can't peek at
-- each other. The nestapp / nestapp_dev databases stay until the move is verified.
--
-- NOT applied by ArgoCD (host-level). Run once on the box as the postgres OS user,
-- passing passwords from 1Password as psql variables (never commit them):
--
--   sudo -u postgres psql -v ON_ERROR_STOP=1 \
--     -v kotin_pw="$(op read 'op://.../kotin/password')" \
--     -v kotin_dev_pw="$(op read 'op://.../kotin_dev/password')" \
--     -f /opt/homelab/host/postgres/provision-kotin.sql
--
-- Resulting connection strings (pods reach the node LAN IP directly, like tally):
--   postgres://kotin:<pw>@192.168.68.106:5432/kotin
--   postgres://kotin_dev:<pw>@192.168.68.106:5432/kotin_dev

CREATE ROLE kotin LOGIN PASSWORD :'kotin_pw';
CREATE ROLE kotin_dev LOGIN PASSWORD :'kotin_dev_pw';

CREATE DATABASE kotin OWNER kotin;
CREATE DATABASE kotin_dev OWNER kotin_dev;

REVOKE CONNECT ON DATABASE kotin FROM PUBLIC;
REVOKE CONNECT ON DATABASE kotin_dev FROM PUBLIC;
GRANT CONNECT ON DATABASE kotin TO kotin;
GRANT CONNECT ON DATABASE kotin_dev TO kotin_dev;
