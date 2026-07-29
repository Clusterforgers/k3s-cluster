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
| `modules/transposition.nix` | Teaches flake-parts how to merge `homeModules` across files: it doesn't know about Home Manager natively |

## Network & SSH model

Every node running `kubernetes-server` or `kubernetes-agent` gets Tailscale enabled with `tailscale0` marked as a trusted firewall interface. **Tailscale SSH** (`tailscale up --ssh`, run once per node, see bootstrap steps below) handles all SSH, both interactive logins and the automated `nixos-rebuild --target-host`/`--build-host` build path.

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
| `ip` | Public IP, only used for TLS SANs and the one-time initial bootstrap before the node is on the tailnet |
| `tailscaleIp` | Tailscale IP, all steady-state SSH, builds, and cluster traffic use this |
| `sshUser` | SSH user for the server (usually `root`) |
| `role` | `"control-plane"` or `"agent"`, scripts use this to find the right server automatically |

After editing, run `rebuild` on your local machine to apply the new SSH config and generate the new aliases.

`rebuild-<name>` and `update-<name>` both target `github:Clusterforgers/servers`, an unpinned flake ref, with `--refresh` so they always fetch its latest commit rather than a stale locally-cached tarball (Nix caches unpinned `github:` refs for up to an hour otherwise). The difference between them is `k3s-cluster`, not `servers`:
- `rebuild-<name>` deploys whatever `k3s-cluster` commit is currently locked in `servers`' own committed `flake.lock`.
- `update-<name>` adds `--override-input k3s-cluster github:Clusterforgers/k3s-cluster`, which fetches `k3s-cluster`'s latest HEAD directly for that one build, bypassing whatever's actually locked. Good for fast iteration, but it's ephemeral, it doesn't update `servers`' `flake.lock`. To make a `k3s-cluster` change the new durable default for everyone's `rebuild-<name>`, bump the lock for real: `cd` into a local checkout of `servers`, run `nix flake update k3s-cluster`, then commit and push `flake.lock`.

---

## Moving the Control Plane

This cluster uses k3s's embedded SQLite datastore, no etcd, no HA. That means all cluster state, every namespace, Secret, Longhorn volume record, and the node join token, lives in one directory on whichever node has `"role": "control-plane"`: `/var/lib/rancher/k3s/server`. Moving the control plane means relocating that directory to the new node, not bootstrapping a fresh cluster and restoring apps into it. Done this way, there's no ArgoCD resync and no per-app data restore to do, the existing cluster just continues running on new hardware.

**Do the config edit first, but don't rebuild anything until Step 6** — the old node keeps serving as control-plane while you stage the copy.

**Step 1 — Make the config change and get it live.** This is the step most likely to silently not work, verify each part:
1. Flip the roles in `cluster-vars.json` (new node → `"control-plane"`, old node → `"agent"`). Check the new control-plane candidate actually has a `tailscaleIp` (required) — an extra field like oracle's `vcnIp` is optional and only changes what `--node-external-ip` advertises; without it, `server.nix` falls back to `tailscaleIp`.
2. Commit and push `k3s-cluster`.
3. Bump `servers`' own lock so it points at that new commit — this is the step that's easy to get wrong. It must run inside an actual local checkout of the **`servers`** repo specifically, not some other flake (e.g. an unrelated personal NixOS config) that happens to also depend on `k3s-cluster` — updating the wrong flake's lock will look like it succeeded but silently does nothing for the cluster:
   ```sh
   cd /path/to/servers
   nix flake update k3s-cluster
   git add flake.lock && git commit -m "Update k3s-cluster input" && git push
   ```
   If `git status` shows nothing to commit after `nix flake update k3s-cluster`, that means the lock was already current, not that the command failed.

**Step 2 — Stop k3s on the old control-plane node:**
```sh
ssh <old-sshAlias> 'systemctl stop k3s'
```

**Step 3 — Pull the datastore off the old node as a local safety-net backup:**
```sh
ssh <old-sshAlias> 'tar czf /root/k3s-server-backup.tar.gz -C /var/lib/rancher/k3s server'
scp <old-sshAlias>:/root/k3s-server-backup.tar.gz ~/k3s-server-backup.tar.gz
```
Keep this tarball until the new control plane is verified healthy, it's the rollback path.

**Step 4 — Stop k3s on the new node** (it may already be running as an agent):
```sh
ssh <new-sshAlias> 'systemctl stop k3s'
```

**Step 5 — Copy the datastore onto the new node:**
```sh
scp ~/k3s-server-backup.tar.gz <new-sshAlias>:/root/
ssh <new-sshAlias> 'mkdir -p /var/lib/rancher/k3s && tar xzf /root/k3s-server-backup.tar.gz -C /var/lib/rancher/k3s'
```

**Step 6 — Rebuild the new control plane:**
```sh
rebuild-<new-name>
```
`rebuild-<name>` always fetches `servers`' latest commit (`--refresh` is baked into the alias), so as long as Step 1 actually landed, this deploys it. k3s comes up in server mode on the copied datastore, same cluster CA, certs, node token, and objects as before. Its TLS listener automatically adds the new node's `ip`/`tailscaleIp` as SANs from the flags already in `server.nix`, no manual cert regeneration needed.

If the command exits non-zero, don't assume the switch failed outright, some unit reload failures (e.g. `dbus-broker` timing out on a reload) can make `nixos-rebuild` report failure even though activation otherwise completed. Check directly instead of trusting the exit code:
```sh
ssh <new-sshAlias> 'systemctl status k3s --no-pager'
kubectl get nodes
```

**Step 7 — Verify before touching the old node:**
```sh
fetch-kubeconfig <new-sshAlias>
k9s   # confirm both nodes, all namespaces, and all workloads are present
```

**Step 8 — Give the old node a join token, then rebuild it as an agent.** The token *value* came along with the copied datastore (it's the same cluster secret it always was), but the file it needs — `/var/lib/rancher/k3s/cluster-token` — has never existed on this node before, since it was a server, not an agent. `bootstrap-node` writes it, fetching from whichever node `cluster-vars.json` currently marks as control-plane (the new one, after Step 1):
```sh
bootstrap-node <old-node-tailscaleIp> <old-node-sshUser>
rebuild-<old-name>
```
Watch the journal to confirm it actually joined the right control plane, not a stale cached address:
```sh
ssh <old-sshAlias> 'journalctl -u k3s -n 20 --no-pager'
```
It should reference the new control plane's `tailscaleIp`. If it's still pointing at the old node, the config that got deployed isn't the one you think it is, go back and check Step 1.

**Step 9 — Clean up.** The old node's `/var/lib/rancher/k3s/server` directory is now unused (agent state lives under `/var/lib/rancher/k3s/agent` instead) and can be removed once the cutover looks stable. Delete the local backup tarball once you're satisfied, or keep it somewhere safe a while longer. The old node's `kubectl get nodes` `ROLES` column will keep showing `control-plane` too, that's a stale Kubernetes Node label k3s doesn't auto-clear on a role change, harmless, and removable with `kubectl label node <old-name> node-role.kubernetes.io/control-plane-` if it bothers you.

Longhorn volume *data* isn't part of any of this, it's already replicated independently across nodes and unaffected by which node runs the API server.

---