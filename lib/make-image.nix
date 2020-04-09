{ pkgs, lib }:

with pkgs.lib;

module:

let
  eval = evalModules {
    modules = [ module ] ++ [
      # To not have to import all NixOS modules...
      ../modules/fake.nix
      ../modules/system.nix
      ../modules/image.nix
      # This is to make nix optionnal
      ../modules/nix-daemon.nix
      ../modules/s6.nix
      ../modules/systemd.nix
      ../modules/system-path.nix
    ] ++ (map (m: (pkgs.path + "/nixos/modules/") + m) [
      "/system/etc/etc.nix"
      "/config/users-groups.nix"
      "/misc/assertions.nix"
      "/config/shells-environment.nix"
      "/config/system-environment.nix"
      "/programs/environment.nix"
      "/misc/ids.nix"
      "/programs/bash/bash.nix"
      "/security/pam.nix"
      "/security/wrappers/default.nix"
      "/programs/shadow.nix"
      "/security/ca.nix"
      "/misc/meta.nix"
      "/misc/version.nix"
      "/services/continuous-integration/hydra/default.nix"
      "/services/databases/postgresql.nix"
      "/services/web-servers/nginx/default.nix"
      "/services/networking/consul.nix"
    ]);
    args = {
      inherit pkgs lib;
      utils = import (pkgs.path + /nixos/lib/utils.nix) pkgs;
    };
  };


  doc = import (pkgs.path + "../../doc/manual") {
    inherit pkgs;
    config = ({...}:{});
    version = "";
    revision = "";
    options = eval.options;
  };

  #  Activation user script is patched because it is creating
  # files in `/` while they have to be created in the build directory.
  activationScriptUsers = let
    userSpec = pkgs.lib.last (pkgs.lib.splitString " " eval.config.system.activationScripts.users.text);
    updateUsersGroupsPatched = pkgs.runCommand
      "update-users-groups-patched"
      { buildInputs = [ pkgs.gnused ]; }
      ''
        sed 's|/etc|etc|g;s|/var|var|g;s|nscd|true|g' ${(pkgs.path + /nixos/modules/config/update-users-groups.pl)} > $out
      '';
  in
    pkgs.runCommand "passwd-groups" { inherit userSpec; buildInputs = [ pkgs.jq ];} ''
      mkdir system
      cd system

      mkdir -p etc root $out

      # home dirs have to be created in the build directory
      sed 's|/home|home|g;s|/var|var|g' $userSpec > ../userSpecPatched

      ${pkgs.perl}/bin/perl -w \
        -I${pkgs.perlPackages.FileSlurp}/lib/perl5/site_perl \
        -I${pkgs.perlPackages.JSON}/lib/perl5/site_perl \
        ${updateUsersGroupsPatched} ../userSpecPatched

       cp -r * $out/
    '';

  # This comes from <nixpkgs/nixos/modules/system/activation/top-level.nix>
  failedAssertions = map (x: x.message) (filter (x: !x.assertion) eval.config.assertions);
  showWarnings = res: fold (w: x: builtins.trace "[1;31mwarning: ${w}[0m" x) res eval.config.warnings;
  withAssertions = f: if failedAssertions != []
    then throw "\nFailed assertions:\n${concatStringsSep "\n" (map (x: "- ${x}") failedAssertions)}"
    else showWarnings f;

  containerBuilder =
    if eval.config.nix.enable
    then pkgs.dockerTools.buildImageWithNixDb
    else pkgs.dockerTools.buildImage;

in withAssertions (containerBuilder {
  name = eval.config.image.name;
  tag = eval.config.image.tag;
  fromImage = eval.config.image.from;
  contents = [
    activationScriptUsers
    eval.config.system.path
    eval.config.system.build.etc ];
  extraCommands = eval.config.image.run;
  config = {
    EntryPoint = eval.config.image.entryPoint;
    Env = mapAttrsToList (n: v: "${n}=${v}") eval.config.image.env;
    ExposedPorts = eval.config.image.exposedPorts;
  };
})
//
# For debugging purposes
{
  config = eval.config;
  options = eval.options;
}
//
(optionalAttrs
  (eval.config.s6.init != null)
  { inherit (eval.config.s6) init; })
