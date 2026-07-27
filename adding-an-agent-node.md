# Adding an Agent Node

This walks through adding a new worker node from a blank machine: install NixOS,
point it at the cluster flake, then join it over Tailscale. Steady-state access is
Tailscale SSH only — there is no OpenSSH fallback — so the one manual step at the
machine's console is what bootstraps everything after it.

## 1. Install NixOS

Install a minimal NixOS on the new machine using the graphical or minimal installer.
No desktop is needed. Once it boots to a login on its own, note its **LAN/public IP**
(`ip -4 addr`) — you only need it for the one-time first connection before the node
is on the tailnet.

## 2. Register the node

**In `k3s-cluster`**, append an entry to the `servers` array in
`modules/cluster-vars.json`:

```json
{
  "name": "my-server",
  "nixosAttr": "my-server",
  "sshAlias": "my-server",
  "ip": "<lan-or-public-ip>",
  "tailscaleIp": "<fill in after step 4>",
  "sshUser": "root",
  "role": "agent"
}
```

Leave `tailscaleIp` as a placeholder for now — you don't have it until Tailscale is up.

**In `Clusterforgers/servers`**, create the host's NixOS config (a directory with its
`default.nix` / `configuration.nix`) that imports the agent module:

```nix
inputs.k3s-cluster.nixosModules.kubernetes-agent
```

Commit and push **both** repos. The deploy in the next step fetches the flake from
GitHub, so anything not pushed won't be seen.

## 3. First deploy (at the machine's console)

The node isn't on the tailnet yet, so this first build runs on the machine itself,
pulling the flake straight from GitHub (nothing needs to be copied to the box):

```sh
nixos-rebuild switch --flake github:Clusterforgers/servers#<nixosAttr> --refresh
```

`--refresh` forces Nix to re-fetch the latest commit rather than a cached one. This
activates the agent config, including Tailscale.

## 4. Bring the node onto the tailnet

Still at the console, authenticate to the tailnet and enable Tailscale SSH:

```sh
tailscale up --ssh      # opens a login URL — approve the node in your tailnet
tailscale ip -4         # prints the node's 100.x.x.x address
tailscale status        # confirm it's connected and can see the control plane
```

> The operator's tailnet identity needs an `ssh` grant in the ACL policy, or Tailscale
> SSH will refuse connections. If `rebuild-*` already works for your other nodes, this
> is already in place.

## 5. Wire up remote deploys

Take the `100.x.x.x` from the previous step and finish the registration:

1. Put it in the node's `tailscaleIp` field in `cluster-vars.json` (in `k3s-cluster`),
   commit and push.
2. In `Clusterforgers/servers`, pull the updated dependency and re-lock:
   ```sh
   nix flake update k3s-cluster
   git commit flake.lock -m "add <name> tailscaleIp"
   git push
   ```
3. On your **local machine**, regenerate the SSH aliases and config:
   ```sh
   rebuild
   ```

You can now reach the node over Tailscale — no console needed:

```sh
ssh <name>            # interactive login over Tailscale
rebuild-<name>        # deploy over Tailscale
update-<name>         # update flake inputs, then rebuild
clean-<name>          # garbage-collect on the node
```

## 6. Join the cluster

SSH access doesn't yet make the node a cluster member — it needs the k3s token from
the control plane. From your local machine:

```sh
bootstrap-node <name-or-ip> <ssh-user>
```

Then verify it registered:

```sh
k9s
# type :nodes  — the new node should appear and go Ready
```

Once it shows **Ready** and is schedulable (no leftover taints), ArgoCD can place
workloads on it.
