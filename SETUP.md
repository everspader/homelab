# Homelab on GMKtec NucBox G11 (k3s) — first tenant: Rookia

> Hardware: GMKtec NucBox G11 · AMD Ryzen Embedded R2514 (4C/8T) · 16GB DDR4 · 512GB NVMe
> Host: `homelab` (Debian 12 Bookworm)

Step-by-step plan to stand up a single-node k3s cluster on a GMKtec NucBox G11 as a **general-purpose home server**, with Rookia (`apps/api` + pg-boss worker, currently on Railway) as the first production tenant. Structured so additional home services (Pi-hole, Home Assistant, Vaultwarden, Uptime Kuma, etc.) can be added later by dropping a new directory under `tenants/`. Each phase is small, achievable, and independently testable. Stop after any phase — nothing breaks.

## Assumptions

- GMKtec NucBox G11, 16GB / 512GB NVMe, in hand
- Wired Ethernet to the LAN
- Mac on same LAN
- Cloudflare account with the `rookia.com` zone (and optionally a personal zone for non-Rookia hostnames, e.g. `home.<personal-domain>`)
- GitHub account
- USB stick (≥4GB) for Debian installer

## Out of scope (for now)

HA control plane, multi-node, on-cluster Postgres (Neon stays remote for Rookia). PVs **are** in scope — bundled `local-path-provisioner` writes to NVMe, sufficient for single-node home services.

## Tenancy model

- Cluster is **multi-tenant by namespace**. One namespace per logical app (`rookia`, `pihole`, `homeassistant`, ...).
- Cluster-wide infrastructure (Cloudflare Tunnel, ArgoCD, Sealed Secrets) lives under `platform/` in the GitOps repo and `argocd` / `cloudflared` / `sealed-secrets` namespaces.
- Each tenant gets its own ArgoCD Application, its own SealedSecret, and (where applicable) its own Cloudflare Tunnel public hostname.
- Resource budgets enforced via `ResourceQuota` per namespace so one runaway tenant can't OOM another.

---

## Phase 0 — Hardware + BIOS (~20 min)

**Goal:** NucBox powered on, BIOS configured for headless server use.

- [ ] Unbox. Plug in keyboard, monitor (HDMI), Ethernet, power.
- [ ] Power on. Spam `Del` (or `F2` / `F7` depending on BIOS) at boot to enter BIOS/setup.
- [ ] In BIOS, set:
  - **Virtualization (SVM Mode):** Enabled — required for any future VMs / nested containers.
  - **Power on after AC loss / Restore on AC Power Loss:** Enabled — server auto-recovers from outages.
  - **Boot order:** Internal NVMe first; USB second (for the installer).
  - **Secure Boot:** Disabled (simplest for Debian; can re-enable later with shim).
  - **Wake on LAN:** Optional, useful for remote power-on.
- [ ] Save and exit.

**Verify:** Boots to "no OS" / PXE prompt. Ethernet link LED solid.

---

## Phase 1 — Install Debian 12 (~45 min)

**Goal:** SSH into a freshly installed Debian 12 minimal server.

### 1.1 Build the installer USB

On the Mac:

- [ ] Download Debian 12 netinst ISO: https://www.debian.org/download
- [ ] Flash it to the USB stick. Easiest: [balenaEtcher](https://etcher.balena.io). Or `dd`:

```bash
diskutil list                                # find the USB disk identifier (e.g. /dev/disk4)
diskutil unmountDisk /dev/diskN
sudo dd if=~/Downloads/debian-12.x.x-amd64-netinst.iso of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

### 1.2 Install Debian

- [ ] Insert the USB into the NucBox, boot. (If it doesn't boot from USB, hit the boot menu key — usually `F7` or `F11`.)
- [ ] Pick **Install** (text mode is fine; no need for graphical).
- [ ] Walkthrough:
  - **Hostname:** `homelab`
  - **Domain:** leave blank (or `lan` if you have an internal domain)
  - **Root password:** **leave blank** to disable root login (you'll use `sudo` from the user account)
  - **User:** `home` (or whatever — single human user)
  - **Partitioning:** Guided → use entire disk → All files in one partition. Target the NVMe.
  - **Software selection:** **uncheck everything except SSH server and standard system utilities.** No desktop environment.
- [ ] Reboot. Remove USB.

### 1.3 Get (or create) your Mac SSH public key

On the Mac:

```bash
cat ~/.ssh/id_ed25519.pub
```

If it doesn't exist:

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
```

### 1.4 Find the NucBox on the LAN

```bash
ping homelab.local                   # works on most networks via mDNS (avahi)
# Or check your router's DHCP leases.
```

In your router admin, assign a **static DHCP lease** to the NucBox's MAC.

### 1.5 First SSH + key copy

From the Mac (will prompt for password the first time):

```bash
ssh-copy-id home@homelab.local
ssh home@homelab.local                # should now be passwordless
```

Verify passwordless **before moving on** — Phase 3 disables password SSH.

### 1.6 Update the system

On the NucBox:

```bash
sudo apt update
sudo apt -y full-upgrade
sudo reboot
```

**Verify:**

```bash
uname -m              # → x86_64
cat /etc/os-release   # → Debian GNU/Linux 12 (bookworm)
```

---

## Phase 2 — Base hardening (~30 min)

**Goal:** locked-down host before installing k3s.

### 2.1 Disable SSH password auth

Create `/etc/ssh/sshd_config.d/99-homelab.conf`:

```conf
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
```

Restart SSH:

```bash
sudo systemctl restart ssh
```

### 2.2 Install firewall, allow LAN-only access to SSH and the k3s API

```bash
sudo apt install -y ufw
sudo ufw allow from 192.168.0.0/16 to any port 22
sudo ufw allow from 192.168.0.0/16 to any port 6443
sudo ufw --force enable
```

### 2.3 Enable unattended security upgrades

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 2.4 Install basic tools

```bash
sudo apt install -y htop vim curl git tmux ca-certificates lsb-release
```

### 2.5 Confirm cgroup v2 + memory controller (Debian 12 default; just verify)

```bash
mount | grep cgroup2                       # cgroup2 on /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers      # must list memory cpu io
```

If `memory` is missing (rare on stock Debian 12), add it via systemd:

```bash
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet systemd.unified_cgroup_hierarchy=1"' | sudo tee -a /etc/default/grub
sudo update-grub
sudo reboot
```

**Verify:** SSH key works, password attempt rejected. `cgroup.controllers` lists `memory`.

---

## Phase 3 — Install k3s single-node (~20 min)

**Goal:** working `kubectl get nodes` Ready, both from NucBox and Mac.

### 3.1 Install k3s

Traefik is disabled (Cloudflare Tunnel handles ingress). Embedded etcd is enabled (needed for Phase 12 snapshots).

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb \
  --cluster-init \
  --node-name homelab
```

On the NucBox, wait for the node to be Ready:

```bash
sudo k3s kubectl get nodes
```

### 3.2 Copy kubeconfig to the Mac

On the Mac:

```bash
scp home@homelab:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
sed -i '' 's/127.0.0.1/<HOMELAB_LAN_IP>/' ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
```

Persist `KUBECONFIG` in `~/.zshrc` (or merge into `~/.kube/config` with `KUBECONFIG=~/.kube/config:~/.kube/homelab.yaml kubectl config view --flatten > ~/.kube/merged && mv ~/.kube/merged ~/.kube/config`).

### 3.3 Confirm the default storage class

```bash
kubectl get sc    # local-path (default)
```

PVCs land on NVMe under `/var/lib/rancher/k3s/storage/`.

**Verify:** Mac `kubectl get pods -A` lists `coredns`, `metrics-server`, `local-path-provisioner` Running.

---

## Phase 4 — Cloudflare Tunnel ingress (~1 hr)

**Goal:** one shared tunnel that any tenant can attach a public hostname to (e.g. `pi-test.rookia.com`, later `argo.<personal-domain>`, `vault.<personal-domain>`, etc.).

### 4.1 Create the tunnel in Cloudflare

In Cloudflare → **Zero Trust → Networks → Tunnels → Create tunnel**:

- Name: `homelab`
- Copy the install token shown after creation.

> One tunnel per cluster. Each tenant adds public hostnames to **this same tunnel**, not new tunnels.

### 4.2 Deploy `cloudflared` in-cluster

Create the namespace and the token Secret:

```bash
kubectl create namespace cloudflared
kubectl -n cloudflared create secret generic tunnel-token \
  --from-literal=token=<TOKEN>
```

Apply a Deployment running `cloudflare/cloudflared:latest` with:

- args: `tunnel --no-autoupdate run --token $(TUNNEL_TOKEN)`
- env from the Secret
- 2 replicas (zero-downtime rollouts; fine on a single node)

### 4.3 Sanity hello pod

In the `default` namespace for now (will move to per-tenant namespaces from Phase 6 onward):

```bash
kubectl create deployment hello --image=nginxdemos/hello --port=80
kubectl expose deployment hello --port=80
```

In tunnel → **Public hostname**:

- Hostname: `homelab-test.rookia.com` (or any subdomain you control)
- Service: `http://hello.default.svc.cluster.local:80`

### 4.4 LAN-only services

For services that should NOT be public (Pi-hole admin UI, Home Assistant, etc.), do not add a public hostname. Reach them via NodePort, `kubectl port-forward`, or set up Tailscale (optional Phase 14).

**Verify:**

```bash
curl https://homelab-test.rookia.com   # nginx hello page
```

TLS valid (CF terminates).

---

## Phase 5 — `homelab` GitOps repo skeleton (~30 min)

**Goal:** create the repo where every Helm values file, SealedSecret, and Argo Application will live. Subsequent phases commit into this repo before the cluster ever sees them.

### 5.1 Repo layout

Create a new private GitHub repo `homelab`:

```text
bootstrap/                       # one-shot manifests applied by hand
  root-app.yaml                  # the root Argo Application (Phase 7)
platform/                        # cluster-wide infra; each subdir == one Argo Application
  sealed-secrets/
    values.yaml                  # Helm values
    app.yaml                     # Argo Application (Helm source)
  argocd/
    values.yaml                  # Helm values for the argo-cd chart
    app.yaml                     # Argo Application (self-managing)
    admin-password.sealedsecret.yaml
  cloudflared/
    deployment.yaml
    app.yaml
  namespaces/                    # Namespace + ResourceQuota per tenant
    rookia.yaml
tenants/
  rookia/
    app.yaml
    manifests/
      api/
      worker/
      sealed-env.yaml
  <future-tenant>/
    app.yaml
    manifests/
```

### 5.2 Clone locally

```bash
git clone git@github.com:<you>/homelab.git
cd homelab
```

### 5.3 Add a `.gitignore`

```text
# Decrypted secrets — never commit
*.env
.env
.env.*
pub-cert.pem
sealed-secrets-key.backup.yaml
homelab-deploy-key
homelab-deploy-key.pub
```

Commit and push the empty skeleton.

**Verify:** Repo exists, `git pull` from another machine works, `.gitignore` in place.

---

## Phase 6 — Sealed Secrets via Helm (~30 min)

**Goal:** Sealed Secrets controller installed and self-managing via Helm + GitOps. Required before ArgoCD so the ArgoCD admin password can be stored as a SealedSecret.

### 6.1 Helm values

`platform/sealed-secrets/values.yaml`:

```yaml
fullnameOverride: sealed-secrets
keyrenewperiod: 30d
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }
```

### 6.2 First install (by hand)

Pin to a known-good chart version (check https://github.com/bitnami-labs/sealed-secrets/releases for the latest):

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n sealed-secrets --create-namespace \
  --version <pinned> \
  -f platform/sealed-secrets/values.yaml
```

Wait for the controller:

```bash
kubectl -n sealed-secrets rollout status deploy/sealed-secrets
```

### 6.3 Install `kubeseal` CLI on the Mac

```bash
brew install kubeseal
```

Fetch the cluster's public cert (used to encrypt every SealedSecret going forward):

```bash
kubeseal --fetch-cert > pub-cert.pem
```

Keep `pub-cert.pem` local. It's not secret, but it's gitignored to avoid clutter.

### 6.4 Back up the controller's private key — **do this now**

Without this file, every SealedSecret in `homelab` becomes useless on a fresh cluster.

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.backup.yaml
```

Move this file into 1Password / Bitwarden / encrypted USB. Delete the local copy.

### 6.5 Self-management Application (declared now, applied in Phase 7)

`platform/sealed-secrets/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - chart: sealed-secrets
      repoURL: https://bitnami-labs.github.io/sealed-secrets
      targetRevision: <pinned>
      helm:
        valueFiles:
          - $values/platform/sealed-secrets/values.yaml
    - repoURL: https://github.com/<you>/homelab.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: sealed-secrets
  syncPolicy:
    automated: { selfHeal: true, prune: false }
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
```

Commit and push. ArgoCD will adopt the existing controller in Phase 7.

### 6.6 First SealedSecret: Rookia's `.env`

```bash
kubectl create secret generic api-env \
  -n rookia \
  --from-env-file=.env \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > tenants/rookia/manifests/sealed-env.yaml
```

Commit `sealed-env.yaml` only — never the raw `.env`.

**Verify:** Once the `rookia` namespace exists (Phase 7 / 9), this will decrypt cleanly:

```bash
kubectl -n rookia get secret api-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

---

## Phase 7 — ArgoCD via Helm + self-management (~1.5 hr)

**Goal:** ArgoCD installed via Helm, with all configuration (UI hostname, admin password, RBAC, resource limits, repo creds) declared as files in `homelab`. After bootstrap, ArgoCD reads its own `Application` from the repo and updates itself on every push. The only command you'll ever rerun by hand is the one in 7.5 if you wipe the cluster.

### 7.1 Generate the admin password as a SealedSecret

ArgoCD reads its admin password from a Secret named `argocd-secret`, key `admin.password` (bcrypt hash) plus `admin.passwordMtime`.

Generate a strong random password and bcrypt-hash it:

```bash
PASSWORD=$(openssl rand -base64 32)
echo "Save this in your password manager: $PASSWORD"
HASH=$(htpasswd -nbBC 10 "" "$PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
```

(`htpasswd` ships in `apache2-utils` on Linux or comes preinstalled on macOS.)

Save the plaintext `$PASSWORD` in 1Password before continuing — there is no recovery.

Encrypt and commit:

```bash
kubectl create secret generic argocd-secret \
  -n argocd \
  --from-literal=admin.password="$HASH" \
  --from-literal=admin.passwordMtime="$(date +%FT%T%Z)" \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > platform/argocd/admin-password.sealedsecret.yaml
```

### 7.2 Helm values

`platform/argocd/values.yaml`:

```yaml
global:
  domain: argo.<your-domain>

configs:
  params:
    server.insecure: "true"           # Cloudflare terminates TLS; ArgoCD speaks HTTP internally
  cm:
    url: https://argo.<your-domain>
    timeout.reconciliation: 180s
    application.instanceLabelKey: argocd.argoproj.io/instance
  secret:
    createSecret: false               # we manage argocd-secret ourselves (admin-password.sealedsecret.yaml)

controller:
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }

server:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 250m, memory: 256Mi }
  service:
    type: ClusterIP

repoServer:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 250m, memory: 256Mi }

applicationSet:
  enabled: true
  resources:
    requests: { cpu: 25m, memory: 64Mi }
    limits:   { cpu: 100m, memory: 128Mi }

notifications:
  enabled: false                      # add later when wiring Slack / Discord alerts
dex:
  enabled: false                      # add later if you want OIDC SSO
```

### 7.3 First install (by hand)

Apply the namespace and the admin password SealedSecret first:

```bash
kubectl create namespace argocd
kubectl apply -f platform/argocd/admin-password.sealedsecret.yaml
```

Then install ArgoCD. Pin to a known-good chart version (https://github.com/argoproj/argo-helm/releases):

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  -n argocd \
  --version <pinned> \
  -f platform/argocd/values.yaml
```

Wait for rollout:

```bash
kubectl -n argocd rollout status deploy/argocd-server
```

### 7.4 Cloudflare Tunnel hostname + Access policy

In the tunnel from Phase 4, add a public hostname:

- **Hostname:** `argo.<your-domain>`
- **Service:** `http://argocd-server.argocd.svc.cluster.local:80`

In Cloudflare → **Zero Trust → Access → Applications**, create a self-hosted application for `argo.<your-domain>`:

- Policy: require login from your email address.
- Optional: add a 2FA requirement.

Browse to `https://argo.<your-domain>` — Cloudflare prompts you, then ArgoCD shows the login screen. Log in as `admin` with the password from 7.1.

### 7.5 Bootstrap the root Application

`bootstrap/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/homelab.git
    targetRevision: HEAD
    path: .
    directory:
      recurse: true
      include: "{platform/*/app.yaml,tenants/*/app.yaml}"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { selfHeal: true, prune: true }
```

This Application discovers every `app.yaml` under `platform/*/` and `tenants/*/` and creates an Argo Application for each. That's the "app-of-apps" pattern.

Apply once:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

### 7.6 Self-management Application for ArgoCD

`platform/argocd/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - chart: argo-cd
      repoURL: https://argoproj.github.io/argo-helm
      targetRevision: <pinned>     # same version pinned in 7.3
      helm:
        valueFiles:
          - $values/platform/argocd/values.yaml
    - repoURL: https://github.com/<you>/homelab.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { selfHeal: true, prune: false }   # don't auto-prune ArgoCD's own resources
    syncOptions:
      - ServerSideApply=true                      # adopts the helm-installed resources cleanly
      - CreateNamespace=false                     # already created in 7.3
```

Push. Within a couple minutes the root Application picks it up; the new `argocd` Application adopts the running install. From here on, edit `values.yaml`, push, ArgoCD updates itself.

### 7.7 Repo access (private repos only)

If `homelab` is private, ArgoCD needs a read-only deploy key.

```bash
ssh-keygen -t ed25519 -f ./homelab-deploy-key -N "" -C "argocd@homelab"
```

Add `./homelab-deploy-key.pub` as a Deploy Key on the GitHub repo (read-only, no write access).

Encrypt the private key as a SealedSecret in the `argocd` namespace:

```bash
kubectl create secret generic homelab-repo \
  -n argocd \
  --from-file=sshPrivateKey=./homelab-deploy-key \
  --from-literal=type=git \
  --from-literal=url=git@github.com:<you>/homelab.git \
  --dry-run=client -o yaml \
  > /tmp/homelab-repo.secret.yaml
```

Edit `/tmp/homelab-repo.secret.yaml` and add this label so ArgoCD picks it up automatically:

```yaml
metadata:
  labels:
    argocd.argoproj.io/secret-type: repository
```

Then encrypt:

```bash
kubeseal --cert pub-cert.pem -o yaml \
  < /tmp/homelab-repo.secret.yaml \
  > platform/argocd/homelab-repo.sealedsecret.yaml

rm /tmp/homelab-repo.secret.yaml ./homelab-deploy-key
```

Commit `homelab-repo.sealedsecret.yaml`. ArgoCD will discover it and use the deploy key for all subsequent syncs.

### 7.8 Pull in the rest of `platform/`

Drop in the cloudflared and namespaces Argo Applications:

`platform/cloudflared/app.yaml` — points at `platform/cloudflared/` for raw manifests. Move the manual cloudflared Deployment from Phase 4 into `platform/cloudflared/deployment.yaml`. Push.

`platform/namespaces/rookia.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rookia
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rookia-quota
  namespace: rookia
spec:
  hard:
    requests.cpu: "1"
    requests.memory: "2Gi"
    limits.cpu: "2"
    limits.memory: "4Gi"
```

(NucBox has 16GB / 4C-8T headroom — quotas can be more generous than the Pi version.)

Plus a `platform/namespaces/app.yaml` Argo Application pointing at `platform/namespaces/`.

**Verify:**

- `kubectl -n argocd get application` shows `root`, `argocd`, `sealed-secrets`, `cloudflared`, `namespaces` — all `Synced` + `Healthy`.
- `kubectl get ns rookia` exists with the ResourceQuota attached.
- Edit `platform/argocd/values.yaml` (e.g. bump `server.resources.limits.memory` from 256Mi to 384Mi), commit, push. Within ~3 minutes ArgoCD picks up the change and rolls itself with no human intervention.
- Browse `https://argo.<your-domain>` — UI loads behind Cloudflare Access, login works.

---

## Phase 8 — amd64 image build in CI (~1 hr)

**Goal:** pushing to `main` of the Rookia monorepo publishes amd64 images to GHCR. Since the homelab is x86_64, no QEMU cross-compilation needed — native build is fast.

### 8.1 Dockerfiles

- [ ] Add (or audit) `apps/api/Dockerfile`. Multi-stage, base `oven/bun:1-slim`, install production deps, copy built `apps/api`.
- [ ] Same for the worker. Reuse the API image with a different `CMD` if it imports the same `packages/core`.

### 8.2 GitHub Actions workflow

Create `.github/workflows/build-images.yaml`:

```yaml
name: build-images
on:
  push:
    branches: [main]
    paths:
      - "apps/api/**"
      - "apps/worker/**"
      - "packages/core/**"
permissions:
  contents: read
  packages: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: apps/api/Dockerfile
          platforms: linux/amd64
          push: true
          cache-from: type=gha
          cache-to: type=gha,mode=max
          tags: |
            ghcr.io/<user>/rookia-api:${{ github.sha }}
            ghcr.io/<user>/rookia-api:latest
```

### 8.3 Test pull on the homelab

```bash
sudo k3s ctr image pull ghcr.io/<user>/rookia-api:latest
```

For private images, add an `imagePullSecret` in the `rookia` namespace.

**Verify:** GHCR shows new amd64 manifests. `crictl pull` on the homelab succeeds.

---

## Phase 9 — Deploy API to cluster (~1 hr)

**Goal:** API reachable at `api-pi.rookia.com` (or whatever subdomain), healthy, hitting Neon. Runs in the `rookia` namespace, inside its ResourceQuota.

### 9.1 Manifests

In `tenants/rookia/manifests/api/`:

`deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: rookia
spec:
  replicas: 1
  selector:
    matchLabels: { app: api }
  template:
    metadata:
      labels: { app: api }
    spec:
      containers:
        - name: api
          image: ghcr.io/<user>/rookia-api:latest
          ports:
            - containerPort: 3000
          envFrom:
            - secretRef:
                name: api-env
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          livenessProbe:
            httpGet: { path: /health, port: 3000 }
          readinessProbe:
            httpGet: { path: /health, port: 3000 }
```

`service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: rookia
spec:
  selector: { app: api }
  ports:
    - port: 80
      targetPort: 3000
```

Plus the `sealed-env.yaml` from Phase 6.

### 9.2 Wire to ArgoCD

Update `tenants/rookia/app.yaml` to point at `tenants/rookia/manifests/`. Push.

### 9.3 Public hostname

In Cloudflare tunnel, add public hostname:

- **Hostname:** `api-homelab.rookia.com`
- **Service:** `http://api.rookia.svc.cluster.local:80`

**Verify:**

```bash
curl https://api-homelab.rookia.com/health      # 200
kubectl -n rookia logs deploy/api               # successful Neon connection
kubectl -n rookia describe resourcequota        # usage well under cap
```

Mobile app pointed at `api-homelab.rookia.com` round-trips a real auth request.

---

## Phase 10 — Deploy pg-boss worker (~30 min)

**Goal:** worker consuming jobs from Neon, gracefully shutting down on rollouts.

### 10.1 Manifest

In `tenants/rookia/manifests/worker/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: rookia
spec:
  replicas: 1
  selector:
    matchLabels: { app: worker }
  template:
    metadata:
      labels: { app: worker }
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: worker
          image: ghcr.io/<user>/rookia-api:latest
          command: ["bun", "run", "start:worker"]
          envFrom:
            - secretRef:
                name: api-env
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 512Mi }
```

No Service. Total of API + worker resources must stay under the `rookia` ResourceQuota.

### 10.2 Sync

The tenant Application from Phase 9 already covers this directory once `tenants/rookia/manifests/` is recursive. Push.

**Verify:** Enqueue a known job → worker logs show pickup + completion. Rolling restart does not lose the in-flight job:

```bash
kubectl rollout restart deploy/worker -n rookia
```

---

## Phase 11 — Cutover from Railway (~1 hr + 48 hr observation)

**Goal:** production traffic on the homelab, Railway off.

### 11.1 Pre-flight

API + worker green on homelab for 24h, no error spikes, Neon connection counts sane.

### 11.2 Repoint clients

- [ ] Vercel: update `apps/web` env `NEXT_PUBLIC_API_URL` to `https://api.rookia.com`.
- [ ] Mobile app: update via OTA config flag if applicable.

### 11.3 Switch DNS

Switch Cloudflare DNS so `api.rookia.com` points at the tunnel hostname (or rename the tunnel hostname directly to `api.rookia.com`). MercadoPago webhook URL stays the same.

### 11.4 Drain Railway

Scale Railway services to 0 but **leave them** for 48h in case of rollback.

### 11.5 Monitor

```bash
kubectl -n rookia logs -f deploy/api
```

Watch MP webhook deliveries (24h retry window forgives short blips) and error reports.

### 11.6 Clean up after 48h

Delete Railway services. Cancel the Railway plan if it was the only thing running.

**Verify:** Real user registers, pays via MP, gets the confirmation email — full flow on the homelab.

---

## Phase 12 — etcd backups (~30 min)

**Goal:** cluster state recoverable if the NVMe dies.

### 12.1 Enable scheduled snapshots

Assumes `--cluster-init` from Phase 3. Edit `/etc/systemd/system/k3s.service` and append to the `ExecStart` line:

```text
--etcd-snapshot-schedule-cron "0 */6 * * *" \
--etcd-snapshot-retention 12
```

### 12.2 Add S3-compatible offsite

Cloudflare R2 or Backblaze B2. Append to the same `ExecStart`:

```text
--etcd-s3 \
--etcd-s3-endpoint=<r2-endpoint> \
--etcd-s3-bucket=homelab-etcd \
--etcd-s3-access-key=<KEY> \
--etcd-s3-secret-key=<SECRET>
```

Reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

### 12.3 Document the restore

```bash
k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>
```

### 12.4 Test the restore

Test on a spare VM once. Untested backups don't exist.

**Verify:**

```bash
ls /var/lib/rancher/k3s/server/db/snapshots/   # recent snapshots
```

R2 bucket shows uploads.

---

## Phase 13 — Adding a new tenant (template, not blocking)

Whenever you want to host a new home service (Pi-hole, Home Assistant, Vaultwarden, Uptime Kuma, Gitea, Immich, etc.), this is the recipe — no cluster-level changes needed.

### 13.1 Repo skeleton

In `homelab`, create:

```text
tenants/<name>/
  app.yaml                 # Argo Application
  manifests/
    *.yaml                 # Deployment, Service, PVC, etc.
    sealed-env.yaml        # SealedSecret if needed
```

### 13.2 Namespace + quota

Add `platform/namespaces/<name>.yaml` with a Namespace and a ResourceQuota sized to the app.

### 13.3 Workload rules

- Set every workload's `namespace: <name>`.
- Set explicit `resources.requests` and `resources.limits`.

### 13.4 Storage

If the app is **stateful**, add a PersistentVolumeClaim using the default `local-path` StorageClass:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <name>-data
  namespace: <name>
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
```

Data lives on NVMe; lost if the homelab dies and you don't have a backup of `/var/lib/rancher/k3s/storage/`.

### 13.5 Networking

- **Public:** add a Cloudflare Tunnel public hostname pointing at `http://<svc>.<name>.svc.cluster.local:<port>`. Add a Cloudflare Access policy if it should be private-but-remote.
- **LAN-only:** skip the tunnel hostname. Reach via Tailscale (Phase 14) or NodePort.

### 13.6 Sync

Push. ArgoCD picks it up under the root app's recursive scan.

**Verify:** New namespace exists, Argo Application Synced + Healthy, app reachable on its chosen ingress path.

---

## Phase 14 — Tailscale for LAN-only services (~30 min, optional)

**Goal:** reach `kubectl`, ArgoCD, Pi-hole admin UI, Home Assistant, etc. from anywhere without exposing them publicly.

- [ ] Sign up for Tailscale (free for personal use, up to 100 devices).
- [ ] Install the Tailscale Kubernetes operator via Helm or as an Argo Application — pick a hostname like `homelab`. Approve the device in the Tailscale admin UI.
- [ ] Annotate any Service to expose it on the tailnet:

```yaml
metadata:
  annotations:
    tailscale.com/expose: "true"
```

Or use the operator's `Ingress` class.

- [ ] Optional: enable **MagicDNS** so services are reachable as `<svc>.<tailnet>.ts.net`.
- [ ] Optional: enable **subnet routing** to access the rest of the LAN (printers, etc.) through the homelab.

**Verify:** From a phone on cellular with Tailscale on, `https://argo.<tailnet>.ts.net` (or whatever you exposed) loads the ArgoCD UI.

---

## Optional follow-ups (not blocking)

- **Observability:** VictoriaMetrics + Grafana + Loki + Promtail. Single platform deployment, scrapes all tenants.
- **Uptime Kuma** in `platform/uptime-kuma/` monitoring all tenants' public hostnames.
- **Renovate** or **Dependabot** on the `homelab` repo for image tag bumps.
- **Small UPS** (CyberPower CP900AVR or APC BE600) — NucBox idle ~10-15W, load ~30-40W. Half-decent UPS gives 30-60 min runtime, plenty for clean shutdown on power blips.
- **Restic / kopia** backing up `/var/lib/rancher/k3s/storage/` (PVC data) to Cloudflare R2 or Backblaze B2 — etcd snapshots from Phase 12 only cover cluster state, not stateful app data.
- **Second NVMe** (if NucBox has a free M.2 slot) — separate `/var/lib/rancher` from root, easier disk replacement.
- **Candidate tenants** (each is its own future Phase 13 instance): Pi-hole or AdGuard Home (DNS adblock — needs LAN UDP/53), Home Assistant, Vaultwarden, Immich (photos), Jellyfin (media), Gitea or Forgejo, Nextcloud, Linkding (bookmarks).

---

## Key traps (do not skip)

- ArgoCD has a chicken-and-egg: bootstrap once by hand, then let it self-manage.
- pg-boss worker absolutely needs `terminationGracePeriodSeconds: 60` — without it, rolling restarts will drop jobs mid-flight.
- MercadoPago retries webhooks for ~24h. Short homelab downtime is recoverable; 48h+ is not.
- **Always set `resources.requests` AND `limits` on every workload.** Without limits, one tenant with a memory leak takes down the whole node — including Rookia.
- **Always deploy into a tenant namespace, never `default`.** `default` has no quota; mistakes there can starve everything else.
- **Back up the Sealed Secrets controller key offline.** Without it, `homelab` is useless on a fresh cluster — every secret has to be re-encrypted by hand.
- **Pi-hole / AdGuard on the same homelab as DNS = single point of failure for the whole house.** Keep a fallback DNS in your router config.
- **`local-path-provisioner` PVCs are node-local.** Single-node is fine; the moment you add a second node, stateful pods can no longer be rescheduled. Plan a migration to Longhorn (or NFS) before adding nodes.
- **Cloudflare Tunnel is one shared resource.** Don't put public Rookia + a sketchy self-hosted experiment on the same hostname pattern. Use Cloudflare Access for anything not meant to be on the public internet.
- **BIOS "Restore on AC Power Loss" must be enabled.** Otherwise an outage = manual power button press to recover.
- **NucBox fans get loud under sustained load.** Place it somewhere the noise doesn't matter, or undervolt the CPU in BIOS if needed.
