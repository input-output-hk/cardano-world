{ inputs
, cell
,
}:
let
  inherit (inputs) self std nixpkgs iohk-nix
    cardano-wallet cardano-db-sync cardano-ogmios cardano-graphql cardano-explorer-app nix-inclusive;
  inherit (inputs.cells) cardano;
  inherit (nixpkgs) lib;

  inherit (import inputs.nixpkgs-haskell {
    inherit (nixpkgs) system;
    inherit (inputs.haskell-nix) config;
    overlays = with iohk-nix.overlays; [
      inputs.haskell-nix.overlay
      haskell-nix-extra
      crypto
      (final: prev: {
        haskellBuildUtils = prev.haskellBuildUtils.override {
          inherit compiler-nix-name index-state;
        };
      })
    ];
  }) haskell-nix;

  project =
    (import ./haskell.nix {
      inherit lib haskell-nix;
      inherit (inputs) byron-chain;
      src = self;
    }).extend (final: prev: {
      release = nixpkgs.callPackage ./binary-release.nix {
        inherit (final.pkgs) stdenv;
        exes = lib.attrValues final.exes ++ [
          final.hsPkgs.bech32.components.exes.bech32
        ];
        inherit (final.exes.cardano-node.identifier) version;
        inherit (cardano.library) copyEnvsTemplate;
        inherit (cardano) environments;
      };
    });

  inherit (project.args) compiler-nix-name;
  inherit (project) index-state;

in
{
  inherit project; # TODO REMOVE
  inherit (project.exes) cardano-node cardano-cli cardano-submit-api cardano-tracer cardano-new-faucet;
  inherit (project.hsPkgs.bech32.components.exes) bech32;
  inherit (project.hsPkgs.network-mux.components.exes) cardano-ping;
  inherit (cardano-wallet.packages) cardano-wallet;
  inherit (cardano-wallet.packages) cardano-address;
  inherit (cardano-db-sync.packages) cardano-db-sync;
  inherit (cardano-ogmios.packages) ogmios;
  cardano-graphql = (import (cardano-graphql + "/nix/pkgs.nix") { inherit (nixpkgs) system; }).packages.cardano-graphql;
  graphql-engine = (import (cardano-graphql + "/nix/pkgs.nix") { inherit (nixpkgs) system; }).packages.graphql-engine;
  cardano-explorer-app =
    let
      # TODO fix the ugliness to make this work
      package = nixpkgs.callPackage (cardano-explorer-app + "/nix/cardano-explorer-app.nix") {
        nix-inclusive = nix-inclusive.lib.inclusive;
        sources = null;
      };
    in
    package;
  #cardano-rosetta-server = (import (cardano-rosetta + "/nix/pkgs.nix") {inherit (nixpkgs) system;}).packages.cardano-rosetta-server;
  cardano-config-html-public =
    let
      publicEnvNames = [ "mainnet" "testnet" "shelley_qa" "vasil-dev" ];
      environments = lib.filterAttrs (n: _: builtins.elem n publicEnvNames) cardano.environments;
    in
    cardano.library.generateStaticHTMLConfigs environments;
  cardano-config-html-internal = cardano.library.generateStaticHTMLConfigs cardano.environments;
  inherit nix-inclusive; # TODO REMOVE
}
