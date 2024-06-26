{ config, lib, pkgs, ... }:
{
  imports = let
    sops-nix_commit = "21f2b8f123a1601fef3cf6bbbdf5171257290a77";
  in [
    ./hardware-configuration.nix
    "${builtins.fetchTarball "https://github.com/Mic92/sops-nix/archive/${sops-nix_commit}.tar.gz"}/modules/sops"
    ./compose.nix
  ];

  environment.systemPackages = with pkgs; [
    vim
    wget
    tailscale
    lm_sensors
  ];
  environment.enableAllTerminfo = true;

  users.users = {
    yodal = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "networkmanager"
        "docker"
        "podman"
        "containers"
        "media"
      ];
      packages = with pkgs; [
        docker-client
        docker-compose
        file
        htop
        tmux
        tree
      ];
      openssh.authorizedKeys.keyFiles = [ ./monamo_ed25519.pub ./katrin_ed25519.pub ];
    };

    nutmonitor = { isSystemUser = true; group = "nutmonitor"; };

    ddclient = { isSystemUser = true; group = "containers"; uid = 2100; };
    swag = { isSystemUser = true; group = "containers"; uid = 2200; };
    mealie = { isSystemUser = true; group = "containers"; uid = 2300; };

    samba = { isNormalUser = true; group = "media"; uid = 2000; };
    jellyfin = { isSystemUser = true; group = "media"; uid = 2400; };
    qbittorrent = { isSystemUser = true; group = "media"; uid = 2500; };
    prowlarr = { isSystemUser = true; group = "media"; uid = 2501; };
    sonarr = { isSystemUser = true; group = "media"; uid = 2502; };
    radarr = { isSystemUser = true; group = "media"; uid = 2503; };
  };
  users.groups = {
    nutmonitor = {};

    media.gid = 2000;
    containers.gid = 2001;
  };

  sops.defaultSopsFile = ./secrets.yaml;

  networking.hostName = "oarre";
  networking.hostId = "441b4f6d";
  networking.wireless.enable = false;
  networking.wireless.environmentFile = config.sops.secrets."wireless.env".path;
  networking.wireless.networks = {
    "@HOME_SSID@" = {
        psk = "@HOME_PSK@";
    };
  };
  sops.secrets."wireless.env" = {};

  services.resolved.enable = true;

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [ 22 ];
    # Allow any of the docker-compose bridge networks access to Prometheus.
    # This is really just for Nginx to have acess, but there's not a good way
    # to specify the name of the bridge network's interface on the host side.
    interfaces."br-+".allowedTCPPorts = [ 9090 ];
  };

  time.timeZone = "America/New_York";

  programs.git.enable = true;

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.X11Forwarding = true;
  };
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "server";
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };
  services.samba = {
    enable = true;
    securityType = "user";
    openFirewall = true;
    extraConfig = ''
      server string = %h
      guest ok = yes
      map to guest = Bad User
      log file = /var/log/samba/%m.log
      max log size = 50
      printcap name = /dev/null
      load printers = no
      use sendfile = yes
    '';
    shares = {
      media = {
        path = "/data/media";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "samba";
        "force group" = "media";
      };
    };
  };

  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };
  virtualisation.podman = {
    enable = false;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  compose.enable = true;
  compose.applications = {
    ddclient.composeFile = ./compose/ddclient.yaml;
    swag.composeFile = ./compose/swag.yaml;
    mealie.composeFile = ./compose/mealie.yaml;
    jellyfin.composeFile = ./compose/jellyfin.yaml;
    arr.composeFile = ./compose/arr.yaml;
  };
  sops.secrets."protonvpn-wireguard.conf" = {};

  services.restic.backups = let
    zfsCmd = "${pkgs.zfs}/bin/zfs";
    mountCmd = "${pkgs.mount}/bin/mount";
    umountCmd = "${pkgs.umount}/bin/umount";
    curlCmd = "${pkgs.curl}/bin/curl -fsS -o /dev/null -m 10 --retry 5";
  in {
    data = {
      repositoryFile = config.sops.secrets."restic-b2-${config.networking.hostName}_repo".path;
      passwordFile = config.sops.secrets."restic-b2-${config.networking.hostName}_pass".path;
      initialize = true;
      environmentFile = config.sops.secrets."restic-b2-${config.networking.hostName}.env".path;
      # TODO: generate paths from attrNames config.compose.applications
      paths = map (p: "/backup${p}") [
        "/var/lib/ddclient"
        "/var/lib/swag"
        "/var/lib/mealie"
        "/var/lib/jellyfin"
        "/var/lib/arr"
        "/data/media"
      ];
      extraBackupArgs = [ "--tag data" ];
      pruneOpts = [
        "--tag data"
        "--keep-within-daily 7d"
        "--keep-within-weekly 2m"
        "--keep-within-monthly 1y"
        "--keep-within-yearly 2y"
      ];
      # TODO: calculate pools to snapshot from paths to backup
      backupPrepareCommand = ''
        set -e
        ${curlCmd} $HEALTHCHECK_URL/start
        # Destroy any lingering backup snapshot.
        ${umountCmd} /backup/data /backup/var/lib || true
        ${zfsCmd} list -t snapshot | grep -q "rpool.*@restic-backup" && ${zfsCmd} destroy -r rpool@restic-backup
        ${zfsCmd} list -t snapshot | grep -q "data.*@restic-backup" && ${zfsCmd} destroy -r data@restic-backup
        rm -rf /backup
        ${zfsCmd} snapshot -r rpool@restic-backup
        ${zfsCmd} snapshot -r data@restic-backup
        ${mountCmd} -m -t zfs rpool/nixos/var/lib@restic-backup /backup/var/lib
        ${mountCmd} -m -t zfs data@restic-backup /backup/data
      '';
      backupCleanupCommand = ''
        if [ "$SERVICE_RESULT" == "success" ]; then
          ${curlCmd} $HEALTHCHECK_URL
        else
          ${curlCmd} $HEALTHCHECK_URL/fail
        fi
        ${umountCmd} /backup/data /backup/var/lib
        ${zfsCmd} destroy -r rpool@restic-backup
        ${zfsCmd} destroy -r data@restic-backup
        rm -r /backup
      '';
      timerConfig = {
        OnCalendar = "03:00:00";
        Persistent = true;
      };
    };
  };
  systemd.services."restic-backups-data".serviceConfig = { PrivateTmp = lib.mkForce false; };
  sops.secrets."restic-b2-${config.networking.hostName}_repo" = {};
  sops.secrets."restic-b2-${config.networking.hostName}_pass" = {};
  sops.secrets."restic-b2-${config.networking.hostName}.env" = {};
  # TODO: backup /var/log
  # TODO: run "b2 cancel-all-unfinished-large-files <bucketName>"

  # TODO: use user nutdaemon for upsd when supported
  # TODO: use user nutmonitor for upsmon when supported. Until then set using RUN_AS_USER in upsmon.conf.
  power.ups = {
    enable = true;
    maxStartDelay = 10;
    ups.main = {
      description = "Tripp Lite SMART1500RM2U";
      driver = "tripplite_usb";
      port = "auto";
    };
    users = {
      admin = {
        passwordFile = config.sops.secrets.upsd_admin_pass.path;
        actions = ["set" "fsd"];
        instcmds = ["all"];
      };
      upswired = {
        passwordFile = config.sops.secrets.upsd_upswired_pass.path;
        upsmon = "primary";
      };
    };
    upsmon = {
      enable = true;
      monitor."main@localhost" =  {
        user = "upswired";
        type = "primary";
        passwordFile = config.sops.secrets.upsd_upswired_pass.path;
      };
      settings = {
        # Remove mkForce once https://github.com/NixOS/nixpkgs/issues/318582 is closed
        RUN_AS_USER = lib.mkForce config.users.users.nutmonitor.name;
        SHUTDOWNCMD = "systemctl poweroff --message \"UPS no longer able to power system\"";
      };
    };
  };
  sops.secrets.upsd_admin_pass = {};
  sops.secrets.upsd_upswired_pass = {};

  services.prometheus = {
    enable = true;
    # TODO: alertmanager
    exporters = {
      node = {
        enable = true;
        disabledCollectors = ["zfs"];
      };
      nut.enable = true;
      smartctl = {
        enable = true;
        user = "root";
        group = "root";
      };
      zfs = {
        enable = true;
        extraFlags = ["--exclude='@restic-backup'"];
      };
    };
    scrapeConfigs = [
      # TODO: exportarr for sonarr, radarr, prowlarr
      # TODO: mealie postgress
      # TODO: arr wireguard
      # TODO: jellyfin
      # TODO: systemd?
      # TODO: pihole?
      # TODO: docker
      # TODO: nginx
      {
        job_name = "node";
        static_configs = [{
          targets = ["127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
        }];
      }
      {
        job_name = "ups-main";
        metrics_path = "/ups_metrics";
        params = {
          ups = ["main"];
          variables = ["battery.charge,battery.voltage,battery.voltage.nominal,input.frequency.nominal,input.voltage,input.voltage.nominal,ups.load,ups.status,ups.temperature"];
        };
        static_configs = [{
          targets = ["127.0.0.1:${toString config.services.prometheus.exporters.nut.port}"];
          labels = {
            ups = "main";
          };
        }];
      }
      {
        job_name = "smartctl";
        static_configs = [{
          targets = ["127.0.0.1:${toString config.services.prometheus.exporters.smartctl.port}"];
        }];
      }
      {
        job_name = "zfs";
        static_configs = [{
          targets = ["127.0.0.1:${toString config.services.prometheus.exporters.zfs.port}"];
        }];
      }
    ];
    ruleFiles = [ ./prometheus/rules/zfs_alerts.yml ];
  };

  # TODO: get systemd-boot working with ZFS
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/efi";
  #boot.loader.systemd-boot.enable = true;
  boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
    mirroredBoots = [
      { devices = ["nodev"]; path = "/efi"; }
    ];
  };

  services.zfs.trim.enable = true;
  services.zfs.autoScrub.enable = true;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

}

