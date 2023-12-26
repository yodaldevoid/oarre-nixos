{ config, lib, pkgs, ... }:
{
  imports = let
    sops-nix_commit = "21f2b8f123a1601fef3cf6bbbdf5171257290a77";
  in [
    ./hardware-configuration.nix
    "${builtins.fetchTarball "https://github.com/Mic92/sops-nix/archive/${sops-nix_commit}.tar.gz"}/modules/sops"
  ];

  environment.systemPackages = with pkgs; [
    vim
    wget
    sops
    tailscale
    docker-client
    docker-compose
  ];
  environment.enableAllTerminfo = true;

  users.groups.samba = {};
  users.users.yodal = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" "podman" "samba" ];
    packages = with pkgs; [
      tree
    ];
    openssh.authorizedKeys.keyFiles = [ ./monamo_ed25519.pub ./katrin_ed25519.pub ];
  };
  users.users.samba = {
    isNormalUser = true;
    group = "samba";
  };

  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets."wireless.env" = {};

  networking.hostName = "oarre";
  networking.hostId = "441b4f6d";
  networking.wireless.enable = true;
  networking.wireless.environmentFile = config.sops.secrets."wireless.env".path;
  networking.wireless.networks = {
    "@HOME_SSID@" = {
        psk = "@HOME_PSK@";
    };
  };

  services.resolved.enable = true;

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
    allowedTCPPorts = [ 22 ];
  };

  time.timeZone = "America/New_York";

  programs.git.enable = true;

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    pinentryFlavor = "curses";
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  services.tailscale.enable = true;

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
    '';
    shares = {
      media = {
        path = "/data";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "samba";
        "force group" = "samba";
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

  # TODO: move docker-compose stuff to a module
  systemd.services."docker-compose@" = {
    description = "%i service with docker compose";
    partOf = [ "docker.service" ];
    after = [ "docker.service" "docker.socket" ];
    # partOf = [ "podman.service" ];
    # after = [ "podman.service" "podman.socket" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/etc/docker/compose/%i";
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose up -d";
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
    };
  };

  systemd.services."docker-compose@mealie" = {
    overrideStrategy = "asDropin";
    wantedBy = [ "default.target" ];
  };
  environment.etc.mealie-compose = {
    source = ./mealie-compose.yaml;
    target = "docker/compose/mealie/compose.yaml";
  };

  systemd.services."docker-compose@jellyfin" = {
    overrideStrategy = "asDropin";
    wantedBy = [ "default.target" ];
  };
  environment.etc.jellyfin-compose = {
    source = ./jellyfin-compose.yaml;
    target = "docker/compose/jellyfin/compose.yaml";
  };
  # TODO: automatically create links from config to log and cache

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

