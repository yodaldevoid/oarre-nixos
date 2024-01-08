{ config, lib, pkgs, ... }:

with lib;

# TODO: provide a way to get the generated service name as a user
let
  cfg = config.compose;
in {
  options.compose = with types; {
    enable = mkOption {
      type = bool;
      default = false;
    };
    applications = mkOption {
      type = attrsOf (submodule {
        options = {
          # TODO: support overriding the name
          enable = mkOption {
            type = bool;
            default = true;
          };
          composeFile = mkOption {
            type = path;
          };
          after = mkOption {
            type = listOf str;
            default = [ ];
          };
          requires = mkOption {
            type = listOf str;
            default = [ ];
          };
        };
      });
      default = {};
    };
  };

  config = let
    # TODO: support podman
    runtimeService = "docker.service";
    runtimeSocket = "docker.socket";
    # TODO: support podman-compose
    composeExecutable = "${pkgs.docker-compose}/bin/docker-compose";

    enabledApplications = filterAttrs (name: app: app.enable) cfg.applications;
  in (mkIf cfg.enable {
    environment.systemPackages = [ pkgs.docker-compose ];
  
    systemd.services = let
      serviceTemplates = {
        "compose-application@" = {
          description = "%i application from a compose file";
          partOf = [ runtimeService ];
          after = [ runtimeService runtimeSocket ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            WorkingDirectory = "/etc/compose/%i";
            ExecStart = composeExecutable + " up -d";
            ExecStop = composeExecutable + " down";
          };
        };
        "compose-watcher@" = {
          description = "Restart compose-application@%i service when compose file changes";
          requisite = [ "compose@%i.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.systemdMinimal}/bin/systemctl try-restart compose-application@%i.service";
          };
        };
      };

      composeServices = lib.concatMapAttrs (name: app: {
        "compose-application@${name}" = {
          overrideStrategy = "asDropin";
          wantedBy = [ "default.target" ];
          after = app.after;
          requires = app.requires;
        };
      }) enabledApplications;
    in composeServices // serviceTemplates;

    systemd.paths = let
      pathTemplates = {
        "compose-watcher@" = {
          description = "Monitor compose file for %i service for changes";
          pathConfig = {
            PathChanged = "/etc/compose/%i/compose.yaml";
          };
        };
      };

      composePaths = lib.concatMapAttrs (name: app: {
        "compose-watcher@${name}" = {
          overrideStrategy = "asDropin";
          wantedBy = [ "default.target" ];
        };
      }) enabledApplications;
    in composePaths // pathTemplates;

    environment.etc = lib.concatMapAttrs (name: app: {
      "compose-file-${name}" = {
        source = app.composeFile;
        target = "compose/${name}/compose.yaml";
      };
    }) enabledApplications;
  });
}
