{ inputs
, cell
,
}:
let
  inherit (inputs) nixpkgs iohk-nix;
  inherit (nixpkgs) lib;
  inherit (cell) packages;
  inherit (packages.project.pkgs) haskell-nix;
  inherit (packages.project.args) compiler-nix-name;
  inherit (packages.project) index-state;

in
rec {
  minimal = _: {
    commands = [
      {
        package = nixpkgs.b2sum;
        category = "cardano";
      }
      {
        package = nixpkgs.xxd;
        category = "cardano";
        name = "xxd";
      }
      {
        package = nixpkgs.haskellPackages.cbor-tool;
        category = "cardano";
      }
      {
        package = packages.bech32;
        name = "bech32";
        category = "cardano";
      }
      {
        package = inputs.cells.automation.jobs.update-cabal-source-repo-checksums;
        category = "nix-build";
      }
    ];
  };
  dev = _: {
    imports = [
      minimal
      packages.project.devshell
    ];

    commands = [
      {
        package = nixpkgs.callPackage iohk-nix.cabal-wrapper  {
          cabal-install = haskell-nix.cabal-install.${compiler-nix-name};
        };
        name = "cabal";
        category = "development";
      }
      {
        package = haskell-nix.tool compiler-nix-name "hlint" {
          version = "3.2.7";
          inherit index-state;
        };
        name = "hlint";
        category = "development";
      }
      {
        package = haskell-nix.tool compiler-nix-name "ghcid" {
          version = "0.8.7";
          inherit index-state;
        };
        name = "ghcid";
        category = "development";
      }
      {
        package = haskell-nix.tool compiler-nix-name "haskell-language-server" {
          version = "1.6.1.1";
          inherit index-state;
        };
        name = "haskell-language-server";
        category = "development";
      }
      {
        package = haskell-nix.tool compiler-nix-name "stylish-haskell" {
          version = "0.13.0.0";
          inherit index-state;
        };
        name = "stylish-haskell";
        category = "development";
      }
    ];
  };
  world = _: {
    imports = [
      minimal
    ];
    commands = [
      {
        package = packages.cardano-wallet;
        category = "cardano";
      }
      {
        package = packages.cardano-address;
        name = "cardano-address";
        category = "cardano";
      }
      {
        package = packages.cardano-cli;
        name = "cardano-cli";
        category = "cardano";
      }
      {
        package = packages.cardano-ping;
        name = "cardano-ping";
        category = "cardano";
      }
      {
        package = packages.cardano-node;
        name = "cardano-node";
        category = "cardano";
      }
    ];
  };
  monorepo = _: {
    commands = [
      {
        package = inputs.cells.automation.jobs.update-mono-repo;
        category = "nix-build";
      }
      {
        package = inputs.cells.cardano.prepare-mono-repo.merge-mono-repo;
        category = "nix-build";
      }
    ];
  };
}
