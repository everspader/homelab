# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps repo for a single-node k3s cluster on a GMKtec NucBox G11 (Ubuntu 26.04 LTS Server, minimal install, amd64). Not application code — only Kubernetes manifests, Helm values, and ArgoCD `Application` resources. ArgoCD running in-cluster is the only thing that applies changes; `kubectl apply` by hand is reserved for the one-time bootstrap flow described in `SETUP.md`.

Domains in use: `rookia.com` (Rookia tenant) and `spaderlabs.com` (personal / homelab infra — e.g. `argo.spaderlabs.com`).

The full step-by-step build plan lives in [SETUP.md](SETUP.md). Treat it as the source of truth — its "Key traps" section at the bottom encodes constraints that are easy to violate accidentally.

## Layout and app-of-apps model

```
bootstrap/          One-shot manifests applied by hand (root-app.yaml)
platform/           Cluster-wide infra. One subdir == one ArgoCD Application.
  sealed-secrets/   Bitnami sealed-secrets controller (Helm). Installed first.
  argocd/           ArgoCD self-managing itself (Helm + SealedSecret admin pw)
  cloudflared/      Shared Cloudflare Tunnel (Helm, SealedSecret tunnel token)
  namespaces/       Namespace + ResourceQuota per tenant
tenants/            One subdir per logical app. Each has app.yaml + manifests/
  rookia/           First tenant: apps/api + pg-boss worker (images on GHCR)
host/               Host-level config NOT managed by ArgoCD — symlinked into the box's filesystem and reloaded manually. See host/README.md.
  k3s/config.yaml   → /etc/rancher/k3s/config.yaml on the homelab box
```

**Per-component layout convention** — each `platform/<component>/` and `tenants/<tenant>/` directory follows the same structure:

```
<component>/
  app.yaml          # ArgoCD Application — managed by root, not by this Application
  values.yaml       # Helm values referenced via $values (only when the component is a Helm release)
  manifests/        # raw manifests applied by this Application; everything in here IS a manifest
    *.yaml          # Namespaces, ResourceQuotas, SealedSecrets, etc.
```

The `manifests/` subdir is what the Application's source path points at, so no `directory.include`/`exclude` filtering is needed. Components with no raw manifests (e.g. `sealed-secrets` is a pure Helm release) can omit it.

**Install order is load-bearing:** Sealed Secrets (Phase 5) → ArgoCD (Phase 6, initially accessed via `kubectl port-forward`) → Cloudflared (Phase 7, with the tunnel token already sealed). Reversing this means committing plaintext secrets or hand-rolling the tunnel. See `SETUP.md` for the full sequence.

The root Application in `bootstrap/root-app.yaml` recursively includes every `platform/*/app.yaml` and `tenants/*/app.yaml`. Adding a new tenant or platform component = creating a directory with an `app.yaml`; the root picks it up on next sync. Do not hand-register Applications.

Each platform component is **self-managing** via Helm: the `app.yaml` points at the upstream chart, `values.yaml` overrides are in the same directory, and the values repo is referenced via `$values/...` using the multi-source pattern. Editing `values.yaml` and pushing is the normal update path — never `helm upgrade` by hand after bootstrap.

## Tenancy rules (enforced, not suggestions)

- One namespace per tenant. Every workload must set `namespace: <tenant>`. Never deploy to `default`.
- Every tenant has a `ResourceQuota` in `platform/namespaces/<tenant>.yaml`. Every Pod spec must declare both `resources.requests` and `resources.limits`, or the quota will reject it.
- Secrets are committed only as `SealedSecret` (generated with `kubeseal --cert pub-cert.pem`). Plain `Secret` / `.env` / `*.env.*` are gitignored — do not commit them even temporarily.
- Public ingress is exclusively via the shared Cloudflare Tunnel in `platform/cloudflared/`. No new tunnels, no NodePorts for public traffic, no Traefik (disabled at install). LAN-only services skip the public hostname; reach them via Tailscale (Phase 14) or `kubectl port-forward`.

## Images

`tenants/rookia` pulls `ghcr.io/<user>/rookia-api:...` built by the Rookia monorepo's GitHub Actions (Phase 8). Only `linux/amd64` — the homelab is x86_64, no multi-arch needed. The worker reuses the API image with a different `command`.

## Common commands

`kubectl` targets the cluster via `~/.kube/homelab.yaml` (set `KUBECONFIG` or merge into `~/.kube/config`). From the Mac:

```bash
# Cluster / ArgoCD status
kubectl get nodes
kubectl -n argocd get application            # all Apps Synced + Healthy?
kubectl -n argocd logs deploy/argocd-repo-server

# Tenant inspection
kubectl -n rookia get pods
kubectl -n rookia describe resourcequota
kubectl -n rookia logs -f deploy/api

# SealedSecret workflow (run from repo root)
kubeseal --fetch-cert > pub-cert.pem          # one-time per machine
kubectl create secret generic api-env -n rookia \
  --from-env-file=.env --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > tenants/rookia/manifests/sealed-env.yaml
```

## Updating secrets

Every committed secret in this repo is a `SealedSecret` referenced by an ArgoCD `Application`. Workflow to change a secret's value:

1. Edit the plaintext source (your gitignored `.env`, or a fresh `kubectl create secret ... --dry-run=client -o yaml` invocation). The plaintext file never leaves your Mac.
2. Pipe it through `kubeseal --cert pub-cert.pem -o yaml > <path>.sealedsecret.yaml`. The `<path>` matches what the owning Application's `directory.include` selects (`*.sealedsecret.yaml` by convention).
3. `git add && git commit && git push`. ArgoCD picks up the change on its next sync (~3 min via polling, near-instant once GitHub webhooks are wired in Phase 7).
4. Sealed Secrets controller decrypts the new manifest and overwrites the underlying `Secret`.
5. **Pods do not auto-restart on Secret change.** Bounce the consumer manually: `kubectl rollout restart deploy/<name> -n <namespace>`. (Same caveat as plain Kubernetes `Secret`s — env is read at pod start.)

`argocd-secret` is a special case: ArgoCD doesn't watch its own admin password Secret, so re-sealing requires `kubectl rollout restart deploy/argocd-server -n argocd` afterward.

If the new SealedSecret name + namespace don't match an existing Secret, the controller creates a new one. The default scope is `(namespace, name)` strict — moving a sealed file to a different namespace breaks decryption. Re-seal under the new identity rather than copying.

No lint/test/build step for this repo itself — validation is "ArgoCD syncs without error." For local sanity-checking manifests before pushing: `kubectl apply --dry-run=client -f <file>` or `kubectl kustomize` when kustomize is in play.

## Commits

Per global rules: never add `Co-Authored-By` trailers. Commits are the deployment mechanism — a push to `main` is what reaches the cluster via ArgoCD. Keep changes small and scoped to one Application when possible so a bad sync is easy to revert with `git revert`.

## Critical traps (from SETUP.md — do not relearn the hard way)

- The Sealed Secrets controller private key must be backed up offline. Without it, every `SealedSecret` in this repo is garbage on a fresh cluster.
- pg-boss workers require `terminationGracePeriodSeconds: 60`. Without it, rolling restarts drop in-flight jobs.
- `local-path-provisioner` PVCs are node-local. Single-node is fine; migrate to Longhorn/NFS before adding nodes.
- MercadoPago retries webhooks for ~24h. Short downtime recoverable, 48h+ is not.
- BIOS "Restore on AC Power Loss" must be on — otherwise a power blip = manual intervention.
