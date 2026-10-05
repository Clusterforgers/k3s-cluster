{ self, ... }: let
  vars = builtins.fromJSON (builtins.readFile ./cluster-vars.json);
  controlPlane = builtins.head (builtins.filter (s: s.role == "control-plane") vars.servers);
  hostArgs = builtins.concatStringsSep " " (map (s: "${s.nixosAttr}:${s.sshAlias}") vars.servers);

  # Resolves the local Clusterforgers/servers checkout. Precedence:
  #   --repo <path>  >  $SERVERS_REPO  >  remembered path  >  interactive prompt
  # The remembered path is re-validated every run, so a moved or deleted
  # checkout prompts for a new one instead of failing deep inside a deploy.
  repoPreamble = cmd: ''
    CONFIG_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/clusterforgers"
    CONFIG_FILE="$CONFIG_DIR/servers-repo"
    REPO=""
    RECONFIGURE=0
    SKIP=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo)
          REPO="''${2:-}"
          [ -n "$REPO" ] || { echo "error: --repo needs a path" >&2; exit 1; }
          shift 2
          ;;
        --reconfigure) RECONFIGURE=1; shift ;;
        --skip)
          [ -n "''${2:-}" ] || { echo "error: --skip needs a host name" >&2; exit 1; }
          SKIP="''${SKIP:+$SKIP,}$2"
          shift 2
          ;;
        -h|--help)
          echo "usage: ${cmd} [--repo <path>] [--reconfigure] [--skip <host>]"
          echo
          echo "  --repo <path>   use this Clusterforgers/servers checkout for this run"
          echo "  --reconfigure   forget the remembered checkout and ask again"
          echo "  --skip <host>   (cluster commands) leave this host out; repeatable"
          echo
          echo "The checkout path is remembered in $CONFIG_FILE."
          exit 0
          ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
      esac
    done

    is_servers_checkout() {
      [ -n "''${1:-}" ] || return 1
      [ -d "$1/.git" ] || return 1
      [ -f "$1/flake.nix" ] || return 1
      url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
      case "$url" in
        *Clusterforgers/servers*) return 0 ;;
        *) return 1 ;;
      esac
    }

    remember_checkout() {
      mkdir -p "$CONFIG_DIR"
      printf '%s\n' "$REPO" > "$CONFIG_FILE"
      echo "==> Remembered checkout path in $CONFIG_FILE" >&2
    }

    prompt_for_checkout() {
      default=""
      is_servers_checkout "$PWD" && default=$(pwd)

      if [ ! -t 0 ]; then
        if [ -n "$default" ]; then
          REPO="$default"
          remember_checkout
          return 0
        fi
        echo "error: no Clusterforgers/servers checkout configured, and stdin is not a terminal" >&2
        echo "       run ${cmd} interactively once, or pass --repo <path>, or set SERVERS_REPO" >&2
        exit 1
      fi

      while true; do
        if [ -n "$default" ]; then
          printf 'Path to your Clusterforgers/servers checkout [%s]: ' "$default" >&2
        else
          printf 'Path to your Clusterforgers/servers checkout: ' >&2
        fi
        read -r reply || exit 1
        [ -n "$reply" ] || reply="$default"
        reply="''${reply/#\~/$HOME}"
        if [ -z "$reply" ]; then
          continue
        elif is_servers_checkout "$reply"; then
          REPO=$(cd "$reply" && pwd)
          remember_checkout
          return 0
        elif [ ! -d "$reply" ]; then
          echo "  no such directory: $reply" >&2
        else
          echo "  not a Clusterforgers/servers checkout: $reply" >&2
        fi
      done
    }

    if [ -n "$REPO" ]; then
      is_servers_checkout "$REPO" ||
        { echo "error: --repo $REPO is not a Clusterforgers/servers checkout" >&2; exit 1; }
      REPO=$(cd "$REPO" && pwd)
    elif [ -n "''${SERVERS_REPO:-}" ]; then
      REPO="$SERVERS_REPO"
      is_servers_checkout "$REPO" ||
        { echo "error: SERVERS_REPO=$REPO is not a Clusterforgers/servers checkout" >&2; exit 1; }
      REPO=$(cd "$REPO" && pwd)
    elif [ "$RECONFIGURE" = 1 ]; then
      prompt_for_checkout
    elif stored=$(cat "$CONFIG_FILE" 2>/dev/null) && is_servers_checkout "$stored"; then
      REPO="$stored"
    else
      if [ -n "''${stored:-}" ]; then
        echo "Remembered checkout $stored is no longer a Clusterforgers/servers clone." >&2
      fi
      prompt_for_checkout
    fi

    echo "==> Using servers checkout: $REPO"
  '';

  # Both commands fetch before doing anything, so a checkout that is behind
  # origin can never be deployed by accident. Sets $ahead / $behind.
  gitSyncHelpers = ''
    BRANCH=main

    fetch_status() {
      echo "==> Fetching origin/$BRANCH"
      git fetch --quiet origin "$BRANCH"
      behind=$(git rev-list --count "HEAD..origin/$BRANCH")
      ahead=$(git rev-list --count "origin/$BRANCH..HEAD")
    }

    working_tree_dirty() {
      [ -n "$(git status --porcelain)" ]
    }
  '';

  # Shared by every deploy command: refuse to deploy a checkout that is behind
  # or diverged from origin, fast-forwarding when that is unambiguously safe.
  syncGate = ''
    cd "$REPO"
    current=$(git rev-parse --abbrev-ref HEAD)
    fetch_status

    if [ "$current" != "$BRANCH" ]; then
      echo "==> On branch '$current' (not $BRANCH); deploying it as-is"
    elif [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
      echo "error: $REPO has diverged from origin/$BRANCH ($ahead ahead, $behind behind)" >&2
      echo "       reconcile before deploying, or the hosts get config nobody else has" >&2
      exit 1
    elif [ "$behind" -gt 0 ] && working_tree_dirty; then
      echo "error: $behind commit(s) behind origin/$BRANCH, and the tree has local edits" >&2
      echo "       commit or stash them, then rerun so the fast-forward can apply" >&2
      exit 1
    elif [ "$behind" -gt 0 ]; then
      echo "==> Fast-forwarding $behind commit(s) from origin/$BRANCH"
      git merge --ff-only "origin/$BRANCH"
    fi

    if working_tree_dirty; then
      echo "==> Note: deploying uncommitted local changes"
    fi
  '';

  # Activation restarts tailscaled / NetworkManager, which tears down the very
  # link the deploy runs over. nixos-rebuild wraps activation in `systemd-run
  # --pipe`, whose transient unit dies with the SSH session - so a dropped
  # connection could kill activation midway, leaving units stopped and never
  # started again. Instead: stage with `boot` (restarts nothing, so the link is
  # safe), then run the switch fully detached and poll for the result.
  deployHelpers = ''
    SSH_OPTS='-o ControlMaster=no -o ServerAliveInterval=15 -o ServerAliveCountMax=4'

    host_ssh() {
      target=$1
      shift
      # shellcheck disable=SC2086
      ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "$target" "$@"
    }

    expected_toplevel() {
      nix eval --raw --impure "$REPO#nixosConfigurations.$1.config.system.build.toplevel"
    }

    report_failed_units() {
      failed=$(host_ssh "$1" systemctl --failed --no-legend --plain 2>/dev/null | cut -d' ' -f1) || return 0
      if [ -n "$failed" ]; then
        echo "    warning: units in a failed state on $1:" >&2
        printf '      %s\n' $failed >&2
      fi
    }

    # Build, copy, install the bootloader and point the system profile at the
    # new generation. Activates nothing, so this can never drop the connection.
    stage_host() {
      echo "--> stage $1 ($2)"
      NIX_SSHOPTS="$SSH_OPTS" nixos-rebuild boot \
        --flake "$REPO#$1" \
        --target-host "$2" --build-host "$2" --impure
    }

    # Run switch-to-configuration detached on the host, then poll. The
    # connection dropping mid-switch is expected here and no longer fatal.
    activate_host() {
      attr=$1
      host=$2
      echo "--> activate $attr ($host)"

      if ! expected=$(expected_toplevel "$attr"); then
        echo "error: could not evaluate the expected system for $attr" >&2
        return 1
      fi

      host_ssh "$host" systemd-run --collect --no-block \
        --unit=cluster-switch --service-type=oneshot \
        /nix/var/nix/profiles/system/bin/switch-to-configuration switch

      echo "    switching detached; waiting for $host to report the new system..."
      tries=0
      while [ "$tries" -lt 60 ]; do
        tries=$((tries + 1))
        sleep 5
        actual=$(host_ssh "$host" readlink -f /run/current-system 2>/dev/null) || continue
        [ "$actual" = "$expected" ] || continue
        # /run/current-system flips before unit restarts finish, so also wait
        # for the detached switch unit itself to be gone.
        if host_ssh "$host" systemctl is-active --quiet cluster-switch.service 2>/dev/null; then
          continue
        fi
        echo "    $host activated."
        report_failed_units "$host"
        return 0
      done

      echo "error: $host did not report the new system within 300s" >&2
      echo "       inspect: ssh $host journalctl -u cluster-switch -n 50" >&2
      return 1
    }


    host_skipped() {
      case ",$SKIP," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
      esac
    }
    deploy_host() {
      echo "==> $1 ($2)"
      stage_host "$1" "$2"
      activate_host "$1" "$2"
    }
  '';
  serverCases = builtins.concatStringsSep "\n" (map (
      s: "      ${s.sshAlias}) SERVER_IP=\"${s.tailscaleIp}\" ;;"
    )
    vars.servers);
  serverNames = builtins.concatStringsSep ", " (map (s: s.sshAlias) vars.servers);
  cleanHostArgs = builtins.concatStringsSep " " (map (s: "${s.name}:${s.sshAlias}") vars.servers);
  cleanNames = builtins.concatStringsSep ", " (map (s: s.name) vars.servers);
  serverAliases = builtins.listToAttrs (map (server: {
      name = "clean-${server.name}";
      value = "ssh ${server.sshAlias} 'sudo nix-collect-garbage -d'";
    })
    vars.servers);
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

      # Headlamp is a NodePort on the tailnet, not an Ingress host, so unlike
      # open-k3s-monitoring there is no tunnel to hold open here. This reads the
      # standing non-expiring token out of the cluster rather than minting one:
      # `kubectl create token` can only issue bounded tokens, so a fresh one
      # every run would mean re-pasting on every device it was handed to.
      (writeShellScriptBin "open-headlamp" ''
        set -e

        URL="http://${controlPlane.tailscaleIp}:30080"

        TOKEN=$(kubectl get secret headlamp-token -n headlamp \
          -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) || true

        if [ -z "$TOKEN" ]; then
          echo "error: no token in secret/headlamp-token (namespace headlamp)" >&2
          echo "       if the app was only just synced, the token controller" >&2
          echo "       may still be filling it in; retry in a few seconds." >&2
          echo "       otherwise check: kubectl -n headlamp get secret headlamp-token" >&2
          exit 1
        fi

        echo "----------------------------------------"
        echo "URL:   $URL"
        echo "Token: $TOKEN"
        echo "----------------------------------------"
        echo "Paste into Headlamp's sign-in prompt. The token does not expire,"
        echo "so each device only needs this once."
        echo "----------------------------------------"
      '')

      # Stoat has no admin UI for invites, so codes go straight into Mongo's
      # account_invites collection. Each code is single-use: on signup Stoat
      # marks it `used` and records the account in `claimed_by`.
      (writeShellScriptBin "stoat-invite" ''
        set -euo pipefail

        mongo() {
          kubectl -n stoat exec deploy/database -- mongosh revolt --quiet --eval "$1"
        }

        case "''${1:-}" in
          -h|--help)
            echo "usage: stoat-invite [<code>]   create an invite (random code if omitted)"
            echo "       stoat-invite --list     show all invites and who claimed them"
            exit 0
            ;;
          --list)
            # Account and user ids are the same in Stoat, so claimed_by joins
            # straight onto users for a readable name.
            mongo '
              db.account_invites.find().forEach(i => {
                let who = "";
                if (i.claimed_by) {
                  const u = db.users.findOne({ _id: i.claimed_by });
                  who = u ? u.username + "#" + u.discriminator : i.claimed_by;
                }
                print((i.used ? "used  " : "free  ") + i._id + (who ? "  -> " + who : ""));
              })'
            exit 0
            ;;
        esac

        CODE="''${1:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10 || true)}"
        # The code is spliced into JavaScript below, so keep it to safe characters.
        if ! printf '%s' "$CODE" | grep -Eq '^[A-Za-z0-9_-]{1,64}$'; then
          echo "error: invite codes may only use letters, digits, '-' and '_'" >&2
          exit 1
        fi

        if [ "$(mongo "db.account_invites.countDocuments({ _id: '$CODE' })")" != "0" ]; then
          echo "error: invite '$CODE' already exists (see stoat-invite --list)" >&2
          exit 1
        fi
        mongo "db.account_invites.insertOne({ _id: '$CODE' })" > /dev/null

        HOST=$(kubectl -n stoat get ingress stoat -o jsonpath='{.spec.rules[0].host}')
        echo "Invite created (single use). Send this:"
        echo
        echo "  Join us on Stoat: https://$HOST"
        echo "  Click 'Create an account' and use invite code: $CODE"
      '')

      (writeShellScriptBin "rebuild-cluster" ''
        set -euo pipefail

        ${repoPreamble "rebuild-cluster"}
        ${gitSyncHelpers}
        ${syncGate}
        ${deployHelpers}

        for entry in ${hostArgs}; do
          attr="''${entry%%:*}"
          host_skipped "$attr" && { echo "==> skipping $attr (--skip)"; continue; }
          deploy_host "''${entry%%:*}" "''${entry##*:}"
        done
      '')

      (writeShellScriptBin "update-cluster" ''
        set -euo pipefail

        ${repoPreamble "update-cluster"}
        ${gitSyncHelpers}
        ${deployHelpers}

        cd "$REPO"

        branch=$(git rev-parse --abbrev-ref HEAD)
        if [ "$branch" != "$BRANCH" ]; then
          echo "error: $REPO is on '$branch', expected '$BRANCH'" >&2
          exit 1
        fi

        dirty=$(git status --porcelain -- . ':(exclude)flake.lock')
        if [ -n "$dirty" ]; then
          echo "error: uncommitted changes in $REPO:" >&2
          printf '%s\n' "$dirty" >&2
          echo "       update-cluster only commits flake.lock; commit or stash these first" >&2
          exit 1
        fi

        fetch_status
        if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
          echo "error: $REPO has diverged from origin/$BRANCH ($ahead ahead, $behind behind)" >&2
          echo "       reconcile before updating; the lock commit could not be pushed anyway" >&2
          exit 1
        elif [ "$behind" -gt 0 ]; then
          echo "==> Fast-forwarding $behind commit(s) from origin/$BRANCH"
          git merge --ff-only "origin/$BRANCH"
        elif [ "$ahead" -gt 0 ]; then
          echo "==> $ahead local commit(s) not on origin yet; they go up with the lock"
        else
          echo "==> Already up to date with origin/$BRANCH"
        fi

        summary=$(mktemp)
        trap 'rm -f "$summary" "$summary.msg"' EXIT

        echo "==> Updating flake inputs"
        before=$(sha256sum flake.lock | cut -d' ' -f1)
        nix flake update 2>&1 | tee "$summary"
        after=$(sha256sum flake.lock | cut -d' ' -f1)

        if [ "$before" = "$after" ]; then
          echo "==> Inputs already current; redeploying to converge hosts"
        fi

        echo
        echo "==> Phase 1/2: staging every host (nothing is activated yet)"
        for entry in ${hostArgs}; do
          attr="''${entry%%:*}"
          host="''${entry##*:}"
          host_skipped "$attr" && { echo "--> skipping $attr (--skip)"; continue; }
          if ! stage_host "$attr" "$host"; then
            echo >&2
            echo "error: $attr failed to build; no host was activated" >&2
            git checkout -- flake.lock
            echo "       flake.lock reverted, nothing committed or pushed" >&2
            exit 1
          fi
        done

        echo
        echo "==> Phase 2/2: activating"
        activated=""
        for entry in ${hostArgs}; do
          attr="''${entry%%:*}"
          host="''${entry##*:}"
          host_skipped "$attr" && { echo "--> skipping $attr (--skip)"; continue; }
          if ! activate_host "$attr" "$host"; then
            echo >&2
            echo "error: $attr failed to activate" >&2
            echo "       activated so far:''${activated:- (none)}" >&2
            echo "       flake.lock is updated but NOT committed, so git still" >&2
            echo "       describes the previously deployed inputs." >&2
            echo "       retry:     update-cluster" >&2
            echo "       roll back: git -C $REPO checkout -- flake.lock && rebuild-cluster" >&2
            exit 1
          fi
          activated="$activated $attr"
        done

        if [ "$before" = "$after" ]; then
          echo
          echo "==> All hosts converged; lock unchanged, nothing to commit."
          exit 0
        fi

        echo
        if [ -n "$SKIP" ]; then
          echo "==> Deployed hosts activated (skipped: $SKIP); recording lock in git"
        else
          echo "==> All hosts activated; recording lock in git"
        fi
        {
          printf 'flake: bump inputs\n\n'
          grep -v '^warning:' "$summary" || true
          printf '\nDeployed to:%s\n' "$activated"
          if [ -n "$SKIP" ]; then printf 'Skipped (NOT deployed): %s\n' "$SKIP"; fi
        } > "$summary.msg"
        git add flake.lock
        git commit -F "$summary.msg"
        git push origin "$BRANCH"
        if [ -n "$SKIP" ]; then
          echo "==> Done. origin/$BRANCH records the lock, but $SKIP was NOT deployed"
          echo "    and is still on its old system. Deploy it with rebuild-<host>"
          echo "    once it is reachable."
        else
          echo "==> Done. origin/$BRANCH now records exactly what is running."
        fi
      '')

      # Every other cluster-wide command aborts on the first failure, but a GC
      # sweep has no ordering to protect: one unreachable host should not stop
      # the others from being cleaned. Failures are collected, reported at the
      # end, and reflected in the exit status instead.
      (writeShellScriptBin "clean-cluster" ''
        set -euo pipefail

        SKIP=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --skip)
              [ -n "''${2:-}" ] || { echo "error: --skip needs a host name" >&2; exit 1; }
              SKIP="''${SKIP:+$SKIP,}$2"
              shift 2
              ;;
            -h|--help)
              echo "usage: clean-cluster [--skip <host>]"
              echo
              echo "Runs 'nix-collect-garbage -d' on every host: the cluster-wide"
              echo "counterpart to the per-host clean-<name> aliases."
              echo
              echo "  --skip <host>   leave this host out; repeatable"
              echo
              echo "Hosts: ${cleanNames}"
              exit 0
              ;;
            *) echo "error: unknown option: $1" >&2; exit 1 ;;
          esac
        done

        host_skipped() {
          case ",$SKIP," in
            *",$1,"*) return 0 ;;
            *) return 1 ;;
          esac
        }

        failures=""
        for entry in ${cleanHostArgs}; do
          name="''${entry%%:*}"
          host="''${entry##*:}"
          host_skipped "$name" && { echo "==> skipping $name (--skip)"; continue; }

          echo "==> $name ($host)"
          if ! ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
                   "$host" 'sudo nix-collect-garbage -d'; then
            echo "    warning: garbage collection failed on $name" >&2
            failures="$failures $name"
          fi
        done

        if [ -n "$failures" ]; then
          echo >&2
          echo "error: garbage collection did not run on:$failures" >&2
          exit 1
        fi

        echo
        echo "==> Done. Every host garbage-collected."
      '')
    ]
    ++ (map (server:
      writeShellScriptBin "rebuild-${server.name}" ''
        set -euo pipefail

        ${repoPreamble "rebuild-${server.name}"}
        ${gitSyncHelpers}
        ${syncGate}
        ${deployHelpers}

        deploy_host ${server.nixosAttr} ${server.sshAlias}
      '')
      vars.servers);
  };
}
