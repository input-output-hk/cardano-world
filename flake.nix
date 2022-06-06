{
  description = "Cardano World";
  inputs.std.url = "github:divnix/std";
  inputs.n2c.url = "github:nlewo/nix2container";
  inputs.data-merge.url = "github:divnix/data-merge";
  inputs = {
    # --- Bitte Stack ----------------------------------------------
    bitte.url = "github:input-output-hk/bitte";
    bitte-cells.url = "github:input-output-hk/bitte-cells";
    # --------------------------------------------------------------
    # --- Auxiliaries ----------------------------------------------
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.05";
    capsules.url = "github:input-output-hk/devshell-capsules";
    # --------------------------------------------------------------
    # --- Bride Heads ----------------------------------------------
    # TODO: remove when moved to monorepo
    cardano-node.url = "github:input-output-hk/cardano-node";
    cardano-db-sync.url = "github:input-output-hk/cardano-db-sync/13.0.0-rc2";
    cardano-wallet.url = "github:input-output-hk/cardano-wallet";
    cardano-ogmios.url = "github:input-output-hk/cardano-ogmios/vasil";
    cardano-graphql = {
      url = "github:input-output-hk/cardano-graphql";
      flake = false;
    };
    cardano-explorer-app = {
      url = "github:input-output-hk/cardano-explorer-app";
      flake = false;
    };
    cardano-rosetta = {
      url = "github:input-output-hk/cardano-rosetta";
      flake = false;
    };
    # --------------------------------------------------------------
  };
  outputs = inputs: let
    nomadEnvs = inputs.self.${system}.cloud.nomadEnvs;
    system = "x86_64-linux";
  in
    inputs.std.growOn {
      inherit inputs;
      cellsFrom = ./nix;
      #debug = ["cells" "cloud" "packages"];
      organelles = [
        (inputs.std.data "constants")
        (inputs.std.data "environments")
        (inputs.std.data "nomadEnvs")
        (inputs.std.devshells "devshells")
        (inputs.std.functions "bitteProfile")
        (inputs.std.functions "devshellProfiles")
        (inputs.std.functions "hydrationProfiles")
        (inputs.std.functions "library")
        (inputs.std.functions "nomadJob")
        (inputs.std.functions "oci-images")
        (inputs.std.installables "packages")
        (inputs.std.runnables "entrypoints")
        (inputs.std.runnables "healthChecks")
        # automation
        (inputs.std.runnables "jobs")
        (inputs.std.functions "pipelines")
      ];
    }
    # Soil (layers) ...
    # 1) bitte instrumentation (TODO: `std`ize bitte)
    (
      let
        bitte = inputs.bitte.lib.mkBitteStack {
          inherit inputs;
          inherit (inputs) self;
          domain = "world.dev.cardano.org";
          bitteProfile = inputs.self.${system}.metal.bitteProfile.default;
          hydrationProfile = inputs.self.${system}.cloud.hydrationProfiles.default;
          deploySshKey = "./secrets/ssh-cardano";
        };
      in
        # if the bitte input is silenced (replaced by divnix/blank)
        # then don't generate flake level attrNames from mkBitteStack (it fails)
        if inputs.bitte ? lib
        then bitte
        else {}
    )
    # 2) renderes nomad environments (TODO: `std`ize as actions)
    {
      infra = inputs.bitte.lib.mkNomadJobs "infra" nomadEnvs;
      vasil-qa = inputs.bitte.lib.mkNomadJobs "vasil-qa" nomadEnvs;
      vasil-dev = inputs.bitte.lib.mkNomadJobs "vasil-dev" nomadEnvs;
    };
  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    extra-substituters = [
      # TODO: spongix
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    # post-build-hook = "./upload-to-cache.sh";
    allow-import-from-derivation = "true";
  };
  # --------------------------------------------------------------
}
