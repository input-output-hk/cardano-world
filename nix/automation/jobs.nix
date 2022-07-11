{
  inputs,
  cell,
}: let
  inherit (inputs) nixpkgs cells iohk-nix;
  inherit (cells.cardano) packages oci-images;
  inherit (nixpkgs) lib;
  inherit (inputs.bitte-cells._writers.library) writeShellApplication;
  inherit (lib.strings) fileContents;

  cabal-project-utils = nixpkgs.callPackages iohk-nix.utils.cabal-project { };

  updateProposalTemplate = ''
    # Inputs: $PAYMENT_KEY, $NUM_GENESIS_KEYS, $KEY_DIR, $TESTNET_MAGIC, $PROPOSAL_ARGS

    CHANGE_ADDRESS=$(cardano-cli address build --payment-verification-key-file "$PAYMENT_KEY".vkey --testnet-magic "$TESTNET_MAGIC")
    TXIN=$(cardano-cli query utxo --address "$CHANGE_ADDRESS" --testnet-magic "$TESTNET_MAGIC" --out-file /dev/stdout \
            | jq -r 'to_entries[0]|.key'
    )
    EPOCH=$(cardano-cli query tip --testnet-magic "$TESTNET_MAGIC"|jq .epoch)
    echo "$TXIN" > /dev/null
    PROPOSAL_KEY_ARGS=()
    SIGNING_ARGS=()
    for ((i=0; i < "$NUM_GENESIS_KEYS"; i++))
    do
      PROPOSAL_KEY_ARGS+=("--genesis-verification-key-file" "$KEY_DIR/genesis-keys/shelley.00$i.vkey")
      SIGNING_ARGS+=("--signing-key-file" "$KEY_DIR/delegate-keys/shelley.00$i.skey")
    done


    cardano-cli governance create-update-proposal \
      --epoch "$EPOCH" \
      "''${PROPOSAL_ARGS[@]}" \
      "''${PROPOSAL_KEY_ARGS[@]}" \
      --out-file update.proposal
    cardano-cli transaction build \
      --tx-in "$TXIN" \
      --change-address "$CHANGE_ADDRESS" \
      --update-proposal-file update.proposal \
      --testnet-magic "$TESTNET_MAGIC" \
      --out-file tx-proposal.txbody
    cardano-cli transaction sign \
      --tx-body-file tx-proposal.txbody \
      --out-file tx-proposal.txsigned \
      --signing-key-file "$PAYMENT_KEY".skey \
      "''${SIGNING_ARGS[@]}"
    # TODO: remove if we figure out how to make it detect where in epoch we are
    if ! cardano-cli transaction submit --testnet-magic "$TESTNET_MAGIC" --tx-file tx-proposal.txsigned
    then
      cardano-cli governance create-update-proposal \
        --epoch $(("$EPOCH" + 1)) \
      "''${PROPOSAL_ARGS[@]}" \
      "''${PROPOSAL_KEY_ARGS[@]}" \
        --out-file update.proposal
      cardano-cli transaction build \
        --tx-in "$TXIN" \
        --change-address "$CHANGE_ADDRESS" \
        --update-proposal-file update.proposal \
        --testnet-magic "$TESTNET_MAGIC" \
        --out-file tx-proposal.txbody
      cardano-cli transaction sign \
        --tx-body-file tx-proposal.txbody \
        --out-file tx-proposal.txsigned \
        --signing-key-file "$PAYMENT_KEY".skey \
        "''${SIGNING_ARGS[@]}"
      cardano-cli transaction submit --testnet-magic "$TESTNET_MAGIC" --tx-file tx-proposal.txsigned
      fi
  '';
in {
  update-cabal-source-repo-checksums = writeShellApplication {
    name = "update-cabal-source-repo-checksums";
    text = ''
      # go to project root directory:
      while [[ $PWD != / && ! -e "cabal.project" ]]; do
        cd ..
      done

      >&2 echo "Updating sha256 of cabal.project 'source-repository-package's..."
      cabal-project-regenerate
    '';
    runtimeInputs = [cabal-project-utils.cabalProjectRegenerate];
  };
  cabal-project-check = cabal-project-utils.checkCabalProject;
  hlint-check = nixpkgs.callPackage iohk-nix.checks.hlint {
    inherit (packages) hlint;
    inherit (packages.project.args) src;
  };
  stylish-haskell-check = nixpkgs.callPackage inputs.iohk-nix.checks.stylish-haskell {
    inherit (packages) stylish-haskell;
    inherit (packages.project.args) src;
  };
  shell-check = nixpkgs.callPackage inputs.iohk-nix.checks.shell {
    src = inputs.self;
  };
  mkHydraRequiredJob = nonRequiredPaths: jobs: nixpkgs.releaseTools.aggregate {
    name = "github-required";
    meta.description = "All jobs required to pass CI";
    constituents = lib.collect lib.isDerivation
      (lib.mapAttrsRecursiveCond (v: !(lib.isDerivation v))
        (path: value:
          let stringPath = lib.concatStringsSep "." path; in if lib.isAttrs value && (lib.any (p: p stringPath) nonRequiredPaths) then { } else value)
        jobs);
  };
  # run-local-node = let
  #   envName = "testnet";
  #   config =
  #     library.evalNodeConfig envName
  #     nixosProfiles.run-node-testnet;
  #   cmd = writeShellApplication {
  #     name = "run-node";
  #     text =
  #       (fileContents ./../entrypoints/node-entrypoint.sh)
  #       + "\n"
  #       + config.script;
  #     env = {
  #       inherit (config) stateDir socketPath;
  #       inherit envName;
  #     };
  #     runtimeInputs = [
  #       packages.cardano-node
  #       packages.cardano-cli
  #       # TODO: take from somewhere else than aws, e.g. an iohk hydra published path or similar
  #       nixpkgs.awscli2
  #       nixpkgs.gnutar
  #       nixpkgs.gzip
  #     ];
  #   };
  # in {
  #   command = "run-node";
  #   dependencies = [cmd];
  # };
  # push-snapshot-node = let
  #   envName = "testnet";
  #   config =
  #     library.evalNodeConfig envName
  #     nixosProfiles.run-node-testnet;
  #   cmd = writeShellApplication {
  #     name = "push-snapshot";
  #     text = fileContents ./push-node-snapshot.sh;
  #     env = {
  #       inherit (config) stateDir;
  #       inherit envName;
  #     };
  #     runtimeInputs = [nixpkgs.awscli2 nixpkgs.gnutar nixpkgs.gzip nixpkgs.coreutils];
  #   };
  # in {
  #   command = "push-snapshot";
  #   dependencies = [cmd];
  # };
  gen-custom-node-config = writeShellApplication {
    name = "gen-custom-node-config";
    runtimeInputs = [packages.cardano-cli nixpkgs.coreutils];
    text = ''
      # Inputs: $START_TIME, $SLOT_LENGTH, $SECURITY_PARAM, $TESTNET_MAGIC, $TEMPLATE_DIR, $GENESIS_DIR
      export START_TIME=''${START_TIME:-$(date --utc +"%Y-%m-%dT%H:%M:%SZ" --date " now +30 min")}
      export SLOT_LENGTH=''${SLOT_LENGTH:-1000}
      export SECURITY_PARAM=''${SECURITY_PARAM:-36}
      export TEMPLATE_DIR=''${TEMPLATE_DIR:-"$PRJ_ROOT/nix/cardano/environments/testnet-template"}
      export GENESIS_DIR=''${GENESIS_DIR:-"$PRJ_ROOT/workbench/custom"}
      mkdir -p "$GENESIS_DIR"
      cardano-cli genesis create-cardano \
        --genesis-dir "$GENESIS_DIR" \
        --gen-genesis-keys 3 \
        --supply 30000000000000000 \
        --testnet-magic 9 \
        --slot-coefficient 0.05 \
        --byron-template "$TEMPLATE_DIR/byron.json" \
        --shelley-template "$TEMPLATE_DIR/shelley.json" \
        --alonzo-template "$TEMPLATE_DIR/alonzo.json" \
        --node-config-template "$TEMPLATE_DIR/config.json" \
        --security-param "$SECURITY_PARAM" \
        --slot-length "$SLOT_LENGTH" \
        --start-time "$START_TIME"
      # TODO remove when genesis generator outputs non-extended-key format
      pushd "$GENESIS_DIR/genesis-keys"
        for i in {0..2}
        do
          mv shelley.00"$i".vkey shelley.00"$i".vkey-ext
          cardano-cli key non-extended-key \
            --extended-verification-key-file shelley.00"$i".vkey-ext \
            --verification-key-file shelley.00"$i".vkey

        done

      popd
    '';
  };
  gen-custom-kv-config =
    writeShellApplication {
      name = "gen-custom-kv-config";
      runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
      text = ''
        # Inputs: $GENESIS_DIR, $ENV_NAME
        export GENESIS_DIR=''${GENESIS_DIR:-"$PRJ_ROOT/workbench/custom"}
        export ENV_NAME=''${ENV_NAME:-"custom-env"}
        mkdir -p "$PRJ_ROOT/nix/cloud/kv/consul/cardano"
        mkdir -p "$PRJ_ROOT/nix/cloud/kv/vault/cardano/$ENV_NAME"
        pushd "$GENESIS_DIR"
          jq -n \
            --arg byron "$(base64 -w 0 < byron-genesis.json)" \
            --arg shelley "$(base64 -w 0 < shelley-genesis.json)" \
            --arg alonzo "$(base64 -w 0 < alonzo-genesis.json)" \
            --argjson config "$(< node-config.json)" \
            '{byronGenesisBlob: $byron, shelleyGenesisBlob: $shelley, alonzoGenesisBlob: $alonzo, nodeConfig: $config}' \
          > config.json
          cp config.json "$PRJ_ROOT/nix/cloud/kv/consul/cardano/$ENV_NAME.json"
          pushd delegate-keys
            for i in {0..2}; do
              jq -n \
                --argjson cold "$(<shelley."00$i".skey)" \
                --argjson vrf "$(<shelley."00$i".vrf.skey)" \
                --argjson kes "$(<shelley."00$i".kes.skey)" \
                --argjson opcert "$(<shelley."00$i".opcert.json)" \
                --argjson counter "$(<shelley."00$i".counter.json)" \
                --argjson byron_cert "$(<byron."00$i".cert.json)" \
                '{
                  "kes.skey": $kes,
                  "vrf.skey": $vrf,
                  "opcert.json": $opcert,
                  "byron.cert.json": $byron_cert,
                  "cold.skey": $cold,
                  "cold.counter": $counter
                }' > "bft-$i.json"
                cp "bft-$i.json" "$PRJ_ROOT/nix/cloud/kv/vault/cardano/$ENV_NAME"
            done
          popd
          pushd "$PRJ_ROOT/nix/cloud/kv/vault/cardano/$ENV_NAME"
            for i in {0..2}; do
              sops -e "bft-$i.json" > "bft-$i.enc.json" && rm "bft-$i.json"
            done
          popd
        popd
      '';
    }
    // {after = ["gen-custom-node-config"];};
  push-custom-kv-config =
    writeShellApplication {
      name = "push-custom-kv-config";
      runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
      text = ''
        nix run .#clusters.cardano.tf.hydrate-app.plan
        nix run .#clusters.cardano.tf.hydrate-app.apply
      '';
    }
    // {after = ["gen-custom-kv-config"];};
  create-stake-pools = writeShellApplication {
    name = "create-stake-pools";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_KEY, $NUM_POOLS, $START_INDEX, $STAKE_POOL_OUTPUT_DIR, $POOL_RELAY, $POOL_RELAY_PORT
      WITNESSES=$(("$NUM_POOLS" * 2 + 1))
      END_INDEX=$(("$START_INDEX" + "$NUM_POOLS"))
      CHANGE_ADDRESS=$(cardano-cli address build --payment-verification-key-file "$PAYMENT_KEY".vkey --testnet-magic "$TESTNET_MAGIC")

      mkdir -p "$STAKE_POOL_OUTPUT_DIR"

      # generate wallet in control of all the funds delegated to the stake pools
      cardano-address recovery-phrase generate > "$STAKE_POOL_OUTPUT_DIR"/owner.mnemonic
      # extract reward address vkey
      cardano-address key from-recovery-phrase Shelley < "$STAKE_POOL_OUTPUT_DIR"/owner.mnemonic \
        | cardano-address key child 1852H/1815H/"0"H/2/0 \
        | cardano-cli key convert-cardano-address-key --shelley-stake-key \
            --signing-key-file /dev/stdin --out-file /dev/stdout \
        | cardano-cli key verification-key --signing-key-file /dev/stdin \
            --verification-key-file /dev/stdout \
        | cardano-cli key non-extended-key \
            --extended-verification-key-file /dev/stdin \
            --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-0-reward-stake.vkey
      for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
      do
        # extract stake skey/vkey needed for pool registration and delegation
        cardano-address key from-recovery-phrase Shelley < "$STAKE_POOL_OUTPUT_DIR"/owner.mnemonic \
          | cardano-address key child 1852H/1815H/"$i"H/2/0 \
          | cardano-cli key convert-cardano-address-key --shelley-stake-key \
              --signing-key-file /dev/stdin \
              --out-file /dev/stdout \
          | tee "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.skey \
          | cardano-cli key verification-key \
              --signing-key-file /dev/stdin \
              --verification-key-file /dev/stdout \
          | cardano-cli key non-extended-key \
              --extended-verification-key-file /dev/stdin \
              --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey
        # generate cold, vrf and kes keys
        cardano-cli node key-gen \
          --cold-signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.skey \
          --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.vkey \
          --operational-certificate-issue-counter-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.counter
        cardano-cli node key-gen-VRF \
          --signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-vrf.skey \
          --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-vrf.vkey
        cardano-cli node key-gen-KES \
          --signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-kes.skey \
          --verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-kes.vkey
        # generate opcert
        cardano-cli node issue-op-cert \
          --kes-period 0 \
          --kes-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-kes.vkey \
          --operational-certificate-issue-counter-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.counter \
          --cold-signing-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.skey \
          --out-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i".opcert
      # generate stake registration and delegation certificate
        cardano-cli stake-address registration-certificate \
          --stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey \
          --out-file sp-"$i"-owner-registration.cert
        cardano-cli stake-address delegation-certificate \
          --cold-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.vkey \
          --stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey \
          --out-file sp-"$i"-owner-delegation.cert
      # generate stake pool registration certificate
        cardano-cli stake-pool registration-certificate \
          --testnet-magic "$TESTNET_MAGIC" \
          --cold-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-cold.vkey \
          --pool-cost 500000000 \
          --pool-margin 1 \
          --pool-owner-stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey \
          --pool-pledge 100000000000000 \
          --single-host-pool-relay "$POOL_RELAY" \
          --pool-relay-port "$POOL_RELAY_PORT" \
          --pool-reward-account-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-0-reward-stake.vkey \
          --vrf-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-vrf.vkey \
          --out-file sp-"$i"-registration.cert
      done
      # generate transaction
      TXIN=$(cardano-cli query utxo --address "$CHANGE_ADDRESS" --testnet-magic "$TESTNET_MAGIC" --out-file /dev/stdout \
              | jq -r 'to_entries[0]|.key'
      )
      # generate arrays needed for build/sign commands
      BUILD_TX_ARGS=()
      SIGN_TX_ARGS=()
      for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
      do
        STAKE_POOL_ADDR=$(cardano-cli address build --payment-verification-key-file "$PAYMENT_KEY".vkey --stake-verification-key-file "$STAKE_POOL_OUTPUT_DIR"/sp-"$i"-owner-stake.vkey --testnet-magic "$TESTNET_MAGIC")
        BUILD_TX_ARGS+=("--tx-out" "$STAKE_POOL_ADDR+100000000000000")
        BUILD_TX_ARGS+=("--certificate-file" "sp-$i-owner-registration.cert")
        BUILD_TX_ARGS+=("--certificate-file" "sp-$i-registration.cert")
        BUILD_TX_ARGS+=("--certificate-file" "sp-$i-owner-delegation.cert")
        SIGN_TX_ARGS+=("--signing-key-file" "$STAKE_POOL_OUTPUT_DIR/sp-$i-cold.skey")
        SIGN_TX_ARGS+=("--signing-key-file" "$STAKE_POOL_OUTPUT_DIR/sp-$i-owner-stake.skey")
      done

      cardano-cli transaction build \
        --tx-in "$TXIN" \
        --change-address "$CHANGE_ADDRESS" \
        --witness-override "$WITNESSES" \
        "''${BUILD_TX_ARGS[@]}" \
        --testnet-magic "$TESTNET_MAGIC" \
        --out-file tx-pool-reg.txbody
      cardano-cli transaction sign \
        --tx-body-file tx-pool-reg.txbody \
        --out-file tx-pool-reg.txsigned \
        --signing-key-file "$PAYMENT_KEY".skey \
        "''${SIGN_TX_ARGS[@]}"
      cardano-cli transaction submit --testnet-magic "$TESTNET_MAGIC" --tx-file tx-pool-reg.txsigned
    '';
  };
  gen-custom-kv-config-pools =
    writeShellApplication {
      name = "gen-custom-kv-config-pools";
      runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
      text = ''
        # Inputs: $NUM_POOLS, $START_INDEX, $STAKE_POOL_DIR, $ENV_NAME
        export ENV_NAME=''${ENV_NAME:-"custom-env"}
        END_INDEX=$(("$START_INDEX" + "$NUM_POOLS"))
        mkdir -p "$PRJ_ROOT/nix/cloud/kv/vault/cardano/$ENV_NAME"
        pushd "$STAKE_POOL_DIR"
          for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
          do
            jq -n \
              --argjson cold    "$(< sp-"$i"-cold.skey)" \
              --argjson vrf     "$(< sp-"$i"-vrf.skey)" \
              --argjson kes     "$(< sp-"$i"-kes.skey)" \
              --argjson opcert  "$(< sp-"$i".opcert)" \
              --argjson counter "$(< sp-"$i"-cold.counter)" \
              '{
                "kes.skey": $kes,
                "vrf.skey": $vrf,
                "opcert.json": $opcert,
                "cold.skey": $cold,
                "cold.counter": $counter
              }' > "$PRJ_ROOT/nix/cloud/kv/vault/cardano/$ENV_NAME/sp-$i.json"
          done
        popd
        pushd "$PRJ_ROOT/nix/cloud/kv/vault/cardano/$ENV_NAME"
          for ((i="$START_INDEX"; i < "$END_INDEX"; i++))
          do
            sops -e "sp-$i.json" > "sp-$i.enc.json" && rm "sp-$i.json"
          done
        popd
      '';
    }
    // {after = ["gen-custom-node-config"];};
  move-genesis-utxo = writeShellApplication {
    name = "move-genesis-utxo";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_ADDRESS, $BYRON_SIGNING_KEY, $TESTNET_MAGIC
      BYRON_UTXO=$(cardano-cli query utxo --whole-utxo --testnet-magic "$TESTNET_MAGIC" --out-file /dev/stdout|jq \
        'to_entries[]|
        {"txin": .key, "address": .value.address, "amount": .value.value.lovelace}
        |select(.amount > 0)
      ')
      FEE=200000
      SUPPLY=$(echo "$BYRON_UTXO"|jq -r '.amount - 200000')
      BYRON_ADDRESS=$(echo "$BYRON_UTXO"|jq -r '.address')
      TXIN=$(echo "$BYRON_UTXO"|jq -r '.txin')

      cardano-cli transaction build-raw --tx-in "$TXIN" --tx-out "$PAYMENT_ADDRESS+$SUPPLY" --fee "$FEE" --out-file tx-byron.txbody
      cardano-cli transaction sign --tx-body-file tx-byron.txbody --out-file tx-byron.txsigned --address "$BYRON_ADDRESS" --signing-key-file "$BYRON_SIGNING_KEY"
      cardano-cli transaction submit --testnet-magic "$TESTNET_MAGIC" --tx-file tx-byron.txsigned
    '';
  };
  update-proposal-generic = writeShellApplication {
    name = "update-proposal-d";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_KEY, $NUM_GENESIS_KEYS, $KEY_DIR, $MAJOR_VERSION, $TESTNET_MAGIC, PROPOSAL_ARGS
      ${updateProposalTemplate}
    '';
  };
  update-proposal-d = writeShellApplication {
    name = "update-proposal-d";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_KEY, $NUM_GENESIS_KEYS, $KEY_DIR, $D_VALUE, $TESTNET_MAGIC
      PROPOSAL_ARGS=(
        "--decentralization-parameter" "$D_VALUE"
      )
      ${updateProposalTemplate}
    '';
  };
  update-proposal-hard-fork = writeShellApplication {
    name = "update-proposal-hf";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_KEY, $NUM_GENESIS_KEYS, $KEY_DIR, $MAJOR_VERSION, $TESTNET_MAGIC
      PROPOSAL_ARGS=(
        "--protocol-major-version" "$MAJOR_VERSION"
        "--protocol-minor-version" "0"
      )
      ${updateProposalTemplate}
    '';
  };
  update-proposal-cost-model = writeShellApplication {
    name = "update-proposal-hf";
    runtimeInputs = [nixpkgs.jq nixpkgs.coreutils];
    text = ''
      # Inputs: $PAYMENT_KEY, $NUM_GENESIS_KEYS, $KEY_DIR, $COST_MODEL, $TESTNET_MAGIC
      PROPOSAL_ARGS=(
        "--cost-model-file" "$COST_MODEL"
      )
      ${updateProposalTemplate}
    '';
  };
  release = let
    ociNamer = oci: builtins.unsafeDiscardStringContext "${oci.imageName}:${oci.imageTag}";
    release-notes = nixpkgs.writeText "release-notes" ''
      # Packages

      | Plattform    | Cache-Link |
      | ------------ | ---------- |
      | x86_64-linux | https://cache.iog.io/${cells.x86_64-linux.cardano.packages.cardano-node}

      # OCI-Images

      | Plattform    | `image:tag` |
      | ------------ | ---- |
      | x86_64-linux | `${ociNamer cells.x86_64-linux.cardano.oci-images.cardano-node}`
    '';
  in
    writeShellApplication {
      name = "release";
      runtimeInputs = [nixpkgs.gh];
      text = ''
        # Inputs: $TAG
        gh release create -d "$TAG" --notes-file ${release-notes}
      '';
    };
}
