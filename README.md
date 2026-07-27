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