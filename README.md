# Clusterforgers K3s Infrastructure

K3s for container orchestration, Tailscale for secure mesh networking, ArgoCD for GitOps deployments. Supports multiple servers defined in a single JSON file.

This repo provides reusable NixOS/home-manager modules. The actual deployable server configs live in [`Clusterforgers/servers`](https://github.com/Clusterforgers/servers), which imports the modules from here. Application manifests deployed via ArgoCD live in [`Clusterforgers/k3s-cluster-manifests`](https://github.com/Clusterforgers/k3s-cluster-manifests).

## Architecture

| File | Purpose |
|------|---------|
| `modules/cluster-vars.json` | Single source of truth for all servers (IPs, SSH aliases, roles) |
| `modules/ssh.nix` | Generates SSH client config entries for every server in the list (routed over Tailscale) |
| `modules/client.nix` | CLI tools + scripts for developer machines (`kubectl`, `k9s`, `fetch-kubeconfig`, `bootstrap-node`) |
| `modules/server.nix` | K3s control plane config + Tailscale hardening, apply to the server with `"role": "control-plane"` |
| `modules/agent.nix` | K3s worker node config + Tailscale hardening, joins the control plane via Tailscale |
| `modules/deployments.nix` | Core cluster infrastructure (Prometheus, ArgoCD) bootstrapped onto the control plane |

## Network & SSH model

Every node running `kubernetes-server` or `kubernetes-agent` gets Tailscale enabled with `tailscale0` marked as a trusted firewall interface. There's no separate OpenSSH — **Tailscale SSH** (`tailscale up --ssh`, run once per node — see bootstrap steps below) handles all SSH, both interactive logins and the automated `nixos-rebuild --target-host`/`--build-host` build path. Access is gated by your tailnet's ACLs (the `ssh` grant), not key management — make sure your tailnet ACL policy actually grants `ssh` to the users/hosts that need it, that part's on the Tailscale admin console, not NixOS.

Tailscale SSH has a known open bug where it can corrupt Nix's remote-store handshake (`nix-store --serve` protocol mismatch) when ssh connection-multiplexing kicks in — see [tailscale/tailscale#14093](https://github.com/tailscale/tailscale/issues/14093). It's intermittent (Tailscale's own engineer couldn't reproduce it in clean testing) and has a confirmed workaround: disabling `ControlMaster`. Both `ssh.nix` (the generated `~/.ssh/config`) and `client.nix` (the `rebuild-*`/`update-*` aliases, via `NIX_SSHOPTS`) set `ControlMaster no` defensively so this shouldn't bite you. If a rebuild ever fails with that protocol-mismatch error anyway, that GitHub issue is the first place to check for updates.

`ssh.nix`'s generated aliases point at each server's `tailscaleIp`, so once a node is bootstrapped, all SSH/build/rebuild traffic to it flows over Tailscale exclusively — nothing needs the public IP after the initial bootstrap.

---

## Common Pitfalls

These bit us during initial setup — worth checking first if something that used to work suddenly errors.

- **`nixos-rebuild` says a field is missing that you just fixed, or a change you just pushed doesn't seem to be there.** `github:owner/repo` flake refs (no pinned commit) are cached locally for up to an hour by Nix's tarball TTL. If you (or a collaborator) just pushed to `k3s-cluster` or `servers` and a rebuild doesn't reflect it, add `--refresh` to force a fresh fetch instead of waiting out the cache.
- **Any flake that consumes this repo pins an exact commit in its `flake.lock`** — pushing a change here does nothing for `servers` (or your personal nixos flake, if it also depends on `k3s-cluster` directly) until you run `nix flake lock --update-input k3s-cluster` there too, and push/rebuild. This has bitten us more than once: the fix landing here feels done, but the consumer is still building the old commit.
- **`rebuild-<name>`/`update-<name>` need `NIXOS_SECRETS_PATH` set** (pointing at your local `secrets.nix`) because `kubernetes-server` reads `secrets.githubToken` for the GymBros CI runner — even if you're not touching CI at all, the module evaluates it unconditionally. If you're only using `kubectl`/`k9s`/`fetch-kubeconfig` (not deploying to servers yourself), you don't need this set. If you are deploying, set it persistently via `home.sessionVariables.NIXOS_SECRETS_PATH` in your own home-manager profile — a plain shell `export`/`set -gx` only lasts for that terminal session and won't survive into new ones without it.

---

## Adding a New Server

All server configuration lives in `modules/cluster-vars.json`. Append an entry to the `servers` array:

```json
{
  "name": "my-server",
  "nixosAttr": "my-server",
  "sshAlias": "my-server",
  "ip": "1.2.3.4",
  "tailscaleIp": "100.x.x.x",
  "sshUser": "root",
  "role": "agent"
}
```

| Field | Description |
|-------|-------------|
| `name` | Used as suffix for shell aliases (`rebuild-<name>`, `update-<name>`, `clean-<name>`) |
| `nixosAttr` | The `nixosConfigurations.<attr>` key in the `Clusterforgers/servers` flake |
| `sshAlias` | The SSH `Host` entry written to `~/.ssh/config` |
| `ip` | Public IP — only used for TLS SANs, kubeconfig patching, and the one-time initial bootstrap before the node is on the tailnet |
| `tailscaleIp` | Tailscale IP — all steady-state SSH, builds, and cluster traffic use this |
| `sshUser` | SSH user for the server (usually `root`) |
| `role` | `"control-plane"` or `"agent"`, scripts use this to find the right server automatically |

There is no `sshKey` field — auth is via Tailscale SSH, gated by tailnet ACLs, not by keys. Nothing operator-specific belongs in this file; it's meant to be shared as-is between everyone working on the cluster.

After editing, run `rebuild` on your local machine to apply the new SSH config and generate the new aliases.

---

## Bootstrapping a New NixOS Server (First Deploy)

A freshly provisioned server isn't on the tailnet yet, so the very first connection has to go over its **public IP**, not the Tailscale alias. Everything after that first `nixos-rebuild` switches to Tailscale-only.

**Step 1 — Add the server to `modules/cluster-vars.json`** in this repo, and add its NixOS host config to `Clusterforgers/servers` (a directory importing `self.nixosModules.kubernetes-server` or `.kubernetes-agent`).

**Step 2 — Copy the `servers` flake to the server, over its public IP:**
```sh
rsync -avz ~/path/to/servers/ root@<public-ip>:/tmp/servers/
```

**Step 3 — Copy `secrets.nix`** (referenced via the `NIXOS_SECRETS_PATH` env var, not included in the flake source):
```sh
ssh root@<public-ip> 'mkdir -p /root'
rsync ~/nixos/secrets.nix root@<public-ip>:/root/secrets.nix
```

**Step 4 — Fix ownership and rebuild on the server natively:**
```sh
ssh root@<public-ip> 'chown -R root:root /tmp/servers && NIXOS_SECRETS_PATH=/root/secrets.nix nixos-rebuild switch --flake /tmp/servers#<nixosAttr> --impure'
```

**Step 5 — Fix the running hostname** (NixOS sets `/etc/hostname` but the kernel hostname may not update until reboot on some cloud providers):
```sh
ssh root@<public-ip> 'hostname <nixosAttr>'
```

**Step 6 — Bring up Tailscale SSH** (this is the step that makes the node reachable at all going forward — there's no OpenSSH fallback):
```sh
ssh root@<public-ip> 'tailscale up --ssh'
```
Make sure the operator's tailnet identity has an `ssh` grant in the ACL policy before relying on this — otherwise Tailscale SSH will refuse the connection.

**Step 7 — All future deploys work normally, over Tailscale only:**
```sh
rebuild-<name>    # rebuild with current flake lock
update-<name>     # update flake inputs, then rebuild
clean-<name>      # run nix garbage collection on the server
```

---

## Setting Up a Developer Machine

1. Add `inputs.k3s-cluster.homeModules.kubernetes-client` and `inputs.k3s-cluster.homeModules.ssh` to your home-manager profile (add `k3s-cluster.url = "github:Clusterforgers/k3s-cluster";` as a flake input first).
2. Run `rebuild`.
3. Run `fetch-kubeconfig` to pull the kubeconfig from the control plane.
4. Run `k9s` to connect to the cluster.

`fetch-kubeconfig` defaults to the control plane server. To target a specific server:
```sh
fetch-kubeconfig <ssh-alias>
```

If you're also going to run `rebuild-<name>`/`update-<name>` yourself (not just `kubectl`/`k9s`), see the `NIXOS_SECRETS_PATH` note under Common Pitfalls above.

---

## Adding a Worker Node (Agent)

**Step 1 — Add the node to `modules/cluster-vars.json`** with `"role": "agent"`, create its NixOS config in `Clusterforgers/servers` importing `self.nixosModules.kubernetes-agent`, and bootstrap it following the steps above.

**Step 2 — Verify Tailscale + Tailscale SSH came up:**
```sh
ssh root@<public-ip> 'tailscale status'
```

**Step 3 — Inject the cluster token from your local machine:**
```sh
bootstrap-node <new-server-ip> <ssh-user>
```

This pulls the token from the control plane and writes it securely to the new node.

**Step 4 — Verify in k9s:**
```sh
k9s
# type :nodes
```

---

## Moving the Control Plane

**Step 1 — Back up the database:**
```sh
kubectl exec -it -n gymbros deployment/gymbros-db -- pg_dump -U admin -d gymbros -F c > gymbros_migration_backup.dump
```

**Step 2 — Update `modules/cluster-vars.json`** with the new server's IPs and SSH alias. Bootstrap the new server, applying `kubernetes-server` and `kubernetes-deployments`.

**Step 3 — Restore GitOps:** Re-sync ArgoCD on the new server. ArgoCD rebuilds all application pods from the Git state.

**Step 4 — Restore the database:**
```sh
kubectl exec -i -n gymbros deployment/gymbros-db -- pg_restore -U admin -d gymbros -1 < gymbros_migration_backup.dump
kubectl rollout restart deployment gymbros-backend -n gymbros
```
