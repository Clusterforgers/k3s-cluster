{ self, ... }:
let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);
  controlPlane = builtins.head (builtins.filter (s: s.role == "control-plane") vars.servers);
in {
  flake.nixosModules.kubernetes-server = { pkgs, secrets, config, ... }: {
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
      role = "server";
      extraFlags = toString [
        "--disable=traefik"
        "--disable=local-storage"
        "--tls-san ${controlPlane.ip}"
        "--tls-san ${controlPlane.tailscaleIp}"
        "--node-ip ${controlPlane.tailscaleIp}"
        "--node-external-ip ${controlPlane.vcnIp}"
        "--flannel-iface tailscale0"
      ];
    };

    # Trust the internal registry over HTTP (only reachable via Tailscale)
    environment.etc."rancher/k3s/registries.yaml".text = ''
      mirrors:
        "${controlPlane.tailscaleIp}:30500":
          endpoint:
            - "http://${controlPlane.tailscaleIp}:30500"
    '';

    virtualisation.docker = {
      enable = true;
      daemon.settings.insecure-registries = ["${controlPlane.tailscaleIp}:30500"];
    };

    services.github-runners.gymbros = {
      enable = true;
      url = "https://github.com/Chrisser1/GymBros";
      tokenFile = "/var/lib/github-runner/token";
      extraLabels = ["arm64"];
      extraPackages = with pkgs; [docker git];
    };

    system.activationScripts.github-runner-token = {
      deps = ["users"];
      text = ''
        mkdir -p /var/lib/github-runner
        echo -n "${secrets.githubRunnerToken}" > /var/lib/github-runner/token
        chmod 600 /var/lib/github-runner/token
        chown github-runner-gymbros /var/lib/github-runner/token
      '';
    };

    users.users."github-runner-gymbros" = {
      isSystemUser = true;
      group = "github-runner-gymbros";
      extraGroups = ["docker"];
    };
    users.groups."github-runner-gymbros" = {};

    services.openiscsi = {
      enable = true;
      name = "iqn.2023-01.io.longhorn:${config.networking.hostName}";
    };

    # Longhorn nsenters into the host and expects iscsiadm on an FHS path
    systemd.tmpfiles.rules = [
      "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
    ];

    networking.firewall.allowedTCPPorts = [80 443 6443 10250 30500 3260];
    networking.firewall.allowedTCPPortRanges = [
      {
        from = 9500;
        to = 9520;
      }
    ];
    networking.firewall.allowedUDPPorts = [8472];

    environment.systemPackages = with pkgs; [
      k3s
      nfs-utils
      openiscsi
    ];
  };
}
