# host/

Host-level config for the homelab box itself — things k3s/the kernel/systemd read at boot, **before** the Kubernetes API server exists. ArgoCD cannot manage these (it's a Kubernetes controller; it has no view outside the cluster).

This directory is in the repo for diff history and rebuild reproducibility, **not** for auto-apply. A push to `main` does NOT propagate. To apply a change, somebody has to `git pull` on the box and reload the relevant daemon.

## Apply contract

- The repo is cloned to `/opt/homelab` on the box (owned by `home:home`). `/opt` is world-traversable, so system services like `postgresql` can read symlinked files via this path; `/home/home/` is mode 0750 and would otherwise block them.
- Files in `host/` are referenced from their canonical system paths via symlink.
- Editing one of these files in the repo + `git pull` on the box + restarting the relevant service is the full apply path.
- First-time install: create each symlink with `sudo ln -s <repo path> <system path>`. Never `ln -sf`: if the system path already holds a real file (e.g. the stock `pg_hba.conf`), move it aside first. The step-by-step order is in [SETUP.md](../SETUP.md) (k3s: Phase 3, Postgres: Phase 11, Hermes: Phase 14).

Not tracked here: Tailscale (installed from its apt repo, state in `/var/lib/tailscale`), ufw rules (listed in SETUP.md Phase 2.3), and the `home` user's sudoers/sshd drop-ins (SETUP.md Phase 2).

## Files

| Repo path | Symlinked from | Reload command |
| --- | --- | --- |
| `host/k3s/config.yaml` | `/etc/rancher/k3s/config.yaml` | `sudo systemctl restart k3s` |
| `host/postgres/conf.d/00-homelab.conf` | `/etc/postgresql/17/main/conf.d/00-homelab.conf` | `sudo systemctl reload postgresql@17-main` (or restart for `archive_mode` changes) |
| `host/postgres/pg_hba.conf` | `/etc/postgresql/17/main/pg_hba.conf` | `sudo systemctl reload postgresql@17-main` |
| `host/postgres/systemd/pgbackrest@.service` | `/etc/systemd/system/pgbackrest@.service` | `sudo systemctl daemon-reload` |
| `host/postgres/systemd/pgbackrest@full.timer` | `/etc/systemd/system/pgbackrest@full.timer` | `sudo systemctl daemon-reload && sudo systemctl restart pgbackrest@full.timer` |
| `host/postgres/systemd/pgbackrest@diff.timer` | `/etc/systemd/system/pgbackrest@diff.timer` | `sudo systemctl daemon-reload && sudo systemctl restart pgbackrest@diff.timer` |
| `host/postgres/systemd/pgbackrest-notify-failure@.service` | `/etc/systemd/system/pgbackrest-notify-failure@.service` | `sudo systemctl daemon-reload` |
| `host/postgres/bin/pgbackrest-notify-failure` | (not linked; the unit above runs it from `/opt/homelab`) | (none — edits live after `git pull`) |

`pgbackrest@.service` has `OnFailure=pgbackrest-notify-failure@%n.service`. When a full or diff backup fails, the notify unit runs as the `hermes` user (with `systemd-journal` added for that unit only) and sends the failed run's last log lines to Telegram with `hermes send`. It runs as `hermes`, not root, because `hermes` can write the script in `/opt/homelab`. Test it with `sudo systemctl start pgbackrest-notify-failure@pgbackrest@diff.service.service`.
| `host/hermes/systemd/hermes.service` | `/etc/systemd/system/hermes.service` | `sudo systemctl daemon-reload && sudo systemctl restart hermes` |
| `host/hermes/bin/hermes-cli` | `/usr/local/bin/hermes` | (none — wrapper script; edits live as soon as they land in the repo) |

### Installed (not symlinked) — strict perm requirements

`sudo` rejects symlinks in `/etc/sudoers.d/` unless the target file is root-owned and 0440. Since the repo working tree is owned by `home`, sudoers fragments are **copied** rather than symlinked. After editing in the repo, re-run the install command on the box.

| Repo path | Real path on box | Apply command (re-run after each edit) |
| --- | --- | --- |
| `host/hermes/sudoers.d/50-hermes-cli` | `/etc/sudoers.d/50-hermes-cli` | `sudo install -m 0440 -o root -g root /opt/homelab/host/hermes/sudoers.d/50-hermes-cli /etc/sudoers.d/50-hermes-cli && sudo visudo -cf /etc/sudoers.d/50-hermes-cli` |

The `90-home-nopasswd` fragment for the `home` user is not tracked; SETUP.md Phase 2.1 creates it.

### One-shot provisioning scripts (run by hand, not symlinked)

| Repo path | Purpose |
| --- | --- |
| `host/postgres/provision-<tenant>.sql` | Creates a tenant's databases and dedicated roles on the host Postgres. Passwords passed as psql variables; usage in each file's header. `provision-nestapp.sql` is the template. |

### Reference-only (template, not symlinked)

| Repo path | Real path on box | Why off-repo |
| --- | --- | --- |
| `host/postgres/pgbackrest.conf.example` | `/etc/pgbackrest/pgbackrest.conf` | Contains R2 access key + secret. The example is the structure with placeholders; the live file is hand-filled from 1Password. |

## Secrets

Files in `host/` are plaintext-only — never commit secrets here.

- **k3s:** etcd S3 credentials (`etcd-s3-access-key`, `etcd-s3-secret-key`; SETUP.md Phase 12.2, not set up yet) go in `/etc/rancher/k3s/config.yaml.d/90-secrets.yaml` on the box, **not** the repo. K3s merges every `*.yaml` in `config.yaml.d/` after `config.yaml`. Sealed Secrets can't help — k3s reads its config before the cluster (and the Sealed Secrets controller) exists.
- **Postgres:** the `postgres` superuser password, per-app role passwords, and pgBackRest R2 credentials live in 1Password and on the box at `/etc/pgbackrest/pgbackrest.conf` (mode 0600, owned by `postgres`). Same constraint — Sealed Secrets is k8s-only, host Postgres exists outside the cluster.
