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
| `ip` | Public IP, only used for TLS SANs, kubeconfig patching, and the one-time initial bootstrap before the node is on the tailnet |
| `tailscaleIp` | Tailscale IP, all steady-state SSH, builds, and cluster traffic use this |
| `sshUser` | SSH user for the server (usually `root`) |
| `role` | `"control-plane"` or `"agent"`, scripts use this to find the right server automatically |

After editing, run `rebuild` on your local machine to apply the new SSH config and generate the new aliases.

---

## Moving the Control Plane

This cluster uses k3s's embedded SQLite datastore, no etcd, no HA. That means all cluster state, every namespace, Secret, Longhorn volume record, and the node join token, lives in one directory on whichever node has `"role": "control-plane"`: `/var/lib/rancher/k3s/server`. Moving the control plane means relocating that directory to the new node, not bootstrapping a fresh cluster and restoring apps into it. Done this way, there's no ArgoCD resync and no per-app data restore to do, the existing cluster just continues running on new hardware, and agents rejoin with the token they already have.

**Do the config edit first, but don't rebuild anything until Step 6** — the old node keeps serving as control-plane while you stage the copy.

**Step 1 — Update `cluster-vars.json`** with the new node's role flipped to `"control-plane"` (and the old one to `"agent"`).

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

**Step 6 — Apply the role swap and rebuild the new control plane:**
```sh
update-<new-name>   # or rebuild-<new-name> if the flake lock is already current
```
k3s comes up in server mode on the copied datastore, same cluster CA, certs, node token, and objects as before. Its TLS listener automatically adds the new node's `ip`/`tailscaleIp` as SANs from the flags already in `server.nix`, no manual cert regeneration needed.

**Step 7 — Verify before touching the old node:**
```sh
fetch-kubeconfig <new-sshAlias>
k9s   # confirm both nodes, all namespaces, and all workloads are present
```

**Step 8 — Rebuild the old node as an agent:**
```sh
update-<old-name>
```
The join token came along with the copied datastore, so the old node rejoins with the *same* token it always had, no need to re-run `bootstrap-node`.

**Step 9 — Clean up.** The old node's `/var/lib/rancher/k3s/server` directory is now unused (agent state lives under `/var/lib/rancher/k3s/agent` instead) and can be removed once the cutover looks stable. Delete the local backup tarball once you're satisfied, or keep it somewhere safe a while longer.

Longhorn volume *data* isn't part of any of this, it's already replicated independently across nodes and unaffected by which node runs the API server.

---