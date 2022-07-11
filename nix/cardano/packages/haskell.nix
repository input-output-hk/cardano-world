############################################################################
# Builds Haskell packages with Haskell.nix
############################################################################
{ lib
, haskell-nix
, # cabal.project directory
  src
, byron-chain
}:
let

  inherit (haskell-nix) haskellLib;

  # This creates the Haskell package set.
  # https://input-output-hk.github.io/haskell.nix/user-guide/projects/
in
(haskell-nix.cabalProject' ({ pkgs
                            , config
                            , lib
                            , ...
                            }: {
  options = {
    packagesExes = lib.mkOption {
      type = lib.types.attrs;
      default =
        let
          project = haskell-nix.cabalProject' {
            inherit (config) name src compiler-nix-name cabalProjectLocal;
          };
          packages = haskellLib.selectProjectPackages project.hsPkgs;
        in
        lib.genAttrs
          (lib.attrNames packages)
          (name: lib.attrNames packages.${name}.components.exes);
      description = "Set of local project packages to list of executables";
    };
  };
  config = {
    name = "cardano-world";
    src = haskellLib.cleanSourceWith {
      src = src.outPath;
      name = "cardano-world-src";
      filter = path: type:
        let relPath = lib.removePrefix "${src.outPath}/" path; in
        # only keep cabal.project and directories under src:
        (relPath == "cabal.project" || relPath == "src" || (type == "directory" && (builtins.match "src/.*" relPath != null))
          || (builtins.match "src/.*/.*" relPath != null))
        && (lib.cleanSourceFilter path type)
        && (haskell-nix.haskellSourceFilter path type)
        && !(lib.hasSuffix ".gitignore" relPath)
        # removes socket files
        && lib.elem type [ "regular" "directory" "symlink" ];
    };
    compiler-nix-name = "ghc8107";
    cabalProjectLocal = ''
      allow-newer: terminfo:base
    '' + lib.optionalString pkgs.stdenv.hostPlatform.isWindows ''
      -- When cross compiling we don't have a `ghc` package
      package plutus-tx-plugin
        flags: +use-ghc-stub
    '';
    shell = {
      name = "cabal-dev-shell";

      packages = ps: builtins.attrValues (haskellLib.selectProjectPackages ps);

      # These programs will be available inside the nix-shell.
      nativeBuildInputs = with pkgs.buildPackages.buildPackages; [
      ];

      # Prevents cabal from choosing alternate plans, so that
      # *all* dependencies are provided by Nix.
      exactDeps = true;

      withHoogle = false;
    };
    modules =
      let
        inherit (config) src packagesExes;
        packageNames = builtins.attrNames packagesExes;
      in
      [
        # Allow reinstallation of Win32
        ({ pkgs, ... }: lib.mkIf pkgs.stdenv.hostPlatform.isWindows {
          nonReinstallablePkgs =
            [
              "rts"
              "ghc-heap"
              "ghc-prim"
              "integer-gmp"
              "integer-simple"
              "base"
              "deepseq"
              "array"
              "ghc-boot-th"
              "pretty"
              "template-haskell"
              # ghcjs custom packages
              "ghcjs-prim"
              "ghcjs-th"
              "ghc-boot"
              "ghc"
              "array"
              "binary"
              "bytestring"
              "containers"
              #"filepath"
              "ghc-boot"
              "ghc-compact"
              "ghc-prim"
              # "ghci" "haskeline"
              "hpc"
              "mtl"
              "parsec"
              "text"
              "transformers"
              "xhtml"
              # "stm" "terminfo"
            ];
          # When cross compfixesiling we don't have a `ghc` package
          packages.plutus-tx-plugin.flags.use-ghc-stub = true;
          # ruby/perl dependencies cannot be cross-built for cddl tests:
          packages.ouroboros-network.flags.cddl = false;
        })
        ({ pkgs, ... }: {
          packages.tx-generator.package.buildable = with pkgs.stdenv.hostPlatform; isUnix && !isMusl;
          packages.cardano-tracer.package.buildable = with pkgs.stdenv.hostPlatform; isUnix && !isMusl;
          packages.plutus-preprocessor.package.buildable = with pkgs.stdenv.hostPlatform; isUnix && !isMusl;
          packages.cardano-node-chairman.components.tests.chairman-tests.buildable = lib.mkForce pkgs.stdenv.hostPlatform.isUnix;
          packages.cardano-ledger-byron.components.tests.cardano-ledger-byron-test.buildable = lib.mkForce (with pkgs.stdenv.hostPlatform; isUnix && !isMusl);
          packages.cardano-ledger-shelley-ma-test.components.tests.cardano-ledger-shelley-ma-test.buildable = lib.mkForce (with pkgs.stdenv.hostPlatform; isUnix && !isMusl);
          packages.cardano-ledger-shelley-test.components.tests.cardano-ledger-shelley-test.buildable = lib.mkForce (with pkgs.stdenv.hostPlatform; isUnix && !isMusl);
          packages.cardano-ledger-alonzo-test.components.tests.cardano-ledger-alonzo-test.buildable = lib.mkForce (with pkgs.stdenv.hostPlatform; isUnix && !isMusl);
          packages.cardano-ledger-babbage-test.components.tests.cardano-ledger-babbage-test.buildable = lib.mkForce (with pkgs.stdenv.hostPlatform; isUnix && !isMusl);
          packages.plutus-tx-plugin.components.library.platforms = with lib.platforms; [ linux darwin ];
        })
        ({ pkgs, ... }: {
          # Needed for the CLI tests.
          # Coreutils because we need 'paste'.
          packages.cardano-cli.components.tests.cardano-cli-test.build-tools =
            lib.mkForce (with pkgs.buildPackages; [ jq coreutils shellcheck ]);
          packages.cardano-cli.components.tests.cardano-cli-golden.build-tools =
            lib.mkForce (with pkgs.buildPackages; [ jq coreutils shellcheck ]);
          packages.cardano-testnet.components.tests.cardano-testnet-tests.build-tools =
            lib.mkForce (with pkgs.buildPackages; [ jq coreutils shellcheck lsof ]);

          packages.cardano-ledger-shelley-ma-test.components.tests.cardano-ledger-shelley-ma-test.build-tools = with pkgs; [ cddl cbor-diag ];
          packages.cardano-ledger-shelley-test.components.tests.cardano-ledger-shelley-test.build-tools = with pkgs; [ cddl cbor-diag ];
          packages.cardano-ledger-alonzo-test.components.tests.cardano-ledger-alonzo-test.build-tools = with pkgs; [ cddl cbor-diag ];
          packages.cardano-ledger-babbage-test.components.tests.cardano-ledger-babbage-test.build-tools = with pkgs; [ cddl cbor-diag ];

          # Command-line options for test suites:
          packages.ouroboros-consensus-cardano-test.components.tests.test.testFlags =
            lib.mkForce [ "--no-create" ];
        })
        ({ pkgs, ... }: {
          # Use the VRF fork of libsodium
          packages = lib.genAttrs [ "cardano-crypto-praos" "cardano-crypto-class" ] (_: {
            components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf ] ];
          });
        })
        ({ pkgs, options, ... }: {
          # make sure that libsodium DLLs are available for windows binaries,
          # stamp executables with the git revision, add shell completion, strip/rewrite:
          packages = lib.mapAttrs
            (name: exes: {
              components.exes = lib.genAttrs exes (exe: {
                postInstall = ''
                  ${lib.optionalString (pkgs.stdenv.hostPlatform.isMusl) ''
                    ${pkgs.buildPackages.binutils-unwrapped}/bin/*strip $out/bin/*
                  ''}
                  ${lib.optionalString (pkgs.stdenv.hostPlatform.isDarwin) ''
                    export PATH=$PATH:${lib.makeBinPath [ pkgs.haskellBuildUtils pkgs.buildPackages.binutils pkgs.buildPackages.nix ]}
                    ${pkgs.haskellBuildUtils}/bin/rewrite-libs $out/bin $out/bin/*
                  ''}
                   ${lib.optionalString (!pkgs.stdenv.hostPlatform.isWindows
                    && lib.elem exe ["cardano-node" "cardano-cli" "cardano-topology" "locli"]) ''
                    BASH_COMPLETIONS=$out/share/bash-completion/completions
                    ZSH_COMPLETIONS=$out/share/zsh/site-functions
                    mkdir -p $BASH_COMPLETIONS $ZSH_COMPLETIONS
                    $out/bin/${exe} --bash-completion-script ${exe} > $BASH_COMPLETIONS/${exe}
                    $out/bin/${exe} --zsh-completion-script ${exe} > $ZSH_COMPLETIONS/_${exe}
                  ''}
                '';
              });
            })
            packagesExes;
        })
        ({ pkgs, config, ... }: {
          # Packages we wish to ignore version bounds of.
          # This is similar to jailbreakCabal, however it
          # does not require any messing with cabal files.
          packages.katip.doExactConfig = true;
          # split data output for ekg to reduce closure size
          packages.ekg.components.library.enableSeparateDataOutput = true;
          # cardano-cli-test depends on cardano-cli
          packages.cardano-cli.preCheck = "
          export CARDANO_CLI=${config.hsPkgs.cardano-cli.components.exes.cardano-cli}/bin/cardano-cli${pkgs.stdenv.hostPlatform.extensions.executable}
          export CARDANO_NODE_SRC=${src}
        ";
          packages.cardano-node-chairman.components.tests.chairman-tests.build-tools =
            lib.mkForce [
              pkgs.lsof
              config.hsPkgs.cardano-node.components.exes.cardano-node
              config.hsPkgs.cardano-cli.components.exes.cardano-cli
              config.hsPkgs.cardano-node-chairman.components.exes.cardano-node-chairman
            ];
          # cardano-node-chairman depends on cardano-node and cardano-cli
          packages.cardano-node-chairman.preCheck = "
          export CARDANO_CLI=${config.hsPkgs.cardano-cli.components.exes.cardano-cli}/bin/cardano-cli${pkgs.stdenv.hostPlatform.extensions.executable}
          export CARDANO_NODE=${config.hsPkgs.cardano-node.components.exes.cardano-node}/bin/cardano-node${pkgs.stdenv.hostPlatform.extensions.executable}
          export CARDANO_NODE_CHAIRMAN=${config.hsPkgs.cardano-node-chairman.components.exes.cardano-node-chairman}/bin/cardano-node-chairman${pkgs.stdenv.hostPlatform.extensions.executable}
          export CARDANO_NODE_SRC=${src}
        ";
          # cardano-testnet needs access to the git repository source
          packages.cardano-testnet.preCheck = "
          export CARDANO_CLI=${config.hsPkgs.cardano-cli.components.exes.cardano-cli}/bin/cardano-cli${pkgs.stdenv.hostPlatform.extensions.executable}
          export CARDANO_NODE=${config.hsPkgs.cardano-node.components.exes.cardano-node}/bin/cardano-node${pkgs.stdenv.hostPlatform.extensions.executable}
          export CARDANO_SUBMIT_API=${config.hsPkgs.cardano-submit-api.components.exes.cardano-submit-api}/bin/cardano-submit-api${pkgs.stdenv.hostPlatform.extensions.executable}
          ${lib.optionalString (!pkgs.stdenv.hostPlatform.isWindows) ''
          ''}
          export CARDANO_NODE_SRC=${src}
        ";
          packages.cardano-ledger-byron.components.tests.cardano-ledger-byron-test = {
            preCheck = ''
              export CARDANO_MAINNET_MIRROR="${byron-chain}/epochs"
              cp ${../environments/mainnet/byron-genesis.json} ./mainnet-genesis.json
            '';
            build-tools = [ pkgs.makeWrapper ];
            testFlags = [ "--scenario=ContinuousIntegration" ];
          };
        })
        ({ pkgs, ... }: lib.mkIf (!pkgs.stdenv.hostPlatform.isDarwin) {
          # Needed for profiled builds to fix an issue loading recursion-schemes part of makeBaseFunctor
          # that is missing from the `_p` output.  See https://gitlab.haskell.org/ghc/ghc/-/issues/18320
          # This work around currently breaks regular builds on macOS with:
          # <no location info>: error: ghc: ghc-iserv terminated (-11)
          packages.plutus-core.components.library.ghcOptions = [ "-fexternal-interpreter" ];
        })
        ({ pkgs, ... }: lib.mkIf (!pkgs.stdenv.hostPlatform.isWindows) {
          packages.ouroboros-network.flags.cddl = true;
          packages.ouroboros-network.components.tests.cddl.build-tools =
            [ pkgs.cddl pkgs.cbor-diag ];
          packages.ouroboros-network.components.tests.cddl.preCheck =
            "export HOME=`pwd`";
        })
        {
          packages =
            let
              # TODO: empty this list:
              packagesWithWarnings = [ "ouroboros-consensus" ];
            in
            lib.genAttrs (lib.subtractLists packagesWithWarnings packageNames)
              (name: { configureFlags = [ "--ghc-option=-Werror" ]; });
        }
        ({ pkgs, ... }: lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          # systemd can't be statically linked
          packages.cardano-git-rev.flags.systemd = !pkgs.stdenv.hostPlatform.isMusl;
          packages.cardano-node.flags.systemd = !pkgs.stdenv.hostPlatform.isMusl;
          packages.cardano-tracer.flags.systemd = !pkgs.stdenv.hostPlatform.isMusl;
        })
        # Musl libc fully static build
        ({ pkgs, ... }: lib.mkIf pkgs.stdenv.hostPlatform.isMusl (
          {
            packages = lib.genAttrs (packageNames ++ [ "bech32" ]) (name: {
              # Module option which adds GHC flags and libraries for a fully static build
              enableStatic = true;
            });
            # Haddock not working and not needed for cross builds
            doHaddock = false;
          }
        ))
        ({ pkgs, ... }: lib.mkIf (pkgs.stdenv.hostPlatform != pkgs.stdenv.buildPlatform) {
          # Remove hsc2hs build-tool dependencies (suitable version will be available as part of the ghc derivation)
          packages.Win32.components.library.build-tools = lib.mkForce [ ];
          packages.terminal-size.components.library.build-tools = lib.mkForce [ ];
          packages.network.components.library.build-tools = lib.mkForce [ ];
        })
        # TODO add flags to packages (like cs-ledger) so we can turn off tests that will
        # not build for windows on a per package bases (rather than using --disable-tests).
        # configureArgs = lib.optionalString stdenv.hostPlatform.isWindows "--disable-tests";
      ];
  };
})).appendOverlays (with haskellLib.projectOverlays; [
  devshell
  projectComponents
  (final: prev: {
    shell = prev.shell.overrideAttrs (oldAttrs: {
      # work-around for https://github.com/input-output-hk/haskell.nix/issues/1297
      buildInputs = lib.unique oldAttrs.buildInputs;
    });
    profiled = final.appendModule {
      modules = [{
        enableLibraryProfiling = true;
        packages.cardano-node.components.exes.cardano-node.enableProfiling = true;
        packages.tx-generator.components.exes.tx-generator.enableProfiling = true;
        packages.locli.components.exes.locli.enableProfiling = true;
      }];
    };
    asserted = final.appendModule {
      modules = [{
        packages = lib.genAttrs [
          "ouroboros-consensus"
          "ouroboros-consensus-cardano"
          "ouroboros-consensus-byron"
          "ouroboros-consensus-shelley"
          "ouroboros-consensus-mock"
          "ouroboros-network"
          "network-mux"
          "io-classes"
          "strict-stm"
        ]
          (name: { flags.asserts = true; });
      }];
    };
    eventlogged = final.appendModule
      {
        modules = [{
          packages = lib.genAttrs [ "cardano-node" ]
            (name: { configureFlags = [ "--ghc-option=-eventlog" ]; });
        }];
      };
    hsPkgs = lib.mapAttrsRecursiveCond (v: !(lib.isDerivation v))
      (path: value:
        if (lib.isAttrs value) then
          lib.recursiveUpdate
            (if lib.elemAt path 2 == "exes" && lib.elem (lib.elemAt path 3) [ "cardano-node" "cardano-cli" ] then
              let
                # setGitRev is a script to stamp executables with version info.
                # Done here to avoid tests depending on rev.
                setGitRev = ''${final.pkgs.buildPackages.haskellBuildUtils}/bin/set-git-rev "${src.rev}" $out/bin/*'';
              in
              final.pkgs.buildPackages.runCommand value.name
                {
                  inherit (value) exeName exePath meta passthru;
                } ''
                mkdir -p $out
                cp --no-preserve=timestamps --recursive ${value}/* $out/
                chmod -R +w $out/bin
                ${setGitRev}
              ''
            else value)
            {
              passthru = {
                profiled = lib.getAttrFromPath path final.profiled.hsPkgs;
                asserted = lib.getAttrFromPath path final.asserted.hsPkgs;
                eventlogged = lib.getAttrFromPath path final.eventlogged.hsPkgs;
              };
            } else value)
      prev.hsPkgs;
  })
])
