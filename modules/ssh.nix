{ self, ... }: let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);
in {
  flake.homeModules.ssh = { config, lib, ... }: {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      settings =
        {"*" = {};}
        // builtins.listToAttrs (map (server: {
            name = server.sshAlias;
            value = {
              HostName = server.tailscaleIp;
              Port = 2222;
              User = server.sshUser;
            };
          })
          vars.servers);
    };
  };
}
