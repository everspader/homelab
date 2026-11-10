-- Provision databases + roles for the nestapp tenant on the host Postgres 17.
-- Same isolation pattern as tally / tally_dev: one login role per database,
-- owner of its DB, CONNECT revoked from PUBLIC so roles can't peek at each other.
--
-- NOT applied by ArgoCD (host-level). Run once on the box as the postgres OS user,
-- passing passwords from 1Password as psql variables (never commit them):
--
--   sudo -u postgres psql -v ON_ERROR_STOP=1 \
--     -v nestapp_pw="$(op read 'op://.../nestapp/password')" \
--     -v nestapp_dev_pw="$(op read 'op://.../nestapp_dev/password')" \
--     -f /opt/homelab/host/postgres/provision-nestapp.sql
--
-- Resulting connection strings (pods reach the node LAN IP directly, like tally):
--   postgres://nestapp:<pw>@192.168.68.106:5432/nestapp
--   postgres://nestapp_dev:<pw>@192.168.68.106:5432/nestapp_dev

CREATE ROLE nestapp LOGIN PASSWORD :'nestapp_pw';
CREATE ROLE nestapp_dev LOGIN PASSWORD :'nestapp_dev_pw';

CREATE DATABASE nestapp OWNER nestapp;
CREATE DATABASE nestapp_dev OWNER nestapp_dev;

REVOKE CONNECT ON DATABASE nestapp FROM PUBLIC;
REVOKE CONNECT ON DATABASE nestapp_dev FROM PUBLIC;
GRANT CONNECT ON DATABASE nestapp TO nestapp;
GRANT CONNECT ON DATABASE nestapp_dev TO nestapp_dev;
