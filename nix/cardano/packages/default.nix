{
  inputs,
  cell,
}: let
  inherit (inputs) nixpkgs cardano-wallet cardano-db-sync cardano-node cardano-ogmios cardano-graphql cardano-explorer-app nix-inclusive;
  inherit (inputs.cells) cardano;
  inherit (nixpkgs) lib;
  cardano-node-project =
    (
      cardano-node.legacyPackages.extend (
        prev: final: {
          haskellBuildUtils =
            cardano-wallet
            .legacyPackages
            .pkgs
            .iohk-nix-utils;
        }
      )
    )
    .cardanoNodeProject;
in {
  cardano-node =
    cardano-node-project.hsPkgs.cardano-node.components.exes.cardano-node;
  cardano-tracer = "TODO";
  cardano-submit-api =
    cardano-node-project
    .hsPkgs
    .cardano-submit-api
    .components
    .exes
    .cardano-submit-api;
  cardano-cli = cardano-node-project.hsPkgs.cardano-cli.components.exes.cardano-cli;
  cardano-ping = cardano-node-project.hsPkgs.network-mux.components.exes.cardano-ping;
  cardano-wallet = cardano-wallet.packages.cardano-wallet;
  cardano-address = cardano-wallet.packages.cardano-address;
  cardano-db-sync = cardano-db-sync.packages.cardano-db-sync;
  cardano-graphql = (import (cardano-graphql + "/nix/pkgs.nix") {inherit (nixpkgs) system;}).packages.cardano-graphql;
  graphql-engine = (import (cardano-graphql + "/nix/pkgs.nix") {inherit (nixpkgs) system;}).packages.graphql-engine;
  cardano-explorer-app = let
    # TODO fix the ugliness to make this work
    package = nixpkgs.callPackage (cardano-explorer-app + "/nix/cardano-explorer-app.nix") {
      nix-inclusive = nix-inclusive.lib.inclusive;
      sources = null;
    };
  in
    package;
  #cardano-rosetta-server = (import (cardano-rosetta + "/nix/pkgs.nix") {inherit (nixpkgs) system;}).packages.cardano-rosetta-server;
  bech32 = cardano-node-project.hsPkgs.bech32.components.exes.bech32;
  ogmios = cardano-ogmios.packages.ogmios;
  cardano-config-html-public = let
    publicEnvNames = ["mainnet" "testnet" "vasil-qa" "vasil-dev"];
    environments = lib.filterAttrs (n: _: builtins.elem n publicEnvNames) cardano.environments;
  in
    cardano.library.generateStaticHTMLConfigs environments;
  cardano-config-html-internal = cardano.library.generateStaticHTMLConfigs cardano.environments;
  inherit nix-inclusive;
}
