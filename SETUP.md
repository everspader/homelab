# Homelab on GMKtec NucBox G11 (k3s) — first tenant: Rookia

> Hardware: GMKtec NucBox G11 · AMD Ryzen Embedded R2514 (4C/8T) · 16GB DDR4 · 512GB NVMe
> Host: `homelab` (Ubuntu 26.04 LTS Server, minimal install)

Step-by-step plan to stand up a single-node k3s cluster on a GMKtec NucBox G11 as a **general-purpose home server**, with Rookia (`apps/api` + pg-boss worker, currently on Railway) as the first production tenant. Structured so additional home services (Pi-hole, Home Assistant, Vaultwarden, Uptime Kuma, etc.) can be added later by dropping a new directory under `tenants/`. Each phase is small, achievable, and independently testable. Stop after any phase — nothing breaks.

## Status

_Last updated: 2026-05-08._

| Phase | Title | Status |
| ----- | ----- | ------ |
| 0     | Hardware + BIOS                              | ✅ done |
| 1     | Install Ubuntu Server 26.04 LTS              | ✅ done |
| 2     | Base hardening (sudo NOPASSWD, ufw, etc.)    | ✅ done |
| 3     | Install k3s single-node                      | ✅ done |
| 4     | GitOps repo skeleton                         | ✅ done |
| 5     | Sealed Secrets via Helm                      | ✅ done |
| 6     | ArgoCD via Helm + GitHub App OAuth           | ✅ done |
| 7     | Cloudflare Tunnel + Access on argo.spaderlabs.com | ✅ done |
| 8     | amd64 image build in CI (Rookia repo)        | ⏳ next |
| 9     | Seal Rookia `.env` + deploy API              | ⏳ pending |
| 10    | Deploy pg-boss worker                        | ⏳ pending |
| 11    | Cutover from Railway                         | ⏳ pending |
| 12    | etcd backups (local + S3 offsite)            | ⏳ pending |
| 13    | Adding a new tenant (template; not blocking) | – reference |
| 14    | Tailscale for LAN-only services              | partial (host-side only) |

## Followups

Things deliberately deferred — not blocking, but write down before they're forgotten.

- [ ] **pgBackRest restore test routine.** Monthly automated restore of the latest backup into a side cluster on a different port; assert key tables still exist; tear down. systemd timer `pgbackrest@verify.timer` would do it.
- [ ] **Failure alerting on `pgbackrest@full.service`.** systemd `OnFailure=` hook to push a notification (email, Discord, ntfy, etc.) so a silently-failing weekly backup is caught before the cluster needs restoring.
- [ ] **R2 bucket versioning + delete protection** on `tally-backup`. Mitigates accidental or malicious deletion of all backups via a compromised API key.
- [ ] **Add `rookia_homelab` database + role** when Phase 9 starts. Same isolation pattern as `tally`: dedicated role, CONNECT revoked from PUBLIC.
- [ ] **Install Reflector for cluster-wide imagePullSecret** once we hit 4+ tenants pulling from GHCR. Right now each tenant duplicates `ghcr-pull` SealedSecret; Reflector lets one source Secret mirror itself into N namespaces by annotation. Migration is trivial — one platform Application, then drop per-tenant SealedSecrets in favor of an annotation reference.

## Assumptions

- GMKtec NucBox G11, 16GB / 512GB NVMe, in hand
- Wired Ethernet from the G11 to the TP-Link Deco mesh router (LAN IP `192.168.68.106`); wifi (`192.168.68.109`) available as fallback
- Mac on same LAN
- Cloudflare account with the `rookia.com` zone (Rookia tenant) and `spaderlabs.com` zone (personal / homelab infra hostnames, e.g. `argo.spaderlabs.com`)
- GitHub account (SSH public keys imported into the host installer for passwordless login)
- USB stick (≥4GB) for the Ubuntu Server installer

## Out of scope (for now)

HA control plane, multi-node, on-cluster Postgres (Neon stays remote for Rookia). PVs **are** in scope — bundled `local-path-provisioner` writes to NVMe, sufficient for single-node home services.

## Tenancy model

- Cluster is **multi-tenant by namespace**. One namespace per logical app (`rookia`, `pihole`, `homeassistant`, ...).
- Cluster-wide infrastructure (Sealed Secrets, ArgoCD, Cloudflare Tunnel) lives under `platform/` in the GitOps repo and `sealed-secrets` / `argocd` / `cloudflared` namespaces.
- Each tenant gets its own ArgoCD Application, its own SealedSecret, and (where applicable) its own Cloudflare Tunnel public hostname.
- Resource budgets enforced via `ResourceQuota` per namespace so one runaway tenant can't OOM another.

## Build order at a glance

1. **Phase 0–2** — hardware, Ubuntu Server, hardening. Bare host ready.
2. **Phase 3** — k3s installed, `kubectl` works from the Mac.
3. **Phase 4** — GitOps repo skeleton in place.
4. **Phase 5** — Sealed Secrets controller installed via Helm. `kubeseal` can encrypt anything we'll need next (Cloudflare tunnel token, ArgoCD admin password, Rookia `.env`).
5. **Phase 6** — ArgoCD installed via Helm, self-managing via the repo. Initial access via `kubectl port-forward`.
6. **Phase 7** — Cloudflare Tunnel via Helm, token stored as a SealedSecret. First public hostname points at ArgoCD behind Cloudflare Access.
7. **Phase 8+** — build Rookia images, deploy API + worker, cut over from Railway, backups, more tenants.

---

## Phase 0 — Hardware + BIOS (~20 min)

**Goal:** NucBox powered on, BIOS configured for headless server use.

- [X] Unbox. Plug in keyboard, monitor (HDMI), Ethernet, power.
- [X] Power on. Spam `Del` (or `F2` / `F7` depending on BIOS) at boot to enter BIOS/setup.
- [X] In BIOS, set:
  - **Virtualization (SVM Mode):** Enabled — required for any future VMs / nested containers.
  - **Power on after AC loss / Restore on AC Power Loss:** Enabled — server auto-recovers from outages.
  - **Boot order:** Internal NVMe first; USB second (for the installer).
  - **Secure Boot:** Disabled (simplest for Ubuntu Server; can re-enable later with shim).
  - **Wake on LAN:** Optional, useful for remote power-on.
- [X] Save and exit.

**Verify:** Boots to "no OS" / PXE prompt. Ethernet link LED solid.

---

## Phase 1 — Install Ubuntu Server 26.04 LTS (~45 min)

**Goal:** SSH into a freshly installed Ubuntu Server 26.04 LTS, minimal flavour, with GitHub-imported SSH keys.

### 1.1 Build the installer USB

On the Mac:

- [ ] Download Ubuntu Server 26.04 LTS ISO: <https://ubuntu.com/download/server>
- [ ] Flash it to the USB stick. Easiest: [balenaEtcher](https://etcher.balena.io). Or `dd`:

```bash
diskutil list                                # find the USB disk identifier (e.g. /dev/disk4)
diskutil unmountDisk /dev/diskN
sudo dd if=~/Downloads/ubuntu-26.04-live-server-amd64.iso of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

### 1.2 Install Ubuntu

- [ ] Insert the USB into the NucBox, boot. (If it doesn't boot from USB, hit the boot menu key — usually `F7` or `F11`.)
- [ ] Pick **Try or Install Ubuntu Server**.
- [ ] Subiquity walkthrough:
  - **Variant:** Ubuntu Server (full), then pick the **minimal** option when offered. (Avoid the "Ubuntu Server (minimised)" cut-down flavour that drops cloud-init/snapd.)
  - **Network:** plug Ethernet (`eno1`); subiquity picks up DHCP from the Deco. Wifi (`wlp2s0`) is optional fallback.
  - **Proxy:** leave blank.
  - **Storage:** guided → use entire NVMe disk. Target the internal NVMe, not the USB.
  - **Profile:** name `home`, hostname `homelab`, username `home`, strong password (used for console + sudo, never SSH).
  - **Ubuntu Pro:** skip.
  - **SSH:** install OpenSSH server. Choose **"Import SSH identity → from GitHub"** and enter your GitHub username — the installer pulls your public keys directly from `github.com/<user>.keys` and writes them to `~/.ssh/authorized_keys`. No `ssh-copy-id` round-trip needed.
  - **Featured server snaps:** skip.
- [ ] Wait for install to finish, then reboot. **Remove the USB before it reboots** — otherwise it boots back into the installer.

### 1.3 Find the NucBox on the LAN

The Deco assigns DHCP. From the Mac:

```bash
ping homelab.local                   # mDNS (avahi); works on most LANs
arp -a | grep -i homelab             # or grep router DHCP leases for the MAC
```

In the Deco app, pin the lease: **Clients → homelab → Reserve IP** so the address is stable. Current assignments: eth `192.168.68.106`, wifi `192.168.68.109`.

### 1.4 First SSH

Keys were imported from GitHub during install, so the first connection is already passwordless:

```bash
ssh home@homelab.local               # or home@192.168.68.106
```

Convenience aliases in `~/.ssh/config`:

```sshconfig
Host homelab
    HostName 192.168.68.106
    User home
Host homelab-wlan
    HostName 192.168.68.109
    User home
Host homelab-ts
    HostName 100.107.122.69          # Tailscale (Phase 14)
    User home
```

### 1.5 Update the system

On the NucBox:

```bash
sudo apt update
sudo apt -y full-upgrade
sudo reboot
```

**Verify:**

```bash
uname -m              # → x86_64
cat /etc/os-release   # → Ubuntu 26.04 LTS
```

---

## Phase 2 — Base hardening (~30 min)

**Goal:** locked-down host before installing k3s.

### 2.1 Passwordless `sudo` for the `home` user

Single human user on a key-only LAN/Tailscale box — typing the password every `sudo` is friction with no security benefit. Drop a sudoers file in via `visudo`'s safe-edit path so a typo can't lock you out:

```bash
echo 'home ALL=(ALL) NOPASSWD:ALL' \
  | sudo EDITOR='tee' visudo -f /etc/sudoers.d/90-home-nopasswd
sudo chmod 440 /etc/sudoers.d/90-home-nopasswd
sudo visudo -c                          # validates the entire sudoers tree
```

**Verify:**

```bash
sudo -n true && echo OK                 # → OK, no prompt
sudo -n visudo -c                       # → /etc/sudoers: parsed OK
```

The console (TTY) login still prompts for the `home` password — that's `getty`/PAM, not `sudo`, and it's the break-glass path if SSH ever breaks. Leave it.

### 2.2 Verify SSH password auth is disabled

If you imported SSH keys from GitHub during the Ubuntu install (Phase 1.2), cloud-init has already dropped `/etc/ssh/sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication no` + `PermitRootLogin no` + `KbdInteractiveAuthentication no`. Verify, don't redo:

```bash
sudo sshd -T | egrep "^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|pubkeyauthentication) "
```

Expect:

```
passwordauthentication no
permitrootlogin no
kbdinteractiveauthentication no
pubkeyauthentication yes
```

If any of those is still `yes` (e.g. fresh Debian install, or Ubuntu without GitHub-key import), drop an override at `/etc/ssh/sshd_config.d/99-homelab.conf`:

```bash
sudo tee /etc/ssh/sshd_config.d/99-homelab.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
sudo sshd -t                      # validate before reloading
sudo systemctl reload ssh         # reload, not restart — keeps active sessions alive
```

Don't edit `50-cloud-init.conf` directly; it's owned by cloud-init and may be regenerated. Higher-numbered dropins win.

### 2.3 Install firewall, allow LAN-only access to SSH and the k3s API

Order matters: **add allow rules before enabling ufw**, or you'll lock yourself out of the SSH session you're typing in.

```bash
sudo apt install -y ufw

# LAN-only inbound to SSH and the k3s API server
sudo ufw allow from 192.168.0.0/16 to any port 22   proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 6443 proto tcp

# Tailscale interface — let everything in over the tailnet (zero-trust mesh, not the public internet)
sudo ufw allow in on tailscale0

# Sane defaults
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw --force enable
sudo ufw status verbose
```

`ufw enable` warns "may disrupt existing ssh connections" — it doesn't, your current session stays up because conntrack lets established flows through. From a *new* Mac terminal verify `ssh homelab true` still works before closing the existing session.

Expected `ufw status verbose` (meaningful lines):

```
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    192.168.0.0/16
6443/tcp                   ALLOW IN    192.168.0.0/16
Anywhere on tailscale0     ALLOW IN    Anywhere
Anywhere (v6) on tailscale0 ALLOW IN  Anywhere (v6)
```

If you previously added rules without `proto tcp` (e.g. plain `port 22`), they'll appear as separate, broader entries (`22 ALLOW IN ...`). Delete the protoless versions to avoid duplicates:

```bash
sudo ufw delete allow from 192.168.0.0/16 to any port 22
sudo ufw delete allow from 192.168.0.0/16 to any port 6443
```

### 2.4 Enable unattended security upgrades

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 2.5 Install basic tools

```bash
sudo apt install -y htop vim curl git tmux ca-certificates lsb-release apache2-utils
```

(`apache2-utils` ships `htpasswd`, used in Phase 6 to bcrypt the ArgoCD admin password.)

### 2.6 Confirm cgroup v2 + memory controller (Ubuntu 26.04 default; just verify)

```bash
mount | grep cgroup2                       # cgroup2 on /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers      # must list memory cpu io
```

If `memory` is missing (rare on stock Ubuntu 26.04), add it via GRUB:

```bash
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet systemd.unified_cgroup_hierarchy=1"' | sudo tee -a /etc/default/grub
sudo update-grub
sudo reboot
```

**Verify:** SSH key works, password attempt rejected. `cgroup.controllers` lists `memory`.

---

## Phase 3 — Install k3s single-node (~20 min)

**Goal:** working `kubectl get nodes` Ready, both from NucBox and Mac.

### 3.1 Clone the homelab repo on the box

The k3s config file lives in this repo at [`host/k3s/config.yaml`](host/k3s/config.yaml) and gets symlinked into `/etc/rancher/k3s/`. So the box needs to clone the repo before k3s can start. See [`host/README.md`](host/README.md) for the broader contract — this is *source-controlled host config*, not GitOps. Pushes don't auto-apply; somebody runs `git pull && systemctl restart k3s` on the box.

#### 3.1.1 Configure git identity

On the homelab:

```bash
git config --global user.email "everton.spader@gmail.com"
git config --global user.name "Everton Spader"
```

#### 3.1.2 Generate an SSH key for GitHub access

Generate a dedicated ed25519 key on the box (don't reuse your Mac's key — different machines, different keys, easier to revoke):

```bash
ssh-keygen -t ed25519 -C "home@homelab" -f ~/.ssh/id_ed25519_homelab -N ""
cat ~/.ssh/id_ed25519_homelab.pub
```

Two ways to authorize this key on GitHub — pick one:

- **A. Repo-scoped Deploy Key (preferred):** GitHub → `everspader/homelab` → Settings → Deploy keys → Add deploy key. Title: `homelab box (read)`. Paste the public key. **Do not** check "Allow write access". Smallest blast radius if the box is ever compromised; only this one repo is at risk.
- **B. Personal SSH key:** GitHub → Settings → SSH and GPG keys → New SSH key. The key now authenticates the box as your account, with read+write to *every* repo you own. Convenient if the box will need to clone other repos later (e.g. Rookia source for ad-hoc work). If the box is compromised, every repo is exposed — revoke immediately by deleting the key on GitHub.

The current homelab uses option B because the box may pull additional repos later. ArgoCD (Phase 6.7) will use a separate, repo-scoped Deploy Key regardless — never reuse your personal key for in-cluster machinery.

Pre-trust GitHub's host key and verify:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts

ssh -T git@github.com
# Option A: "Hi everspader/homelab! You've successfully authenticated..."
# Option B: "Hi everspader! You've successfully authenticated..."
```

#### 3.1.3 Clone the repo

```bash
sudo git clone git@github.com:everspader/homelab.git /opt/homelab
sudo chown -R home:home /opt/homelab
ls /opt/homelab/host/k3s/config.yaml   # confirms host/ tree pulled in
```

**Why `/opt/homelab` and not `~/homelab`:** `/home/home/` is mode 0750 by default; system services (`postgresql`, etc.) running as their own user can't traverse into it to read the symlinked configs. `/opt` is world-traversable, so any service can follow `/etc/.../foo -> /opt/homelab/host/.../foo`.

### 3.2 Symlink the k3s config

```bash
sudo mkdir -p /etc/rancher/k3s
sudo ln -sf /opt/homelab/host/k3s/config.yaml /etc/rancher/k3s/config.yaml
ls -l /etc/rancher/k3s/config.yaml   # verify the symlink target
sudo cat /etc/rancher/k3s/config.yaml
```

Why each line in `host/k3s/config.yaml`:

- `write-kubeconfig-mode: "0644"` — kubeconfig readable without sudo (so `scp` to the Mac works as `home`).
- `cluster-init: true` — embeds etcd instead of the default SQLite kine. Required for the Phase 12 snapshot mechanism and for adding nodes later.
- `disable: [traefik, servicelb]` — Cloudflare Tunnel handles public ingress; no `LoadBalancer` Services on a single-node box.
- `tls-san:` — extra Subject Alternative Names baked into the API server cert. Without these, `kubectl` from anything other than the node's primary IP fails TLS verification. Adding all addresses you might ever connect from (LAN eth/wifi, Tailscale, mDNS) avoids cert regeneration later.

### 3.3 Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

The install script picks up `/etc/rancher/k3s/config.yaml` automatically — no flags needed. Wait for the node to be Ready:

```bash
sudo k3s kubectl get nodes                       # → STATUS Ready
sudo k3s kubectl get pods -A                     # coredns + metrics-server + local-path-provisioner Running
```

### 3.4 Copy kubeconfig to the Mac

On the Mac:

```bash
scp homelab:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
sed -i '' 's/127.0.0.1/192.168.68.106/' ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
```

Persist `KUBECONFIG` in `~/.zshrc` (or merge into `~/.kube/config` with `KUBECONFIG=~/.kube/config:~/.kube/homelab.yaml kubectl config view --flatten > ~/.kube/merged && mv ~/.kube/merged ~/.kube/config`).

### 3.5 Install `helm` + `kubeseal` on the Mac

```bash
brew install helm kubeseal
```

### 3.6 Confirm the default storage class

```bash
kubectl get sc    # local-path (default)
```

PVCs land on NVMe under `/var/lib/rancher/k3s/storage/`.

**Verify:** Mac `kubectl get pods -A` lists `coredns`, `metrics-server`, `local-path-provisioner` Running.

---

## Phase 4 — `homelab` GitOps repo skeleton (~30 min)

**Goal:** create the repo where every Helm values file, SealedSecret, and Argo Application will live. Subsequent phases commit into this repo before the cluster ever sees them.

### 4.1 Repo layout

Create a new private GitHub repo `homelab`:

```text
bootstrap/                       # one-shot manifests applied by hand
  root-app.yaml                  # the root Argo Application (Phase 6)
platform/                        # cluster-wide infra; each subdir == one Argo Application
  sealed-secrets/
    values.yaml                  # Helm values
    app.yaml                     # Argo Application (Helm source)
  argocd/
    values.yaml                  # Helm values for the argo-cd chart
    app.yaml                     # Argo Application (self-managing)
    admin-password.sealedsecret.yaml
  cloudflared/
    values.yaml                  # Helm values for the cloudflare-tunnel chart
    app.yaml                     # Argo Application (Helm source)
    tunnel-token.sealedsecret.yaml
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

### 4.2 Clone locally

```bash
git clone git@github.com:<you>/homelab.git
cd homelab
```

### 4.3 Add a `.gitignore`

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

## Phase 5 — Sealed Secrets via Helm (~30 min)

**Goal:** Sealed Secrets controller installed via Helm. `kubeseal` on the Mac can encrypt any Secret into a committable `SealedSecret`. Installed **before** ArgoCD and Cloudflare so their sensitive config (ArgoCD admin password, tunnel token) can be declared in git from day one.

### 5.1 Helm values

`platform/sealed-secrets/values.yaml`:

```yaml
fullnameOverride: sealed-secrets-controller   # match kubeseal CLI's default
keyrenewperiod: 720h                          # 30 days; Go duration parser doesn't accept "d"
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }
```

### 5.2 First install (by hand)

Pin to a known-good chart version (check <https://github.com/bitnami-labs/sealed-secrets/releases> for the latest):

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

### 5.3 Fetch the public cert

```bash
kubeseal --fetch-cert > pub-cert.pem
```

Keep `pub-cert.pem` local. It's not secret, but it's gitignored to avoid clutter. Every `kubeseal` invocation in the rest of this plan uses `--cert pub-cert.pem`.

### 5.4 Back up the controller's private key — **do this now**

Without this file, every SealedSecret in `homelab` becomes useless on a fresh cluster.

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.backup.yaml
```

Move this file into 1Password / Bitwarden / encrypted USB. Delete the local copy.

### 5.5 Self-management Application (declared now, applied in Phase 6)

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

Commit and push. ArgoCD will adopt the existing controller in Phase 6.

### 5.6 Smoke test `kubeseal`

Create a throwaway sealed secret to confirm the round-trip works:

```bash
kubectl create secret generic smoke \
  --from-literal=hello=world \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > /tmp/smoke.sealed.yaml

kubectl apply -f /tmp/smoke.sealed.yaml
kubectl get secret smoke -o jsonpath='{.data.hello}' | base64 -d   # → world
kubectl delete sealedsecret smoke
rm /tmp/smoke.sealed.yaml
```

**Verify:** `kubeseal` encrypts, controller decrypts, Secret materialises, cleanup works.

---

## Phase 6 — ArgoCD via Helm + self-management (~1.5 hr)

**Goal:** ArgoCD installed via Helm, with all configuration (admin password, RBAC, resource limits, repo creds) declared in `homelab`. After bootstrap, ArgoCD reads its own `Application` from the repo and updates itself on every push. Initial access is via `kubectl port-forward` — the public hostname behind Cloudflare Access comes in Phase 7.

### 6.1 Generate the admin password as a SealedSecret

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

### 6.2 Helm values

`platform/argocd/values.yaml`:

```yaml
global:
  domain: argo.spaderlabs.com               # used in Phase 7 when tunnel goes up

configs:
  params:
    server.insecure: "true"                # Cloudflare terminates TLS; ArgoCD speaks HTTP internally
  cm:
    url: https://argo.spaderlabs.com
    timeout.reconciliation: 180s
    application.instanceLabelKey: argocd.argoproj.io/instance
  secret:
    createSecret: false                    # we manage argocd-secret ourselves

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
  enabled: false
dex:
  enabled: false
```

### 6.3 First install (by hand)

Apply the namespace and the admin password SealedSecret first:

```bash
kubectl create namespace argocd
kubectl apply -f platform/argocd/admin-password.sealedsecret.yaml
```

Then install ArgoCD. Pin to a known-good chart version (<https://github.com/argoproj/argo-helm/releases>):

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

### 6.4 First login via port-forward

No public hostname yet. From the Mac:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Browse to `http://localhost:8080`, log in as `admin` with the password from 6.1. Stop port-forward once you've confirmed login works.

### 6.5 Bootstrap the root Application (app-of-apps)

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

This Application discovers every `app.yaml` under `platform/*/` and `tenants/*/` and creates an Argo Application for each.

Apply once:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

### 6.6 Self-management Application for ArgoCD

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
      targetRevision: <pinned>              # same version pinned in 6.3
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
    automated: { selfHeal: true, prune: false }
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false
```

Push. Within a couple minutes the root Application picks it up; the `argocd` Application adopts the Helm install. From here on, edit `values.yaml`, push, ArgoCD updates itself.

### 6.7 Repo access (private repos only)

If `homelab` is private, ArgoCD needs a read-only deploy key.

```bash
ssh-keygen -t ed25519 -f ./homelab-deploy-key -N "" -C "argocd@homelab"
```

Add `./homelab-deploy-key.pub` as a Deploy Key on the GitHub repo (read-only).

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

Commit. ArgoCD discovers it and uses the deploy key for subsequent syncs.

### 6.8 Add the namespaces Application

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

Plus a `platform/namespaces/app.yaml` Argo Application pointing at `platform/namespaces/` (raw manifest source).

**Verify:**

- `kubectl -n argocd get application` shows `root`, `argocd`, `sealed-secrets`, `namespaces` — all `Synced` + `Healthy`.
- `kubectl get ns rookia` exists with the ResourceQuota attached.
- Edit `platform/argocd/values.yaml` (e.g. bump `server.resources.limits.memory` from 256Mi to 384Mi), commit, push. Within ~3 minutes ArgoCD rolls itself with no human intervention.
- Port-forward still reaches the UI.

---

## Phase 7 — Cloudflare Tunnel via Helm + expose ArgoCD (~1 hr)

**Goal:** one shared tunnel that any tenant can attach a public hostname to (e.g. `argo.spaderlabs.com`, later `api-homelab.rookia.com`, `vault.spaderlabs.com`, etc.). Deployed via the official Cloudflare Helm chart, with the tunnel token stored as a SealedSecret from Phase 5. First public hostname exposes ArgoCD behind Cloudflare Access.

### 7.1 Create the tunnel in Cloudflare

In Cloudflare → **Zero Trust → Networks → Tunnels → Create tunnel → Cloudflared**:

- Name: `homelab`
- Copy the install token shown after creation. (The token is what `cloudflared` uses to authenticate the connector; hostname routing is configured in the Cloudflare UI.)

> One tunnel per cluster. Each tenant adds public hostnames to **this same tunnel**, not new tunnels.

### 7.2 Encrypt the tunnel token as a SealedSecret

```bash
kubectl create namespace cloudflared
kubectl create secret generic tunnel-token \
  -n cloudflared \
  --from-literal=token=<TOKEN> \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > platform/cloudflared/tunnel-token.sealedsecret.yaml
```

Commit. Raw token never lands in git — only the sealed form.

### 7.3 Helm values

Using the official Cloudflare chart `cloudflare-tunnel-remote` (remotely-managed tunnel; hostnames configured in the CF dashboard).

`platform/cloudflared/values.yaml`:

```yaml
cloudflare:
  tunnel_token_secret:
    name: tunnel-token
    key: token

replicaCount: 2                              # zero-downtime rollouts on a single node

resources:
  requests: { cpu: 25m,  memory: 32Mi }
  limits:   { cpu: 200m, memory: 128Mi }
```

> Chart docs: <https://github.com/cloudflare/helm-charts/tree/main/charts/cloudflare-tunnel-remote>. Pin the chart version in `app.yaml`.

### 7.4 Application manifest

`platform/cloudflared/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflared
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - chart: cloudflare-tunnel-remote
      repoURL: https://cloudflare.github.io/helm-charts
      targetRevision: <pinned>
      helm:
        valueFiles:
          - $values/platform/cloudflared/values.yaml
    - repoURL: https://github.com/<you>/homelab.git
      targetRevision: HEAD
      ref: values
      path: platform/cloudflared            # also sync the SealedSecret from this dir
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudflared
  syncPolicy:
    automated: { selfHeal: true, prune: true }
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
```

> Argo's multi-source support applies the Helm chart **and** the raw `tunnel-token.sealedsecret.yaml` (which has `namespace: cloudflared` set) in the same Application. The SealedSecret is decrypted by the Phase 5 controller before the Helm pods start.

Push. Confirm ArgoCD syncs `cloudflared` Healthy:

```bash
kubectl -n argocd get application cloudflared
kubectl -n cloudflared get pods                  # 2 cloudflared pods Running
```

In the Cloudflare dashboard, the tunnel should show **HEALTHY** with 2 connectors.

### 7.5 First public hostname: ArgoCD behind Cloudflare Access

In the tunnel (Cloudflare dashboard) → **Public Hostname → Add public hostname**:

- **Subdomain:** `argo`
- **Domain:** `spaderlabs.com`
- **Service:** `http://argocd-server.argocd.svc.cluster.local:80`

In Cloudflare → **Zero Trust → Access → Applications**, create a self-hosted application for `argo.spaderlabs.com`:

- Policy: require login from your email address.
- Optional: add a 2FA requirement.

Browse to `https://argo.spaderlabs.com` — Cloudflare Access prompts first, then ArgoCD shows the login screen. Log in as `admin` with the password from 6.1.

### 7.6 LAN-only services

For services that should NOT be public (Pi-hole admin UI, Home Assistant, etc.), do not add a public hostname. Reach them via `kubectl port-forward` or set up Tailscale (optional Phase 14).

**Verify:**

- `kubectl -n cloudflared get pods` — 2 Running, no CrashLoopBackOff.
- Cloudflare tunnel status **HEALTHY**.
- `curl -I https://argo.spaderlabs.com` — 200 OK, TLS valid (CF terminates), Access challenge appears in a browser.
- Editing `platform/cloudflared/values.yaml` (e.g. bump `replicaCount` to 3 and back) rolls through ArgoCD with no manual steps.

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

## Phase 9 — Seal Rookia `.env` + deploy API (~1 hr)

**Goal:** API reachable at `api-homelab.rookia.com`, healthy, hitting Neon. Runs in the `rookia` namespace, inside its ResourceQuota.

### 9.1 Seal the Rookia `.env`

```bash
kubectl create secret generic api-env \
  -n rookia \
  --from-env-file=.env \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > tenants/rookia/manifests/sealed-env.yaml
```

Commit `sealed-env.yaml` only — never the raw `.env`.

### 9.2 Manifests

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

### 9.3 Wire to ArgoCD

Update `tenants/rookia/app.yaml` to point at `tenants/rookia/manifests/`. Push.

### 9.4 Public hostname

In the Cloudflare tunnel, add public hostname:

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
- **LAN-only:** skip the tunnel hostname. Reach via Tailscale (Phase 14) or `kubectl port-forward`.

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

- ArgoCD + Sealed Secrets + Cloudflared each have a chicken-and-egg: bootstrap once by hand, then let them self-manage. Install order matters — Sealed Secrets first (Phase 5), then ArgoCD (Phase 6), then Cloudflared (Phase 7, with its token already sealed).
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
