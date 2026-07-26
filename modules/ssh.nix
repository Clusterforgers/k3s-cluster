{ self, ... }: let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);
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
          vars.servers);
    };
  };
}
