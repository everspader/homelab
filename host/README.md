# host/

Host-level config for the homelab box itself — things k3s/the kernel/systemd read at boot, **before** the Kubernetes API server exists. ArgoCD cannot manage these (it's a Kubernetes controller; it has no view outside the cluster).

This directory is in the repo for diff history and rebuild reproducibility, **not** for auto-apply. A push to `main` does NOT propagate. To apply a change, somebody has to `git pull` on the box and reload the relevant daemon.

## Apply contract

- The repo is cloned to `~/homelab` on the box.
- Files in `host/` are referenced from their canonical system paths via symlink.
- Editing one of these files in the repo + `git pull` on the box + restarting the relevant service is the full apply path.

## Files

| Repo path | Symlinked from | Reload command |
| --- | --- | --- |
| `host/k3s/config.yaml` | `/etc/rancher/k3s/config.yaml` | `sudo systemctl restart k3s` |

## Secrets

`host/k3s/config.yaml` is plaintext-only. Phase 12 will add etcd S3 backup credentials (`etcd-s3-access-key`, `etcd-s3-secret-key`) — those go in `/etc/rancher/k3s/config.yaml.d/90-secrets.yaml` on the box, **not** in this repo. K3s merges every `*.yaml` in `config.yaml.d/` after `config.yaml`, so the split is supported natively. Sealed Secrets cannot be used here because k3s reads its config before the cluster (and therefore the Sealed Secrets controller) exists.
