{
  description = "Cardano World";

  inputs.nix-inclusive.url = "github:input-output-hk/nix-inclusive";
  inputs = {
    std = {
      url = "github:divnix/std";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    n2c.url = "github:nlewo/nix2container";
    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs = {
        hackage.follows = "hackage";
      };
    };
    hackage = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    iohk-nix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    data-merge.url = "github:divnix/data-merge";
    byron-chain = {
      url = "github:input-output-hk/cardano-mainnet-mirror";
      flake = false;
    };
    # --- Bitte Stack ----------------------------------------------
    bitte.url = "github:input-output-hk/bitte";
    bitte-cells = {
      url = "github:input-output-hk/bitte-cells";
      inputs = {
        std.follows = "std";
        nixpkgs.follows = "nixpkgs";
        n2c.follows = "n2c";
        data-merge.follows = "data-merge";
        cardano-iohk-nix.follows = "iohk-nix";
        cardano-node.follows = "cardano-node";
        cardano-db-sync.follows = "cardano-db-sync";
        cardano-wallet.follows = "cardano-wallet";
      };
    };
    # --------------------------------------------------------------
    # --- Auxiliaries ----------------------------------------------
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    nixpkgs-haskell.follows = "haskell-nix/nixpkgs-unstable";
    capsules.url = "github:input-output-hk/devshell-capsules";
    grafonnix.url = "github:divnix/grafonnix/auto-convert";
    # --------------------------------------------------------------
    # --- Bride Heads ----------------------------------------------
    # TODO: remove cardano-node (and use self) when mono-repo branch is merged:
    cardano-node = {
      url = "github:input-output-hk/cardano-node/1.35.2";
      flake = false;
    };
    cardano-db-sync.url = "github:input-output-hk/cardano-db-sync/13.0.2";
    cardano-wallet.url = "github:input-output-hk/cardano-wallet/v2022-07-01";
    ogmios = {
      url = "github:CardanoSolutions/ogmios/v5.5.2";
      flake = false;
    };
    cardano-graphql = {
      url = "github:input-output-hk/cardano-graphql";
      flake = false;
    };
    cardano-explorer-app = {
      url = "github:input-output-hk/cardano-explorer-app/fix-nix-system";
      flake = false;
    };
    #cardano-rosetta = {
    #  url = "github:input-output-hk/cardano-rosetta";
    #  flake = false;
    #};
    # --------------------------------------------------------------
    tullia.url = "github:input-output-hk/tullia";
  };
  outputs = inputs: let
    inherit (inputs.nixpkgs) lib;
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
        (inputs.std.data "alerts")
        (inputs.std.data "dashboards")
        (inputs.std.devshells "devshells")
        (inputs.std.functions "bitteProfile")
        (inputs.std.functions "devshellProfiles")
        (inputs.std.functions "hydrationProfiles")
        (inputs.std.functions "library")
        (inputs.std.functions "nomadJob")
        (inputs.std.containers "oci-images")
        (inputs.std.installables "packages")
        (inputs.std.functions "hydraJobs")
        (inputs.std.functions "prepare-mono-repo")
        (inputs.std.runnables "entrypoints")
        (inputs.std.runnables "healthChecks")
        # automation
        (inputs.std.runnables "jobs")

        # Tullia
        (inputs.tullia.tasks "pipelines")
        (inputs.std.functions "actions")
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
    }
    # 3) hydra jobs
    (
      let
        jobs = lib.filterAttrsRecursive (n: _: n != "recurseForDerivations") (
          lib.mapAttrs (n: lib.mapAttrs (_: cell: cell.hydraJobs or {})) {
            # systems with hydra builders:
            inherit (inputs.self) x86_64-linux x86_64-darwin;
          }
        );
        requiredJobs = lib.filterAttrsRecursive (n: v: n == "required" || !(lib.isDerivation v)) jobs;
        required = inputs.self.x86_64-linux.automation.jobs.mkHydraRequiredJob [] requiredJobs;
      in {
        hydraJobs =
          jobs
          // {
            inherit required;
          };
      }
    )
    # 4) oci-images re-export due to image tag changes stemming from bitte-cells follows
    {
      vector.oci-images = inputs.std.harvest inputs.bitte-cells ["vector" "oci-images"];
    }
    # 5) tullia tasks and cicero actions
    (inputs.tullia.fromStd {
      actions = inputs.std.harvest inputs.self ["cloud" "actions"];
      tasks = inputs.std.harvest inputs.self ["automation" "pipelines"];
    });
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
