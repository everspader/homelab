# host/

Host-level config for the homelab box itself — things k3s/the kernel/systemd read at boot, **before** the Kubernetes API server exists. ArgoCD cannot manage these (it's a Kubernetes controller; it has no view outside the cluster).

This directory is in the repo for diff history and rebuild reproducibility, **not** for auto-apply. A push to `main` does NOT propagate. To apply a change, somebody has to `git pull` on the box and reload the relevant daemon.

## Apply contract

- The repo is cloned to `/opt/homelab` on the box (owned by `home:home`). `/opt` is world-traversable, so system services like `postgresql` can read symlinked files via this path; `/home/home/` is mode 0750 and would otherwise block them.
- Files in `host/` are referenced from their canonical system paths via symlink.
- Editing one of these files in the repo + `git pull` on the box + restarting the relevant service is the full apply path.

## Files

| Repo path | Symlinked from | Reload command |
| --- | --- | --- |
| `host/k3s/config.yaml` | `/etc/rancher/k3s/config.yaml` | `sudo systemctl restart k3s` |
| `host/postgres/conf.d/00-homelab.conf` | `/etc/postgresql/17/main/conf.d/00-homelab.conf` | `sudo systemctl reload postgresql@17-main` (or restart for `archive_mode` changes) |
| `host/postgres/pg_hba.conf` | `/etc/postgresql/17/main/pg_hba.conf` | `sudo systemctl reload postgresql@17-main` |
| `host/postgres/systemd/pgbackrest@.service` | `/etc/systemd/system/pgbackrest@.service` | `sudo systemctl daemon-reload` |
| `host/postgres/systemd/pgbackrest@diff.timer` | `/etc/systemd/system/pgbackrest@diff.timer` | `sudo systemctl daemon-reload && sudo systemctl restart pgbackrest@diff.timer` |
| `host/postgres/systemd/pgbackrest@full.timer` | `/etc/systemd/system/pgbackrest@full.timer` | `sudo systemctl daemon-reload && sudo systemctl restart pgbackrest@full.timer` |

### Reference-only (template, not symlinked)

| Repo path | Real path on box | Why off-repo |
| --- | --- | --- |
| `host/postgres/pgbackrest.conf.example` | `/etc/pgbackrest/pgbackrest.conf` | Contains R2 access key + secret. The example is the structure with placeholders; the live file is hand-filled from 1Password. |

## Secrets

Files in `host/` are plaintext-only — never commit secrets here.

- **k3s:** Phase 12 etcd S3 credentials (`etcd-s3-access-key`, `etcd-s3-secret-key`) go in `/etc/rancher/k3s/config.yaml.d/90-secrets.yaml` on the box, **not** the repo. K3s merges every `*.yaml` in `config.yaml.d/` after `config.yaml`. Sealed Secrets can't help — k3s reads its config before the cluster (and the Sealed Secrets controller) exists.
- **Postgres:** the `postgres` superuser password, per-app role passwords, and pgBackRest R2 credentials live in 1Password and on the box at `/etc/pgbackrest/pgbackrest.conf` (mode 0600, owned by `postgres`). Same constraint — Sealed Secrets is k8s-only, host Postgres exists outside the cluster.
