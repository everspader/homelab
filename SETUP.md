# Homelab on GMKtec NucBox G11 (k3s)

> Hardware: GMKtec NucBox G11 · AMD Ryzen Embedded R2514 (4C/8T) · 16GB DDR4 · 512GB NVMe
> Host: `homelab` (Ubuntu 26.04 LTS Server, minimal install)

Step-by-step guide to stand up a single-node k3s cluster on a GMKtec NucBox G11 as a **general-purpose home server**, managed with GitOps (ArgoCD + Sealed Secrets) and exposed publicly through one shared Cloudflare Tunnel. Next to the cluster, the host runs Postgres (with pgBackRest backups to Cloudflare R2), Tailscale, and the Hermes agent.

Each phase is small and independently testable. You can stop after any phase without breaking anything. Phases 0–7 are the bootstrap path and must run in order. Phases 8–14 can run in any order after that.

## Status

_Last verified against the running box: 2026-11-12 (k3s v1.35.4+k3s1, Postgres 17.9, Tailscale 1.104.5)._

| Phase | Title | Status |
| ----- | ----- | ------ |
| 0     | Hardware + BIOS                                        | ✅ done |
| 1     | Install Ubuntu Server 26.04 LTS                        | ✅ done |
| 2     | Base hardening (sudo, sshd, ufw, unattended-upgrades)  | ✅ done |
| 3     | Install k3s single-node                                | ✅ done |
| 4     | GitOps repo skeleton                                   | ✅ done |
| 5     | Sealed Secrets via Helm                                | ✅ done |
| 6     | ArgoCD via Helm + GitHub App repo creds + GitHub SSO   | ✅ done |
| 7     | Cloudflare Tunnel + Access on `argo.spaderlabs.com`    | ✅ done |
| 8     | Tailscale on the host                                  | ✅ done (host only; no k8s operator) |
| 9     | Observability (VictoriaMetrics + VictoriaLogs + Grafana) | ✅ done |
| 10    | ArgoCD Image Updater                                   | ✅ done |
| 11    | Host Postgres 17 + pgBackRest to R2                    | ✅ done |
| 12    | etcd backups                                           | 🟡 partial (local snapshots only; no offsite) |
| 13    | Adding a new tenant                                    | – reference |
| 14    | Hermes agent (host-level)                              | ✅ done |

## Followups

Deferred work. Not blocking, but written down so it is not forgotten.

- [ ] **etcd offsite snapshots (Phase 12.2).** Local snapshots run on the k3s default schedule. Nothing leaves the box yet.
- [ ] **pgBackRest restore test routine.** Monthly automated restore of the latest backup into a side cluster on a different port. Assert that key tables exist, then tear it down. A `pgbackrest@verify.timer` would do it.
- [ ] **R2 bucket versioning + delete protection** on the pgBackRest bucket. Protects against deletion of all backups through a compromised API key.
- [ ] **Reflector for a cluster-wide imagePullSecret.** Each tenant has its own `ghcr-pull` SealedSecret (4 copies today). Reflector mirrors one source Secret into N namespaces by annotation.
- [ ] **PVC backups.** Restic or kopia for `/var/lib/rancher/k3s/storage/` (VMSingle, VictoriaLogs, Grafana). etcd snapshots cover cluster state only, not volume data.
- [ ] **Tailscale Kubernetes operator** (optional). Only needed to expose individual Services on the tailnet. The host-level install already covers `ssh`, `kubectl` and Postgres.

## Assumptions

- GMKtec NucBox G11, 16GB / 512GB NVMe
- Wired Ethernet from the G11 to the TP-Link Deco mesh router (LAN IP `192.168.68.106`); wifi (`192.168.68.109`) available as fallback
- Mac with Homebrew, on the same LAN for the first phases (Tailscale for remote access later)
- Cloudflare account with the `spaderlabs.com` zone (homelab infra hostnames, e.g. `argo.spaderlabs.com`) plus a zone for each tenant that has its own domain
- GitHub account `everspader` (SSH public keys imported into the host installer; owns the `homelab` repo and the tenant images on GHCR)
- 1Password for every plaintext secret (Sealed Secrets backup key, ArgoCD admin password, R2 keys, Postgres role passwords)
- USB stick (≥4GB) for the Ubuntu Server installer

## Out of scope (for now)

HA control plane, multi-node, in-cluster Postgres. Databases run on the **host** Postgres (Phase 11) or on external managed providers. PVs **are** in scope: the bundled `local-path-provisioner` writes to the NVMe, which is enough for single-node services.

## Architecture at a glance

```text
Internet ──► Cloudflare (TLS, Access) ──► cloudflared pods (2x, outbound-only tunnel)
                                              │
                                              ▼
                                   k3s Services (ClusterIP only)
                                              │
     ArgoCD ◄── GitHub (GitHub App creds + webhook) ── this repo
       │
       ├── platform/*   sealed-secrets, argocd, cloudflared, namespaces,
       │                observability, argocd-image-updater
       └── tenants/*    one namespace + quota per tenant

Host (outside k3s): Postgres 17 + pgBackRest ──► R2 · Tailscale · Hermes agent · ufw
```

- Cluster is **multi-tenant by namespace**. One namespace per logical app, each with a `ResourceQuota`.
- Cluster-wide infrastructure lives under `platform/`. Each subdirectory is one ArgoCD Application.
- There is no ingress controller (Traefik disabled) and no LoadBalancer (ServiceLB disabled). All public traffic enters through the shared Cloudflare Tunnel. Private access is over Tailscale or the LAN.

## Build order at a glance

1. **Phase 0–2:** hardware, Ubuntu Server, hardening. Bare host ready.
2. **Phase 3:** k3s installed, `kubectl` works from the Mac.
3. **Phase 4:** GitOps repo skeleton in place.
4. **Phase 5:** Sealed Secrets controller installed with Helm. `kubeseal` can encrypt everything the next phases need.
5. **Phase 6:** ArgoCD installed with Helm, then self-managing from the repo. First access through `kubectl port-forward`.
6. **Phase 7:** Cloudflare Tunnel, token stored as a SealedSecret. First public hostname is ArgoCD behind Cloudflare Access.
7. **Phase 8+:** Tailscale, observability, image updater, host Postgres, backups, tenants.

---

## Phase 0 — Hardware + BIOS (~20 min)

**Goal:** NucBox powered on, BIOS configured for headless server use.

- [X] Unbox. Plug in keyboard, monitor (HDMI), Ethernet, power.
- [X] Power on. Press `Del` (or `F2` / `F7` depending on BIOS) at boot to enter setup.
- [X] In BIOS, set:
  - **Virtualization (SVM Mode):** Enabled. Required for future VMs / nested containers.
  - **Power on after AC loss / Restore on AC Power Loss:** Enabled. The server recovers from outages without a button press.
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

- [X] Download the Ubuntu Server 26.04 LTS ISO: <https://ubuntu.com/download/server>
- [X] Flash it to the USB stick with [balenaEtcher](https://etcher.balena.io), or with `dd`:

```bash
diskutil list                                # find the USB disk identifier (e.g. /dev/disk4)
diskutil unmountDisk /dev/diskN
sudo dd if=~/Downloads/ubuntu-26.04-live-server-amd64.iso of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

### 1.2 Install Ubuntu

- [X] Insert the USB into the NucBox and boot. (If it does not boot from USB, use the boot menu key, usually `F7` or `F11`.)
- [X] Pick **Try or Install Ubuntu Server**.
- [X] Subiquity walkthrough:
  - **Variant:** Ubuntu Server (full), then pick the **minimal** option when offered. (Avoid the "Ubuntu Server (minimised)" flavour that drops cloud-init/snapd.)
  - **Network:** plug Ethernet (`eno1`); subiquity gets DHCP from the Deco. Wifi (`wlp2s0`) is an optional fallback.
  - **Proxy:** leave blank.
  - **Storage:** guided, use the entire NVMe disk. Target the internal NVMe, not the USB.
  - **Profile:** name `home`, hostname `homelab`, username `home`, strong password (used for console + break-glass, never SSH).
  - **Ubuntu Pro:** skip.
  - **SSH:** install OpenSSH server. Choose **"Import SSH identity → from GitHub"** and enter your GitHub username. The installer pulls your public keys from `github.com/<user>.keys` into `~/.ssh/authorized_keys`.
  - **Featured server snaps:** skip.
- [X] Wait for the install to finish, then reboot. **Remove the USB before it reboots**, or it boots back into the installer.

### 1.3 Find the NucBox on the LAN

The Deco assigns DHCP. From the Mac:

```bash
ping homelab.local                   # mDNS (avahi); works on most LANs
arp -a | grep -i homelab             # or check the router DHCP leases for the MAC
```

In the Deco app, pin the lease: **Clients → homelab → Reserve IP**, so the address is stable. Current assignments: eth `192.168.68.106`, wifi `192.168.68.109`.

### 1.4 First SSH

Keys were imported from GitHub during install, so the first connection is passwordless:

```bash
ssh home@192.168.68.106
```

SSH aliases in `~/.ssh/config` on the Mac. `homelab` goes over Tailscale (Phase 8), so it works from anywhere. The `-lan` / `-wlan` aliases are for when Tailscale is down or not set up yet:

```sshconfig
Host homelab
    HostName 100.107.122.69          # Tailscale (Phase 8)
    User home
Host homelab-lan
    HostName 192.168.68.106
    User home
Host homelab-wlan
    HostName 192.168.68.109
    User home
```

Until Phase 8 is done, use `homelab-lan`.

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

Single human user on a key-only LAN/Tailscale box: a password prompt on every `sudo` adds friction with no security benefit. Add a sudoers file through `visudo`'s safe-edit path, so a typo cannot lock you out:

```bash
echo 'home ALL=(ALL) NOPASSWD:ALL' \
  | sudo EDITOR='tee' visudo -f /etc/sudoers.d/90-home-nopasswd
sudo chmod 440 /etc/sudoers.d/90-home-nopasswd
sudo visudo -c                          # validates the entire sudoers tree
```

**Verify:**

```bash
sudo -n true && echo OK                 # → OK, no prompt
```

The console (TTY) login still asks for the `home` password. That is `getty`/PAM, not `sudo`, and it is the break-glass path if SSH breaks. Leave it.

### 2.2 Verify SSH password auth is disabled

When SSH keys are imported from GitHub during the install, cloud-init writes `/etc/ssh/sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication no` + `PermitRootLogin no` + `KbdInteractiveAuthentication no`. Verify:

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

If any of those is `yes`, add an override at `/etc/ssh/sshd_config.d/99-homelab.conf`:

```bash
sudo tee /etc/ssh/sshd_config.d/99-homelab.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
EOF
sudo sshd -t                      # validate before reloading
sudo systemctl reload ssh         # reload, not restart — keeps active sessions alive
```

Do not edit `50-cloud-init.conf` directly; cloud-init owns it and can regenerate it. Higher-numbered drop-ins win.

### 2.3 Firewall: LAN-only SSH and k3s API

Order matters: **add the allow rules before you enable ufw**, or you lock yourself out of the SSH session you are typing in.

```bash
sudo apt install -y ufw

# LAN-only inbound to SSH and the k3s API server
sudo ufw allow from 192.168.0.0/16 to any port 22   proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 6443 proto tcp

# Tailscale interface — allow everything over the tailnet (Phase 8)
sudo ufw allow in on tailscale0

# Defaults
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw --force enable
sudo ufw status verbose
```

`ufw enable` warns "may disrupt existing ssh connections". It does not: conntrack keeps established flows. From a *new* Mac terminal, verify that `ssh homelab-lan true` works before you close the existing session.

Phase 11 adds two more rules for Postgres (`5432/tcp` from the LAN and from the k3s pod CIDR). The full expected rule set on a finished box:

```
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    192.168.0.0/16
6443/tcp                   ALLOW IN    192.168.0.0/16
Anywhere on tailscale0     ALLOW IN    Anywhere
5432/tcp                   ALLOW IN    192.168.0.0/16             # postgres - LAN
5432/tcp                   ALLOW IN    10.42.0.0/16               # postgres - k3s pods
Anywhere (v6) on tailscale0 ALLOW IN    Anywhere (v6)
```

If you added rules without `proto tcp` (e.g. plain `port 22`), they show as separate, broader entries. Delete them:

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
sudo apt install -y htop vim curl git tmux zsh ca-certificates lsb-release apache2-utils
```

(`apache2-utils` ships `htpasswd`, used in Phase 6 to bcrypt the ArgoCD admin password. The `home` user's login shell is `zsh`: `chsh -s /usr/bin/zsh`.)

### 2.6 Confirm cgroup v2 + memory controller (Ubuntu 26.04 default; verify only)

```bash
mount | grep cgroup2                       # cgroup2 on /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers      # must list memory cpu io
```

If `memory` is missing (rare on stock Ubuntu 26.04), add it with GRUB:

```bash
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet systemd.unified_cgroup_hierarchy=1"' | sudo tee -a /etc/default/grub
sudo update-grub
sudo reboot
```

**Verify:** SSH key works, password attempt rejected. `cgroup.controllers` lists `memory`.

---

## Phase 3 — Install k3s single-node (~20 min)

**Goal:** `kubectl get nodes` shows Ready, both on the NucBox and from the Mac.

### 3.1 Clone the homelab repo on the box

The k3s config lives in this repo at [`host/k3s/config.yaml`](host/k3s/config.yaml) and is symlinked into `/etc/rancher/k3s/`. So the box must clone the repo before k3s can start. See [`host/README.md`](host/README.md) for the contract: this is *source-controlled host config*, not GitOps. Pushes do not apply automatically; you run `git pull` and restart the service on the box.

#### 3.1.1 Configure git identity

On the homelab:

```bash
git config --global user.email "<your email>"
git config --global user.name "<your name>"
```

#### 3.1.2 Generate an SSH key for GitHub access

Generate a dedicated ed25519 key on the box. Do not reuse the Mac's key: different machines, different keys, easier to revoke.

```bash
ssh-keygen -t ed25519 -C "home@homelab" -f ~/.ssh/id_ed25519_homelab -N ""
cat ~/.ssh/id_ed25519_homelab.pub
```

Point SSH at it for GitHub (`~/.ssh/config` on the box):

```sshconfig
Host github.com
    IdentityFile ~/.ssh/id_ed25519_homelab
```

Two ways to authorize this key on GitHub. Pick one:

- **A. Repo-scoped Deploy Key:** GitHub → `everspader/homelab` → Settings → Deploy keys → Add deploy key. Leave "Allow write access" off. Smallest blast radius: only this repo is at risk if the box is compromised.
- **B. Personal SSH key:** GitHub → Settings → SSH and GPG keys → New SSH key. The box can then read and write *every* repo you own. Convenient if the box clones other repos. If the box is compromised, revoke the key on GitHub immediately.

The current box uses option B. In-cluster machinery never uses this key: ArgoCD uses a GitHub App (Phase 6.7), and the Hermes agent has its own deploy key (Phase 14).

Trust GitHub's host key and verify:

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

`sudo git clone` runs as root and does not see `home`'s SSH key. If it fails with `Permission denied (publickey)`, clone as `home` into a directory you own first: `sudo install -d -o home -g home /opt/homelab && git clone git@github.com:everspader/homelab.git /opt/homelab`.

**Why `/opt/homelab` and not `~/homelab`:** `/home/home/` is mode 0750. System services (`postgresql`, `hermes`, etc.) run as their own users and cannot traverse into it to read symlinked configs. `/opt` is world-traversable, so any service can follow `/etc/.../foo -> /opt/homelab/host/.../foo`.

### 3.2 Symlink the k3s config

On a fresh box, `/etc/rancher/k3s/config.yaml` does not exist yet. Check first, and never use `ln -sf`: it silently replaces a real file.

```bash
sudo mkdir -p /etc/rancher/k3s
ls -la /etc/rancher/k3s/                  # must NOT already contain config.yaml
sudo ln -s /opt/homelab/host/k3s/config.yaml /etc/rancher/k3s/config.yaml
ls -l /etc/rancher/k3s/config.yaml        # verify the symlink target
```

Why each line in `host/k3s/config.yaml`:

- `write-kubeconfig-mode: "0644"`: kubeconfig readable without sudo (so `scp` to the Mac works as `home`, and the Hermes agent can use it).
- `cluster-init: true`: embedded etcd instead of the default SQLite kine. Required for etcd snapshots (Phase 12) and for adding nodes later.
- `node-name: homelab`: stable node name, independent of the hostname.
- `disable: [traefik, servicelb]`: Cloudflare Tunnel handles public ingress; no `LoadBalancer` Services on a single-node box.
- `tls-san:`: extra Subject Alternative Names in the API server cert. Without them, `kubectl` from any address other than the node's primary IP fails TLS verification. The list covers LAN eth/wifi, Tailscale and mDNS, so the cert never needs regeneration.

### 3.3 Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

The install script reads `/etc/rancher/k3s/config.yaml` automatically; no flags needed. Wait for the node to be Ready:

```bash
sudo k3s kubectl get nodes                       # → STATUS Ready
sudo k3s kubectl get pods -A                     # coredns + metrics-server + local-path-provisioner Running
```

Upgrades: re-run the same install command (optionally with `INSTALL_K3S_VERSION=v1.xx.y+k3s1`). It keeps the config and data.

### 3.4 Copy kubeconfig to the Mac

On the Mac:

```bash
scp homelab-lan:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
sed -i '' 's/127.0.0.1/100.107.122.69/' ~/.kube/homelab.yaml    # Tailscale IP; use 192.168.68.106 until Phase 8 is done
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
```

The kubeconfig points at the Tailscale IP, so `kubectl` works from anywhere **while Tailscale runs on the Mac**. If `kubectl` hangs, check `tailscale status` on the Mac first. On the LAN, `--server https://192.168.68.106:6443` is a quick override.

Persist `KUBECONFIG` in `~/.zshrc`, or merge into `~/.kube/config` with `KUBECONFIG=~/.kube/config:~/.kube/homelab.yaml kubectl config view --flatten > ~/.kube/merged && mv ~/.kube/merged ~/.kube/config`.

### 3.5 Install `helm` + `kubeseal` on the Mac

```bash
brew install kubectl helm kubeseal
```

These tools run on the Mac only. The box itself does not need `helm` or `kubeseal`.

### 3.6 Confirm the default storage class

```bash
kubectl get sc    # local-path (default)
```

PVCs land on the NVMe under `/var/lib/rancher/k3s/storage/`.

**Verify:** `kubectl get pods -A` from the Mac lists `coredns`, `metrics-server`, `local-path-provisioner` Running.

---

## Phase 4 — `homelab` GitOps repo skeleton (~30 min)

**Goal:** the repo where every Helm values file, SealedSecret and ArgoCD Application lives. Later phases commit into this repo before the cluster sees anything.

### 4.1 Repo layout

Private GitHub repo `everspader/homelab`:

```text
bootstrap/
  root-app.yaml                  # the root ArgoCD Application (app-of-apps), applied once by hand
platform/                        # cluster-wide infra; each subdir == one ArgoCD Application
  <component>/
    app.yaml                     # ArgoCD Application (picked up by root)
    values.yaml                  # Helm values, only for Helm-based components
    manifests/                   # raw manifests applied by the Application (SealedSecrets, RBAC, ...)
tenants/                         # one subdir per logical app
  <tenant>/
    app.yaml                     # ArgoCD Application
    manifests/
      kustomization.yaml         # resource list + pinned image tags (rewritten by Image Updater)
      sealed-env.yaml            # SealedSecret: the tenant's env
      sealed-ghcr-pull.yaml      # SealedSecret: GHCR imagePullSecret
      <service>/                 # one subdir per Deployment (api/, worker/, ...)
host/                            # host-level config, symlinked into the box (not ArgoCD)
```

Rules for this layout:

- The Application's source path points at `manifests/`, so everything in that directory is a manifest. No `directory.include`/`exclude` filters are needed.
- `app.yaml` sits *outside* `manifests/`. The root Application owns it, not the component's own Application.
- Components with no raw manifests (e.g. `sealed-secrets`, a pure Helm release) omit `manifests/`.

### 4.2 `.gitignore`

```text
# Decrypted secrets — never commit
*.env
.env
.env.*

# Sealed Secrets material
pub-cert.pem
*.pem
sealed-secrets-key.backup.yaml

# Repo deploy keys
homelab-deploy-key
homelab-deploy-key.pub

# Editor / OS junk
.DS_Store
.idea/
.vscode/
*.swp
```

The plaintext source of each tenant secret lives at `tenants/<tenant>/.env` on the Mac only; the `*.env` rule keeps it out of git.

**Verify:** repo exists, `git pull` from another machine works, `.gitignore` in place.

---

## Phase 5 — Sealed Secrets via Helm (~30 min)

**Goal:** Sealed Secrets controller installed with Helm. `kubeseal` on the Mac encrypts any Secret into a committable `SealedSecret`. Installed **before** ArgoCD and Cloudflare, so their sensitive config (ArgoCD secrets, tunnel token) is in git from day one.

### 5.1 Helm values

[`platform/sealed-secrets/values.yaml`](platform/sealed-secrets/values.yaml):

```yaml
fullnameOverride: sealed-secrets-controller   # match kubeseal CLI's default
keyrenewperiod: 720h                          # 30 days; Go duration parser doesn't accept "d"
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }
```

### 5.2 First install (by hand)

Use the same chart version that [`platform/sealed-secrets/app.yaml`](platform/sealed-secrets/app.yaml) pins (currently `2.18.5`):

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  -n sealed-secrets --create-namespace \
  --version 2.18.5 \
  -f platform/sealed-secrets/values.yaml

kubectl -n sealed-secrets rollout status deploy/sealed-secrets-controller
```

### 5.3 Fetch the public cert

```bash
kubeseal --fetch-cert > pub-cert.pem
```

Keep `pub-cert.pem` local (gitignored). It is not secret. Every `kubeseal` command in this guide uses `--cert pub-cert.pem`.

### 5.4 Back up the controller's private key — **do this now**

Without this key, every SealedSecret in the repo is useless on a fresh cluster.

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key.backup.yaml
```

Move the file into 1Password and delete the local copy. The controller adds a new key every 30 days (`keyrenewperiod`) and keeps the old ones, so **re-export after each rotation**, or at least before any rebuild. To restore on a new cluster: `kubectl apply -f sealed-secrets-key.backup.yaml` *before* installing the controller.

### 5.5 Self-management Application

[`platform/sealed-secrets/app.yaml`](platform/sealed-secrets/app.yaml) is a multi-source Application: the upstream chart plus this repo as `$values`. `prune: false`, `ServerSideApply=true`, `CreateNamespace=true`. Commit and push. ArgoCD adopts the existing Helm release in Phase 6.

### 5.6 Smoke test `kubeseal`

```bash
kubectl create secret generic smoke -n default \
  --from-literal=hello=world \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > /tmp/smoke.sealed.yaml

kubectl apply -f /tmp/smoke.sealed.yaml
kubectl -n default get secret smoke -o jsonpath='{.data.hello}' | base64 -d   # → world
kubectl -n default delete sealedsecret smoke
rm /tmp/smoke.sealed.yaml
```

**Verify:** `kubeseal` encrypts, the controller decrypts, the Secret appears, cleanup works.

---

## Phase 6 — ArgoCD via Helm + self-management (~1.5 hr)

**Goal:** ArgoCD installed with Helm, all of its configuration in git. After bootstrap, ArgoCD reads its own `Application` from the repo and updates itself on every push. Humans log in with GitHub (Dex); ArgoCD reads the repo through a GitHub App. Public access comes in Phase 7; until then use `kubectl port-forward`.

### 6.1 Create the GitHub OAuth App (for SSO through Dex)

GitHub → Settings → Developer settings → **OAuth Apps → New OAuth App**:

- Homepage URL: `https://argo.spaderlabs.com`
- Authorization callback URL: `https://argo.spaderlabs.com/api/dex/callback`

Generate a client secret. Keep the client ID and secret for 6.2.

### 6.2 Seal `argocd-secret`

ArgoCD reads one Secret named `argocd-secret`. The chart does not create it (`configs.secret.createSecret: false`); this repo owns it as [`platform/argocd/manifests/admin-password.sealedsecret.yaml`](platform/argocd/manifests/admin-password.sealedsecret.yaml). It holds:

| Key | Purpose |
| --- | --- |
| `admin.password` / `admin.passwordMtime` | Local `admin` user (bcrypt). Break-glass login if GitHub SSO breaks. |
| `server.secretkey` | Signs ArgoCD session tokens. Random. |
| `dex.github.clientID` / `dex.github.clientSecret` | OAuth App from 6.1, read by `dex.config` as `$dex.github.*`. |
| `webhook.github.secret` | Shared secret for the GitHub push webhook (6.8). |

Generate and seal all of them together. This file is one SealedSecret, so a re-seal must always include every key:

```bash
PASSWORD=$(openssl rand -base64 32)
HASH=$(htpasswd -nbBC 10 "" "$PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Save in 1Password — admin password: $PASSWORD  webhook secret: $WEBHOOK_SECRET"

kubectl create secret generic argocd-secret -n argocd \
  --from-literal=admin.password="$HASH" \
  --from-literal=admin.passwordMtime="$(date -u +%FT%TZ)" \
  --from-literal=server.secretkey="$(openssl rand -base64 32)" \
  --from-literal=dex.github.clientID='<oauth client id>' \
  --from-literal=dex.github.clientSecret='<oauth client secret>' \
  --from-literal=webhook.github.secret="$WEBHOOK_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > platform/argocd/manifests/admin-password.sealedsecret.yaml
```

### 6.3 Helm values

[`platform/argocd/values.yaml`](platform/argocd/values.yaml) sets:

- `global.domain` + `configs.cm.url`: `argo.spaderlabs.com`.
- `configs.params.server.insecure: "true"`: Cloudflare terminates TLS; ArgoCD speaks plain HTTP inside the cluster.
- `configs.cm.dex.config`: one GitHub connector, client ID/secret from `argocd-secret`.
- `configs.rbac`: default-deny (`policy.default: ''`), `scopes: '[email, groups]'`, and `g, <your GitHub-verified email>, role:admin`. The Dex GitHub connector emits no groups without an org filter, so RBAC matches on email.
- `configs.secret.createSecret: false`.
- Requests and limits on every component. `dex.enabled: true`, `notifications.enabled: false`.

### 6.4 First install (by hand)

Apply the namespace and `argocd-secret` first, then install the chart version that [`platform/argocd/app.yaml`](platform/argocd/app.yaml) pins (currently `9.5.12`):

```bash
kubectl create namespace argocd
kubectl apply -f platform/argocd/manifests/admin-password.sealedsecret.yaml

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  -n argocd \
  --version 9.5.12 \
  -f platform/argocd/values.yaml

kubectl -n argocd rollout status deploy/argocd-server
```

### 6.5 First login via port-forward

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Browse to `http://localhost:8080` and log in as `admin` with the password from 6.2. (GitHub SSO needs the public URL, so it works only after Phase 7.)

### 6.6 Repo access: GitHub App

ArgoCD reads the repo over HTTPS with a GitHub App. The same App also lets ArgoCD Image Updater (Phase 10) push tag bumps, so it needs write access.

1. GitHub → Settings → Developer settings → **GitHub Apps → New GitHub App**. Name e.g. `homelab-argocd`. Disable the webhook. Repository permissions: **Contents: Read and write**, Metadata: Read-only.
2. Install the App on `everspader/homelab` only. Note the **App ID** and the **Installation ID** (the number at the end of the installation's settings URL).
3. Generate a private key (`.pem`) and seal it as a `repo-creds` Secret (a credential template that matches every repo URL under the prefix):

```bash
kubectl create secret generic github-app-homelab -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/everspader \
  --from-literal=githubAppID='<app id>' \
  --from-literal=githubAppInstallationID='<installation id>' \
  --from-file=githubAppPrivateKey=./homelab-argocd.private-key.pem \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > platform/argocd/manifests/github-app-creds.sealedsecret.yaml

rm ./homelab-argocd.private-key.pem      # after saving it in 1Password
```

### 6.7 Bootstrap the root Application (app-of-apps)

[`bootstrap/root-app.yaml`](bootstrap/root-app.yaml) recursively includes `{platform/*/app.yaml,tenants/*/app.yaml}` with `selfHeal` + `prune`. Apply it once:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

From here, adding a component or tenant means adding a directory with an `app.yaml`. Never register Applications by hand.

[`platform/argocd/app.yaml`](platform/argocd/app.yaml) then adopts the Helm install. It has three sources: the `argo-cd` chart, this repo as `$values`, and `platform/argocd/manifests/` (the two SealedSecrets). `prune: false` so ArgoCD never prunes itself.

### 6.8 GitHub webhook (near-instant syncs)

Without a webhook, ArgoCD polls every 180s (`timeout.reconciliation`). With one, a push syncs in seconds. GitHub → `everspader/homelab` → Settings → Webhooks → Add:

- Payload URL: `https://argo.spaderlabs.com/api/webhook`
- Content type: `application/json`
- Secret: the `webhook.github.secret` value from 6.2
- Events: just the push event

This needs the public hostname from Phase 7, including the Cloudflare Access bypass for `/api/webhook` (7.5).

### 6.9 The namespaces Application

[`platform/namespaces/app.yaml`](platform/namespaces/app.yaml) applies `platform/namespaces/manifests/*.yaml`: one file per tenant with a `Namespace` + `ResourceQuota`. `prune: true`, so deleting a tenant's file deletes its namespace.

**Verify:**

- `kubectl -n argocd get application` shows `root`, `argocd`, `sealed-secrets`, `namespaces`, all `Synced` + `Healthy`.
- Edit `platform/argocd/values.yaml` (e.g. bump a memory limit), commit, push. ArgoCD rolls itself with no human step.

---

## Phase 7 — Cloudflare Tunnel + expose ArgoCD (~1 hr)

**Goal:** one shared tunnel that every service attaches public hostnames to. The tunnel is *remotely managed*: hostname routing lives in the Cloudflare dashboard, the cluster only runs the connector. The token is a SealedSecret.

### 7.1 Create the tunnel in Cloudflare

Cloudflare → **Zero Trust → Networks → Tunnels → Create tunnel → Cloudflared**:

- Name: `homelab`
- Copy the connector token shown after creation.

> One tunnel per cluster. Every service adds public hostnames to **this same tunnel**, never a new tunnel.

### 7.2 Seal the tunnel token

```bash
kubectl create secret generic tunnel-token \
  -n cloudflared \
  --from-literal=token='<TOKEN>' \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > platform/cloudflared/manifests/tunnel-token.sealedsecret.yaml
```

### 7.3 Connector Deployment

`cloudflared` runs as a plain Deployment, not a Helm chart: [`platform/cloudflared/manifests/deployment.yaml`](platform/cloudflared/manifests/deployment.yaml).

- 2 replicas, so a rolling restart never drops the tunnel.
- Image pinned (`cloudflare/cloudflared:2026.10.5`) and `--no-autoupdate`. Bump the tag in git to upgrade.
- `TUNNEL_TOKEN` from the `tunnel-token` Secret.
- Metrics on `:2000`; liveness/readiness on `/ready`.
- Non-root, read-only root filesystem, all capabilities dropped, requests + limits set.

[`platform/cloudflared/app.yaml`](platform/cloudflared/app.yaml) is a single-source Application on `platform/cloudflared/manifests/` with `CreateNamespace=true`. Push, then:

```bash
kubectl -n argocd get application cloudflared
kubectl -n cloudflared get pods                  # 2 cloudflared pods Running
```

The Cloudflare dashboard shows the tunnel as **HEALTHY** with 2 connectors.

### 7.4 Public hostnames

In the tunnel → **Public Hostname → Add public hostname**. Each entry maps a hostname to an in-cluster Service URL of the form `http://<svc>.<namespace>.svc.cluster.local:<port>`. Infra entries:

| Hostname | Service |
| --- | --- |
| `argo.spaderlabs.com` | `http://argocd-server.argocd.svc.cluster.local:80` |
| `grafana.spaderlabs.com` | `http://observability-grafana.observability.svc.cluster.local:80` (Phase 9) |

Tenant hostnames follow the same pattern (Phase 13). Cloudflare creates the DNS CNAME automatically when the zone is on the same account. The catch-all rule returns `http_status:404`.

To list what the tunnel currently routes, read the last config the connector received:

```bash
kubectl -n cloudflared logs deploy/cloudflared | grep "Updated to new configuration" | tail -1
```

### 7.5 Cloudflare Access in front of ArgoCD

Cloudflare → **Zero Trust → Access → Applications → Add → Self-hosted** for `argo.spaderlabs.com`:

- Policy: **Allow**, include your email address.
- Second policy on the same host, path `/api/webhook`: action **Bypass**, include **Everyone**. GitHub's webhook POSTs cannot pass an Access login. ArgoCD verifies them with the webhook secret instead.

Browse to `https://argo.spaderlabs.com`: Cloudflare Access first, then the ArgoCD login with **Log in via GitHub**.

### 7.6 LAN-only services

Services that should not be public get no tunnel hostname. Reach them over Tailscale (Phase 8) or with `kubectl port-forward`.

**Verify:**

- `kubectl -n cloudflared get pods`: 2 Running, no CrashLoopBackOff.
- `curl -sI https://argo.spaderlabs.com` → `302` to `*.cloudflareaccess.com`.
- `curl -s -o /dev/null -w '%{http_code}' https://argo.spaderlabs.com/api/webhook` → `400` (reaches ArgoCD, not Access).
- GitHub → repo → Webhooks → Recent deliveries show `200`.

---

## Phase 8 — Tailscale on the host (~15 min)

**Goal:** reach `ssh`, `kubectl` and Postgres from anywhere without any public exposure. Tailscale runs on the **host**, not as a Kubernetes operator.

On the box:

```bash
curl -fsSL https://tailscale.com/install.sh | sh     # adds the tailscale apt repo
sudo tailscale up --ssh
tailscale ip -4                                       # → 100.107.122.69
```

- Approve the device in the Tailscale admin console, and **disable key expiry** for `homelab` so it never drops off the tailnet.
- `--ssh` enables Tailscale SSH: connections to port 22 on the Tailscale IP are authenticated by tailnet identity and ACLs instead of `authorized_keys`. SSH on the LAN IP still goes to OpenSSH, which stays the fallback if Tailscale is down. ufw allows everything on `tailscale0` (Phase 2.3).
- The Tailscale IP is already in the k3s `tls-san` list (Phase 3.2) and in the Mac's kubeconfig (Phase 3.4).

On the Mac (and phone), install Tailscale and sign in to the same tailnet.

**Optional, not set up:** the Tailscale Kubernetes operator (exposes single Services on the tailnet with `tailscale.com/expose: "true"`), MagicDNS names, subnet routing for the rest of the LAN.

**Verify:** from a network outside the LAN (phone hotspot) with Tailscale on: `ssh homelab true` and `kubectl get nodes` both work.

---

## Phase 9 — Observability (~2 hr)

**Goal:** metrics + logs in one place, light enough for a 16GB single-node box, with GitHub SSO. Stack:

- **VictoriaMetrics k8s-stack** (chart `victoria-metrics-k8s-stack`): VM operator, VMSingle, vmagent, kube-state-metrics, node-exporter, Grafana. About 5–10× less RAM than kube-prometheus-stack.
- **VictoriaLogs single** (chart `victoria-logs-single`): log database.
- **Vector** as a DaemonSet: tails every pod's stdout/stderr and ships it to VictoriaLogs.
- **Grafana with GitHub OAuth**: login only through GitHub, with a JMESPath role allowlist.

Everything is under `platform/observability/` as **one ArgoCD Application** with four sources: two Helm charts, this repo as `$values`, and `manifests/` (with `directory.recurse: true` for the `dashboards/` subdirectory).

### 9.1 Repo layout

```
platform/observability/
  app.yaml                        # multi-source: 2 charts + $values + manifests (recurse)
  values.yaml                     # victoria-metrics-k8s-stack values
  values-vlogs.yaml               # victoria-logs-single values
  manifests/
    limitrange.yaml               # default container limits (operator sidecars need them)
    vector.yaml                   # Vector DaemonSet + RBAC + ConfigMap
    grafana-github-oauth.sealedsecret.yaml
    *.sealedsecret.yaml           # extra datasource credentials, if any
    dashboards/*.yaml             # dashboards as labeled ConfigMaps
platform/namespaces/manifests/observability.yaml   # Namespace + ResourceQuota
```

### 9.2 GitHub OAuth App for Grafana SSO

1. GitHub → Settings → Developer settings → **OAuth Apps → New OAuth App**.
2. Homepage URL: `https://grafana.spaderlabs.com`. Callback URL: `https://grafana.spaderlabs.com/login/github`.
3. Generate a client secret.

### 9.3 Seal the OAuth credentials

```bash
kubectl create secret generic grafana-github-oauth -n observability \
  --from-literal=GF_AUTH_GITHUB_CLIENT_ID='<paste>' \
  --from-literal=GF_AUTH_GITHUB_CLIENT_SECRET='<paste>' \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > platform/observability/manifests/grafana-github-oauth.sealedsecret.yaml
```

The env-var-shaped keys are intentional: Grafana binds `GF_AUTH_GITHUB_*` env vars to `[auth.github]` with no extra wiring.

### 9.4 Cloudflare hostname

Add `grafana.spaderlabs.com` → `http://observability-grafana.observability.svc.cluster.local:80` to the tunnel (7.4).

**Do not put Cloudflare Access in front of Grafana.** Grafana's GitHub OAuth callback (`/login/github`) must pass through cleanly. Grafana enforces access itself with `role_attribute_path`: only your GitHub login gets `GrafanaAdmin`, everyone else gets `None`.

### 9.5 Sync + verify

The root Application picks up `platform/observability/app.yaml` automatically.

```bash
kubectl -n observability get pods        # all Running

kubectl -n observability logs deploy/observability-grafana -c grafana 2>&1 \
  | grep "inserting datasource"           # → VictoriaMetrics + VictoriaLogs
```

`https://grafana.spaderlabs.com` shows **Sign in with GitHub**. After a few scrape cycles, **Dashboards → Kubernetes / Compute Resources / Cluster** fills in.

### 9.6 Dashboards as code

Each dashboard is a ConfigMap in `manifests/dashboards/` with the Grafana sidecar's dashboard label. Edit the JSON, push, and the sidecar reloads it. Do not edit dashboards in the UI without exporting them back to git: the next sync overwrites UI changes.

### 9.7 Adding Viewers

Edit `platform/observability/values.yaml`:

```yaml
role_attribute_path: >-
  login=='everspader' && 'GrafanaAdmin' ||
  (contains(['alice','bob'], login) && 'Viewer' || 'None')
```

Push. ArgoCD syncs, Grafana redeploys, they sign in with GitHub and get read-only access.

---

## Phase 10 — ArgoCD Image Updater (~30 min)

**Goal:** a new semver tag on GHCR becomes a git commit in this repo, and ArgoCD rolls it out. No manual tag bumps, and git stays the source of truth.

How it works:

1. [`platform/argocd-image-updater/`](platform/argocd-image-updater/) installs chart `argocd-image-updater` **0.14.0** (the annotation-based 0.x line; 1.x replaces annotations with an `ImageUpdater` CRD and would need every tenant rewired).
2. It reads annotations on ArgoCD `Application` CRs directly through the Kubernetes API (`applicationsAPIKind: kubernetes`) and polls GHCR every 5 minutes.
3. When a tag that matches the allow-list is newer, it commits the bump into the tenant's `kustomization.yaml` `images:` block as `argocd-image-updater <argocd-image-updater@spaderlabs.com>`, with a `chore(<app>): bump image tag` message.
4. The commit triggers the webhook; ArgoCD syncs.

Credentials, without duplicate secrets:

- **Git push:** reuses ArgoCD's GitHub App Secret (`argocd/github-app-homelab`, Phase 6.6), which is why the App needs **Contents: Read and write**.
- **Registry:** reads each tenant's own `ghcr-pull` Secret.
- [`manifests/rbac.yaml`](platform/argocd-image-updater/manifests/rbac.yaml) grants the updater ServiceAccount `get` on exactly those Secrets (one Role + RoleBinding per namespace, pinned with `resourceNames`). **Each new tenant that uses the updater needs its own Role + RoleBinding pair here.**

The `argocd-image-updater` namespace and quota come from `platform/namespaces/manifests/argocd-image-updater.yaml`.

Per-Application annotations are in Phase 13.5.

**Verify:**

```bash
kubectl -n argocd-image-updater logs deploy/argocd-image-updater | tail -20
# → "Processing results: applications=N images_considered=M ... errors=0"
git log --author=argocd-image-updater --oneline | head
```

Because the updater pushes to `main`, always `git pull --rebase` before you push changes to this repo.

---

## Phase 11 — Host Postgres 17 + pgBackRest (~1.5 hr)

**Goal:** one Postgres cluster on the host for tenants that want a local database, with continuous WAL archiving, weekly full and daily differential backups to Cloudflare R2. It runs outside k3s on purpose: simpler upgrades and backups, and no database data on a node-local PVC.

Config files are in [`host/postgres/`](host/postgres/) and are symlinked into place. See [`host/README.md`](host/README.md) for the full file map.

### 11.1 Install from the PGDG apt repo

Ubuntu's own archive ships a different major version, so use the PostgreSQL project repo:

```bash
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh     # adds /etc/apt/sources.list.d/pgdg.list
sudo apt install -y postgresql-17 pgbackrest
pg_lsclusters                                                      # → 17 main 5432 online
```

The package creates cluster `17/main` and the `postgresql@17-main` unit.

### 11.2 Link the config

`pg_hba.conf` already exists, so move it aside first (never `ln -sf` over a real file):

```bash
sudo ln -s /opt/homelab/host/postgres/conf.d/00-homelab.conf /etc/postgresql/17/main/conf.d/00-homelab.conf
sudo mv /etc/postgresql/17/main/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf.orig
sudo ln -s /opt/homelab/host/postgres/pg_hba.conf /etc/postgresql/17/main/pg_hba.conf
```

What they set:

- `00-homelab.conf`: `listen_addresses = '*'`, `scram-sha-256`, memory sized for a host shared with k3s, slow-query logging, `archive_mode = on` with `archive_command = 'pgbackrest --stanza=main archive-push %p'`.
- `pg_hba.conf`: peer auth on the local socket, `scram-sha-256` from loopback, Tailscale (`100.64.0.0/10`), LAN (`192.168.0.0/16`) and the k3s pod CIDR (`10.42.0.0/16`). Everything else is rejected.

Hold the restart until pgBackRest is configured (11.4): with `archive_mode = on` and no stanza, WAL archiving fails and WAL files pile up.

### 11.3 Firewall

```bash
sudo ufw allow from 192.168.0.0/16 to any port 5432 proto tcp comment 'postgres - LAN'
sudo ufw allow from 10.42.0.0/16  to any port 5432 proto tcp comment 'postgres - k3s pods'
```

Tailscale access is already covered by the `tailscale0` rule.

### 11.4 pgBackRest to R2

1. Cloudflare → R2 → create a bucket. Create an R2 API token with **Object Read & Write** scoped to that bucket.
2. Install the config from the example and fill the placeholders (bucket, account endpoint, key, secret):

```bash
sudo install -d -o postgres -g postgres -m 0750 /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest
sudo cp /opt/homelab/host/postgres/pgbackrest.conf.example /etc/pgbackrest/pgbackrest.conf
sudoedit /etc/pgbackrest/pgbackrest.conf
sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
sudo chmod 0640 /etc/pgbackrest/pgbackrest.conf
```

3. Restart Postgres to load the config, then create the stanza and check archiving:

```bash
sudo systemctl restart postgresql@17-main
sudo -u postgres pgbackrest --stanza=main stanza-create
sudo -u postgres pgbackrest --stanza=main check        # forces a WAL switch and confirms it reached R2
```

4. Link the systemd units and enable both timers. `pgbackrest@.service` is a template: the instance name is the backup type (`full` or `diff`).

| Timer | Schedule (UTC) | What it stores |
| --- | --- | --- |
| `pgbackrest@full.timer` | Sundays 02:00 | Complete copy of the cluster. 4 kept (`repo1-retention-full=4`). |
| `pgbackrest@diff.timer` | Daily 03:30 | Changes since the last full. 8 kept (`repo1-retention-diff=8`). |

WAL archiving covers the time between backups. The daily diff shortens a restore: pgBackRest replays at most one day of WAL instead of up to a week.

```bash
sudo ln -s /opt/homelab/host/postgres/systemd/pgbackrest@.service    /etc/systemd/system/pgbackrest@.service
sudo ln -s /opt/homelab/host/postgres/systemd/pgbackrest@full.timer  /etc/systemd/system/pgbackrest@full.timer
sudo ln -s /opt/homelab/host/postgres/systemd/pgbackrest@diff.timer  /etc/systemd/system/pgbackrest@diff.timer
sudo systemctl daemon-reload
sudo systemctl enable --now pgbackrest@full.timer pgbackrest@diff.timer
sudo systemctl start pgbackrest@full.service             # first full backup now
```

A diff needs an existing full backup. If none exists, pgBackRest takes a full instead.

5. Failure alerts (needs Hermes from Phase 14 with Telegram configured). `pgbackrest@.service` has `OnFailure=pgbackrest-notify-failure@%n.service`. When a backup run fails, that unit runs [`host/postgres/bin/pgbackrest-notify-failure`](host/postgres/bin/pgbackrest-notify-failure) as the `hermes` user, which sends the unit name, exit status and last log lines to Telegram with `hermes send`. Link the unit and send a test alert:

```bash
sudo ln -s /opt/homelab/host/postgres/systemd/pgbackrest-notify-failure@.service /etc/systemd/system/pgbackrest-notify-failure@.service
sudo systemctl daemon-reload
sudo systemctl start pgbackrest-notify-failure@pgbackrest@diff.service.service   # test: Telegram message arrives
```

The notify unit runs as `hermes`, not root, because `hermes` can write to `/opt/homelab` and could otherwise change the script to run code as root.

6. Backup age check. A failed run alerts through step 5, but a run that never starts does not: if `postgresql@17-main` is down, systemd skips the backup as a dependency failure and `OnFailure=` never fires. `pgbackrest-check-age.timer` covers that. Every day at 09:00 UTC it runs [`host/postgres/bin/pgbackrest-check-age`](host/postgres/bin/pgbackrest-check-age) as `postgres`, which fails when the newest backup is older than 48 hours, the repo is empty, or the repo cannot be read. The failure goes to Telegram through the same notifier. `pgbackrest info` only reads R2, so the check works while Postgres is down.

The script runs as `postgres`, so install a root-owned copy instead of running it from `/opt/homelab` (which `hermes` can write). Re-run the `install` line after every edit to the script.

```bash
sudo install -d -m 0755 /usr/local/libexec
sudo install -m 0755 -o root -g root /opt/homelab/host/postgres/bin/pgbackrest-check-age /usr/local/libexec/pgbackrest-check-age
sudo ln -s /opt/homelab/host/postgres/systemd/pgbackrest-check-age.service /etc/systemd/system/pgbackrest-check-age.service
sudo ln -s /opt/homelab/host/postgres/systemd/pgbackrest-check-age.timer   /etc/systemd/system/pgbackrest-check-age.timer
sudo systemctl daemon-reload
sudo systemctl enable --now pgbackrest-check-age.timer
sudo systemctl start pgbackrest-check-age.service       # should succeed: "ok: latest backup ..."
journalctl -u pgbackrest-check-age.service -n 3 -o cat
```

Restore (into a stopped, empty or stale data directory):

```bash
sudo systemctl stop postgresql@17-main
sudo -u postgres pgbackrest --stanza=main --delta restore     # add --type=time --target="<ts>" for PITR
sudo systemctl start postgresql@17-main
```

### 11.5 Per-tenant databases

One login role per database, owner of that database, with `CONNECT` revoked from `PUBLIC` so tenants cannot see each other. Keep the provisioning SQL in `host/postgres/provision-<tenant>.sql` and run it once with passwords passed as psql variables from 1Password. See [`host/postgres/provision-nestapp.sql`](host/postgres/provision-nestapp.sql) for the template.

Pods connect to the **node LAN IP**: `postgres://<role>:<pw>@192.168.68.106:5432/<db>`. Pod traffic to the node IP is allowed by the `10.42.0.0/16` ufw and `pg_hba.conf` rules. Do not use the Tailscale IP from pods: the pod network does not route to it.

**Verify:**

```bash
sudo -u postgres psql -Atc "select datname from pg_database where not datistemplate"
sudo -u postgres pgbackrest --stanza=main info      # status: ok, full + diff backups listed
systemctl list-timers 'pgbackrest@*'
```

---

## Phase 12 — etcd backups (~30 min)

**Goal:** cluster state recoverable if the NVMe dies.

### 12.1 Local snapshots (in place)

With `cluster-init: true`, k3s takes etcd snapshots on its default schedule: **every 12 hours (00:00 and 12:00 UTC), keeping the last 5**, in `/var/lib/rancher/k3s/server/db/snapshots/`. No config was needed. To change the schedule, add to [`host/k3s/config.yaml`](host/k3s/config.yaml) and restart k3s:

```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 12
```

### 12.2 S3-compatible offsite (pending)

Use Cloudflare R2 (a separate bucket from pgBackRest). The S3 credentials must **not** go in the repo. k3s merges every `*.yaml` in `/etc/rancher/k3s/config.yaml.d/` after `config.yaml`, so put them in a root-only file there:

```bash
sudo install -d -m 0700 /etc/rancher/k3s/config.yaml.d
sudo tee /etc/rancher/k3s/config.yaml.d/90-secrets.yaml >/dev/null <<'EOF'
etcd-s3: true
etcd-s3-endpoint: <account-id>.r2.cloudflarestorage.com
etcd-s3-bucket: homelab-etcd
etcd-s3-region: auto
etcd-s3-access-key: <KEY>
etcd-s3-secret-key: <SECRET>
EOF
sudo chmod 0600 /etc/rancher/k3s/config.yaml.d/90-secrets.yaml
sudo systemctl restart k3s
```

### 12.3 Restore

```bash
sudo systemctl stop k3s
sudo k3s server --cluster-reset --cluster-reset-restore-path=<snapshot-path-or-name>
sudo systemctl start k3s
```

A restore brings back cluster state (including the Sealed Secrets keys stored in etcd). PVC data and host Postgres are separate (Phase 11, Followups).

### 12.4 Test the restore

Test on a spare VM once. An untested backup is not a backup.

**Verify:**

```bash
sudo k3s etcd-snapshot ls        # recent snapshots, local and (once 12.2 is done) s3
```

---

## Phase 13 — Adding a new tenant (reference)

The recipe for any new app. No cluster-level changes are needed beyond the namespace file and, if it uses the image updater, one RBAC entry.

### 13.1 Build images in CI

In the app's own repo, a GitHub Actions workflow builds and pushes to GHCR:

- `platforms: linux/amd64` only. The box is x86_64; no QEMU or multi-arch.
- Tag releases as plain semver `X.Y.Z` (that is what the image updater allow-list matches). Separate images (e.g. api / worker) can have independent versions.
- Workflow permissions: `packages: write`; log in with `GITHUB_TOKEN`.

### 13.2 Namespace + quota

Add `platform/namespaces/manifests/<name>.yaml` with a `Namespace` and a `ResourceQuota` sized for the app. Size `limits` for a rolling-update surge (2× the biggest Deployment) plus a migration Job running at the same time.

### 13.3 Secrets

```bash
# App env (plaintext stays at tenants/<name>/.env on the Mac, gitignored)
kubectl create secret generic <name>-env -n <name> \
  --from-env-file=tenants/<name>/.env --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml > tenants/<name>/manifests/sealed-env.yaml

# GHCR pull secret (a GitHub PAT with read:packages)
kubectl create secret docker-registry ghcr-pull -n <name> \
  --docker-server=ghcr.io --docker-username=everspader --docker-password='<PAT>' \
  --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml > tenants/<name>/manifests/sealed-ghcr-pull.yaml
```

Pods do not restart when a Secret changes. After a re-seal: `kubectl rollout restart deploy/<name> -n <tenant>`.

If the app needs a database on the host Postgres, provision it first (Phase 11.5).

### 13.4 Manifests

```text
tenants/<name>/
  app.yaml
  manifests/
    kustomization.yaml       # namespace, resources, images: (tags live only here)
    sealed-env.yaml
    sealed-ghcr-pull.yaml
    api/
      deployment.yaml
      service.yaml
      migrate-job.yaml       # optional: DB migrations
    worker/
      deployment.yaml        # optional
```

Workload rules:

- `namespace: <name>` on everything; never `default`.
- `resources.requests` **and** `resources.limits` on every container, including Jobs.
- `imagePullSecrets: [{ name: ghcr-pull }]` on every pod spec.
- `revisionHistoryLimit: 3` on Deployments.
- Workers that process jobs: `terminationGracePeriodSeconds: 60` so a rollout does not kill in-flight work.
- Image references in manifests use the bare image name; the tag comes from `kustomization.yaml` `images:`.

Migrations: run them as a Job with `argocd.argoproj.io/hook: Sync`, `hook-delete-policy: BeforeHookCreation` and `sync-wave: "5"`, with the Deployments at `sync-wave: "10"`. A `PreSync` hook also works once the tenant exists, but it fails on the **first** sync because it runs before the SealedSecrets are applied (see Key traps).

Stateful apps: add a PVC on the default `local-path` StorageClass. The data lives on the NVMe and is not backed up yet (Followups).

### 13.5 `app.yaml`

Single source on `tenants/<name>/manifests`, `selfHeal: true`, `ServerSideApply=true`. Opt in to the image updater with annotations:

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: <alias>=ghcr.io/everspader/<image>
    argocd-image-updater.argoproj.io/<alias>.update-strategy: semver
    argocd-image-updater.argoproj.io/<alias>.allow-tags: 'regexp:^\d+\.\d+\.\d+$'
    argocd-image-updater.argoproj.io/<alias>.pull-secret: pullsecret:<name>/ghcr-pull
    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/github-app-homelab
    argocd-image-updater.argoproj.io/git-branch: main
    argocd-image-updater.argoproj.io/write-back-target: kustomization
```

Then add a Role + RoleBinding for `<name>/ghcr-pull` in [`platform/argocd-image-updater/manifests/rbac.yaml`](platform/argocd-image-updater/manifests/rbac.yaml).

### 13.6 Networking

- **Public:** add a tunnel public hostname → `http://<svc>.<name>.svc.cluster.local:<port>` (Phase 7.4). Add a Cloudflare Access policy if it should be private-but-remote; bypass any webhook or OAuth callback paths.
- **Private:** no hostname. Reach it with `kubectl port-forward`, over Tailscale, or from the LAN.

### 13.7 Sync

Push. The root Application picks up `tenants/<name>/app.yaml`.

**Verify:** namespace exists, Application `Synced` + `Healthy`, `kubectl -n <name> describe resourcequota` well under the caps, app reachable on its hostname.

---

## Phase 14 — Hermes agent (host-level)

"Adolf" is a [Hermes agent](https://github.com/NousResearch/hermes-agent) that operates the homelab and acts as a personal assistant over Telegram. It runs on the host as a sandboxed systemd service under a dedicated `hermes` system user, **not** in k3s.

Tracked config is in [`host/hermes/`](host/hermes/): the systemd unit, the `hermes` CLI wrapper and a sudoers fragment. Runtime state (`.env`, `config.yaml`, sessions, skills) lives in `/var/lib/hermes/.hermes/`, outside the repo.

Install outline:

1. Create the `hermes` system user and `/var/lib/hermes` (owned `hermes:hermes`, 0750). Install Hermes into `/var/lib/hermes`.
2. Give it repo write access with an ACL, plus its own GitHub deploy key with write access. It commits as `Adolf <adolf@spaderlabs.com>`. Grant `home` the same ACL in the same step. Without it, the `.git/objects` subdirectories that Adolf creates are owned by `hermes` and not writable by `home`, and `git pull` as `home` fails with `insufficient permission for adding an object to repository database`.

   ```bash
   for u in hermes home; do
     sudo setfacl -R -m u:$u:rwX /opt/homelab                              # existing files and dirs
     sudo find /opt/homelab -type d -exec setfacl -m d:u:$u:rwX {} +       # default ACL for new ones (dirs only)
   done
   ```
3. Link the unit and the wrapper, install the sudoers fragment (copied, not linked), then start it. Exact commands are in [`host/README.md`](host/README.md).

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now hermes
sudo systemctl reload hermes          # after editing /var/lib/hermes/.hermes/config.yaml (SIGUSR1)
```

Capability decisions (cluster-admin through the 0644 kubeconfig, repo write, read-only DB access) and their trade-offs are recorded in [`CLAUDE.md`](CLAUDE.md#hermes-adolf--host-level-agent).

**Verify:** `systemctl is-active hermes` → `active`; the agent answers on Telegram.

---

## Optional follow-ups (not blocking)

- **Uptime Kuma** (or similar) monitoring all public hostnames.
- **Renovate** on the `homelab` repo for Helm chart and `cloudflared` image bumps (Image Updater only covers tenant images).
- **Small UPS** (CyberPower CP900AVR or APC BE600). The NucBox idles at ~10–15W and loads at ~30–40W; a basic UPS gives 30–60 min, enough for a clean shutdown.
- **Second NVMe** (if there is a free M.2 slot): separate `/var/lib/rancher` and `/var/lib/postgresql` from root, for easier disk replacement.
- **Candidate tenants:** Pi-hole or AdGuard Home (needs LAN UDP/53), Home Assistant, Vaultwarden, Immich, Jellyfin, Forgejo, Linkding.

---

## Key traps (do not skip)

- ArgoCD, Sealed Secrets and cloudflared each have a chicken-and-egg problem: bootstrap once by hand, then let them self-manage. Order matters: Sealed Secrets (Phase 5), then ArgoCD (Phase 6), then cloudflared (Phase 7, token already sealed).
- **Back up the Sealed Secrets controller key offline, and re-export after each 30-day key rotation.** Without it, every SealedSecret in the repo is useless on a fresh cluster.
- **Always set `resources.requests` AND `limits` on every container.** Quota'd namespaces reject pods without them, and a pod without limits can take down the whole node.
- **Always deploy into a tenant namespace, never `default`.** `default` has no quota.
- **Do not `ln -sf` host config into place.** It silently replaces real files (e.g. the stock `pg_hba.conf`). Check with `ls -la`, move the original aside, then `ln -s`.
- **`sudo` rejects symlinked sudoers fragments.** Install them as root-owned 0440 copies (see `host/README.md`).
- **Host Postgres with `archive_mode = on` and a broken pgBackRest config fills the disk with WAL.** Run `pgbackrest check` after every change to `pgbackrest.conf` or the R2 token.
- **Pods reach host Postgres on the node LAN IP, not the Tailscale IP.** Both ufw and `pg_hba.conf` must allow `10.42.0.0/16`.
- **The Image Updater pushes to `main`.** Pull with rebase before pushing, or your push is rejected.
- **`kubectl` from the Mac goes over Tailscale.** If it hangs, Tailscale on the Mac is probably stopped.
- **Workers need `terminationGracePeriodSeconds: 60`** (or longer than the longest job), or rolling restarts drop jobs mid-flight.
- **`local-path-provisioner` PVCs are node-local.** Fine on one node. Before adding a node, plan a migration to Longhorn or NFS.
- **Cloudflare Tunnel is one shared resource.** Use Cloudflare Access for anything not meant for the public internet, and bypass only the specific webhook/callback paths that need it.
- **BIOS "Restore on AC Power Loss" must be enabled.** Otherwise an outage needs a manual power-button press.
- **NucBox fans get loud under sustained load.** Place it where noise does not matter, or undervolt in BIOS.
- **Do not use `PreSync` hooks in an Application that owns its own SealedSecrets** for a brand-new tenant. PreSync runs *before* the Sync phase applies the secrets, so on the first sync the hook pod has no `imagePullSecret` and no env Secret. Use a `Sync` hook with sync-waves: secrets at wave 0, migrate Job at wave 5, Deployments at wave 10.
- **Do not split one tenant into several ArgoCD Applications.** Independent rollback is a team-scale feature. Default to one Application per tenant with services as `manifests/<service>/` subdirectories.
- **Stripping Application finalizers + deleting Apps does not always orphan resources cleanly.** During a refactor that swaps Applications, the old App's cascade-delete can race the new App's create and leave the cluster without Secrets/Deployments for a moment. Apply critical Secrets by hand (`kubectl apply -f`) right after the swap, then let ArgoCD adopt them.
- **ArgoCD excludes `EndpointSlice` from sync.** To point a Service at something outside the cluster, use a selector-less Service with a v1 `Endpoints` object.

### Observability-specific traps

- **The VictoriaMetrics chart's `global.cluster.dnsDomain` defaults to `cluster.local.` (trailing dot).** The dot ends up in every generated URL, and **Grafana 13's URL parser silently drops the whole datasource provisioning file**. Override `global.cluster.dnsDomain: cluster.local`.
- **The VM operator's prometheus-converter watches `PodMonitor` / `ServiceMonitor` CRDs by default.** Without prometheus-operator those CRDs do not exist and the operator crashloops with `failed to wait for podmonitor caches to sync`. Set `victoria-metrics-operator.operator.disable_prometheus_converter: true` and use VM-native CRDs.
- **k3s bundles kube-controller-manager / kube-scheduler / etcd into one binary.** Their scrapers find no endpoints, and the generated controller-manager Service name is 64 chars (over the 63-char limit), which blocks the sync. Disable `kubeControllerManager / kubeScheduler / kubeEtcd`; keep `kubeApiServer` and `kubelet`.
- **`ResourceQuota` requires `limits.cpu` and `limits.memory` on every container**, including operator-injected sidecars (`config-init`, `config-reloader`). Pair every quota'd namespace with a `LimitRange` that supplies defaults (see `platform/observability/manifests/limitrange.yaml`).
- **Grafana persistence + `local-path` (RWO) deadlocks rolling updates.** Use `deploymentStrategy.type: Recreate`, or disable persistence if everything is config-as-code.
- **Prefer static `grafana.datasources` over the sidecar path for datasources.** The sidecar has a startup race; the static path mounts the file before Grafana boots.
- **Default `revisionHistoryLimit` is 10.** Set it to 3 on every chart that exposes it and on every raw Deployment / DaemonSet / StatefulSet.
- **ArgoCD Applications with subdirectories need `directory.recurse: true`.** Without it, ArgoCD silently skips the subdirectory (e.g. `manifests/dashboards/`).
- **Do not put Cloudflare Access in front of a service that does its own OAuth callback** (Grafana). Either skip Access for that hostname or add a path-specific bypass.
