{ self, ... }: let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);
  controlPlane = builtins.head (builtins.filter (s: s.role == "control-plane") vars.servers);
  serversFlake = "github:Clusterforgers/servers";
  serverCases = builtins.concatStringsSep "\n" (map (
      s: "      ${s.sshAlias}) SERVER_IP=\"${s.tailscaleIp}\" ;;"
    )
    vars.servers);
  serverNames = builtins.concatStringsSep ", " (map (s: s.sshAlias) vars.servers);
  serverAliases = builtins.listToAttrs (builtins.concatLists (map (server: [
      {
        name = "rebuild-${server.name}";
        value = "NIX_SSHOPTS='-o ControlMaster=no' nixos-rebuild switch --flake ${serversFlake}#${server.nixosAttr} --target-host ${server.sshAlias} --build-host ${server.sshAlias} --impure";
      }
      {
        name = "update-${server.name}";
        value = "nix flake update ${serversFlake} && NIX_SSHOPTS='-o ControlMaster=no' nixos-rebuild switch --flake ${serversFlake}#${server.nixosAttr} --target-host ${server.sshAlias} --build-host ${server.sshAlias} --impure";
      }
      {
        name = "clean-${server.name}";
        value = "ssh ${server.sshAlias} 'sudo nix-collect-garbage -d'";
      }
    ])
    vars.servers));
in {
  flake.homeModules.kubernetes-client = { pkgs, ... }: {
    programs.fish.shellAliases = serverAliases;

    home.packages = with pkgs; [
      kubectl
      kubernetes-helm
      k9s

      (writeShellScriptBin "fetch-kubeconfig" ''
        set -e

        SERVER="''${1:-${controlPlane.sshAlias}}"

        case "$SERVER" in
        ${serverCases}
          *) echo "Unknown server: $SERVER. Known: ${serverNames}"; exit 1 ;;
        esac

        echo "Fetching kubeconfig from $SERVER..."
        mkdir -p ~/.kube
        scp "$SERVER":/etc/rancher/k3s/k3s.yaml ~/.kube/config

        chmod 600 ~/.kube/config

        echo "Patching server IP to $SERVER_IP..."
        sed -i "s/127.0.0.1/$SERVER_IP/g" ~/.kube/config

        echo "Kubeconfig ready. Run 'k9s' to connect."
      '')

      (writeShellScriptBin "bootstrap-node" ''
        set -e
        NEW_IP=$1
        NEW_USER=$2

        if [ -z "$NEW_IP" ] || [ -z "$NEW_USER" ]; then
          echo "Usage: bootstrap-node <new-server-ip> <ssh-user>"
          echo "Example: bootstrap-node 192.168.1.50 root"
          exit 1
        fi

        echo "Fetching cluster token from control plane (${controlPlane.sshAlias})..."
        TOKEN=$(ssh ${controlPlane.sshAlias} "sudo cat /var/lib/rancher/k3s/server/node-token")

        echo "Injecting token into $NEW_IP..."
        ssh $NEW_USER@$NEW_IP "sudo mkdir -p /var/lib/rancher/k3s/ && echo '$TOKEN' | sudo tee /var/lib/rancher/k3s/cluster-token > /dev/null && sudo chmod 600 /var/lib/rancher/k3s/cluster-token"

        echo "Done. Deploy agent.nix to $NEW_IP to complete the join."
      '')

      (writeShellScriptBin "open-k3s-monitoring" ''
        set -e

        echo "Extracting Grafana credentials from the cluster..."
        PASSWORD=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d)

        echo "----------------------------------------"
        echo "Username: admin"
        echo "Password: $PASSWORD"
        echo "----------------------------------------"
        echo "Open your browser to: http://localhost:3000"
        echo "Press Ctrl+C to close the tunnel."
        echo "----------------------------------------"

        kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
      '')
    ];
  };
}
