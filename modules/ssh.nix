{ self, lib, ... }: let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);

  isValidIp = ip: builtins.isString ip && builtins.match "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" ip != null;

  # New nodes carry a placeholder tailscaleIp until Tailscale is up on them
  # (see adding-an-agent-node.md). Rendering that straight into ~/.ssh/config
  # produces an invalid HostName line, which aborts parsing of the *entire*
  # file for every host, not just this one. Skip and warn instead.
  serversWithIp = builtins.filter (
    server:
      isValidIp server.tailscaleIp
      || lib.warn "ssh.nix: skipping SSH host '${server.sshAlias}' — tailscaleIp is missing or invalid (${builtins.toJSON server.tailscaleIp})" false
  )
  vars.servers;
in {
  flake.homeModules.ssh = { config, lib, ... }: {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      settings =
        {
          # Works around an open Tailscale SSH / nix-copy-closure interaction bug where
          # ssh multiplexing corrupts the 'nix-store --serve' handshake:
          # https://github.com/tailscale/tailscale/issues/14093
          "*" = {ControlMaster = "no";};
        }
        // builtins.listToAttrs (map (server: {
            name = server.sshAlias;
            value = {
              HostName = server.tailscaleIp;
              User = server.sshUser;
            };
          })
          serversWithIp);
    };
  };
}
