# homelab

GitOps repo for a single-node k3s cluster on a GMKtec NucBox G11 (Ubuntu 26.04 LTS Server, amd64). ArgoCD running in the cluster applies everything under `platform/` and `tenants/`. A push to `main` is a deploy.

- **Setup guide:** [SETUP.md](SETUP.md). Phase-by-phase build of the box, with current status and key traps.
- **Host-level config** (k3s, Postgres, pgBackRest, Hermes): [host/README.md](host/README.md). Not ArgoCD-managed; applied with `git pull` on the box.
- **Working conventions** (tenancy rules, secrets workflow, common commands): [CLAUDE.md](CLAUDE.md).

## What runs where

| Layer | Components |
| --- | --- |
| Host | Ubuntu 26.04, ufw, Tailscale, Postgres 17 + pgBackRest → Cloudflare R2, Hermes agent |
| Cluster platform | Sealed Secrets, ArgoCD (+ Dex GitHub SSO), ArgoCD Image Updater, cloudflared, VictoriaMetrics + VictoriaLogs + Grafana + Vector |
| Tenants | One namespace + `ResourceQuota` per app under `tenants/` |

Public traffic enters only through the shared Cloudflare Tunnel (`argo.spaderlabs.com`, `grafana.spaderlabs.com`, tenant hostnames). There is no ingress controller and no LoadBalancer. Private access is over Tailscale or the LAN.

## Layout

```text
bootstrap/root-app.yaml   app-of-apps; applied once by hand
platform/<component>/     app.yaml (+ values.yaml for Helm) + manifests/
tenants/<tenant>/         app.yaml + manifests/ (kustomization, SealedSecrets, one subdir per service)
host/                     host config, symlinked from /opt/homelab into system paths
```

Adding a platform component or tenant = adding a directory with an `app.yaml`. The root Application picks it up on the next sync.

## Quick checks

```bash
export KUBECONFIG=~/.kube/homelab.yaml     # points at the Tailscale IP; Tailscale must be running on the Mac
kubectl get nodes
kubectl -n argocd get application          # all Synced + Healthy?
ssh homelab                                # Tailscale; homelab-lan for the LAN IP
```

## Secrets

Only `SealedSecret`s are committed, encrypted with `kubeseal --cert pub-cert.pem`. Plaintext `.env` files stay on the Mac (gitignored). The Sealed Secrets controller key is backed up in 1Password; without it the repo cannot be restored onto a new cluster.
