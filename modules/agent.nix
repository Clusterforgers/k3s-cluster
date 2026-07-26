{ self, ... }:
let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);
  controlPlane = builtins.head (builtins.filter (s: s.role == "control-plane") vars.servers);
in {
  flake.nixosModules.kubernetes-agent = { pkgs, config, ... }: {
    services.tailscale.enable = true;

    networking.firewall.trustedInterfaces = ["tailscale0"];

    services.openssh = {
      enable = true;
      ports = [2222];
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    services.k3s = {
      enable = true;
      role = "agent";
      serverAddr = "https://${controlPlane.ip}:6443";
      tokenFile = "/var/lib/rancher/k3s/cluster-token";
      extraFlags = toString [
        "--flannel-iface tailscale0"
      ];
    };

    environment.etc."rancher/k3s/registries.yaml".text = ''
      mirrors:
        "${controlPlane.tailscaleIp}:30500":
          endpoint:
            - "http://${controlPlane.tailscaleIp}:30500"
    '';

    services.openiscsi = {
      enable = true;
      name = "iqn.2023-01.io.longhorn:${config.networking.hostName}";
    };

    # Longhorn nsenters into the host and expects iscsiadm on an FHS path
    systemd.tmpfiles.rules = [
      "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    ];

    networking.firewall.allowedTCPPorts = [10250 3260];
    networking.firewall.allowedTCPPortRanges = [
      {
        from = 9500;
        to = 9520;
      }
    ];
    networking.firewall.allowedUDPPorts = [8472];

    environment.systemPackages = with pkgs; [k3s nfs-utils openiscsi];
  };
}
