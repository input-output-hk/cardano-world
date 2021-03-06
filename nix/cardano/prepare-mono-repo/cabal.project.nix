{ lib
, index-state
, packages
, cardano-base-src
, plutus-src
}: ''
  -- run `nix flake lock --update-input hackageNix` after updating index-state.
  index-state: ${index-state}

  packages:
      ${lib.concatStringsSep "\n    " (lib.naturalSort (map (p: "src${p.src.origSubDir}") packages))}

  constraints:
      hedgehog >= 1.0
    , bimap >= 0.4.0
    , libsystemd-journal >= 1.4.4
    , systemd >= 2.3.0
      -- systemd-2.3.0 requires at least network 3.1.1.0 but it doesn't declare
      -- that dependency
    , network >= 3.1.1.0
    -- bizarre issue: in earlier versions they define their own 'GEq', in newer
    -- ones they reuse the one from 'some', but there isn't e.g. a proper version
    -- constraint from dependent-sum-template (which is the library we actually use).
    , dependent-sum > 0.6.2.0
    , HSOpenSSL >= 0.11.7.2

  allow-newer:
    *:aeson,
    monoidal-containers:aeson,
    size-based:template-haskell

  test-show-details: direct

  -- ---------------------------------------------------------

  -- The two following one-liners will cut off / restore the remainder of this file (for nix-shell users):
  -- when using the "cabal" wrapper script provided by nix-shell.
  -- --------------------------- 8< --------------------------
  -- Please do not put any `source-repository-package` clause above this line.

  -- Using a fork until our patches can be merged upstream
  source-repository-package
    type: git
    location: https://github.com/input-output-hk/optparse-applicative
    tag: 7497a29cb998721a9068d5725d49461f2bba0e7a
    --sha256: 1gvsrg925vynwgqwplgjmp53vj953qyh3wbdf34pw21c8r47w35r

  source-repository-package
    type: git
    location: https://github.com/vshabanov/ekg-json
    tag: 00ebe7211c981686e65730b7144fbf5350462608
    --sha256: 1zvjm3pb38w0ijig5wk5mdkzcszpmlp5d4zxvks2jk1rkypi8gsm

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/hedgehog-extras
    tag: 4e55143e06f3c730ad989dbdee59f9fd6edce167
    --sha256: 080m31jl53bggbp6r92p8xifs9x0sjv7y0xhi2r8dmdcac560scr

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/cardano-base
    tag: ${cardano-base-src.rev}
    --sha256: ${cardano-base-src.outputHash}
    subdir:
      base-deriving-via
      binary
      binary/test
      cardano-crypto-class
      cardano-crypto-praos
      cardano-crypto-tests
      measures
      orphans-deriving-via
      slotting
      strict-containers


  source-repository-package
    type: git
    location: https://github.com/input-output-hk/io-sim
    tag: f4183f274d88d0ad15817c7052df3a6a8b40e6dc
    --sha256: 0vb2pd9hl89v2y5hrhrsm69yx0jf98vppjmfncj2fraxr3p3lldw
    subdir:
      io-classes
      io-sim
      strict-stm

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/typed-protocols
    tag: 181601bc3d9e9d21a671ce01e0b481348b3ca104
    --sha256: 1lr97b2z7l0rpsmmz92rsv27qzd5vavz10cf7n25svya4kkiysp5
    subdir:
      typed-protocols
      typed-protocols-cborg
      typed-protocols-examples

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/cardano-crypto
    tag: f73079303f663e028288f9f4a9e08bcca39a923e
    --sha256: 1n87i15x54s0cjkh3nsxs4r1x016cdw1fypwmr68936n3xxsjn6q

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/cardano-prelude
    tag: bb4ed71ba8e587f672d06edf9d2e376f4b055555
    --sha256: 00h10l5mmiza9819p9v5q5749nb9pzgi20vpzpy1d34zmh6gf1cj
    subdir:
      cardano-prelude
      cardano-prelude-test

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/goblins
    tag: cde90a2b27f79187ca8310b6549331e59595e7ba
    --sha256: 17c88rbva3iw82yg9srlxjv2ia5wjb9cyqw44hik565f5v9svnyg

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/iohk-monitoring-framework
    tag: 066f7002aac5a0efc20e49643fea45454f226caa
    --sha256: 0s6x4in11k5ba7nl7la896g28sznf9185xlqg9c604jqz58vj9nj
    subdir:
      contra-tracer
      iohk-monitoring
      plugins/backend-aggregation
      plugins/backend-ekg
      plugins/backend-monitoring
      plugins/backend-trace-forwarder
      plugins/scribe-systemd
      tracer-transformers

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/Win32-network
    tag: 3825d3abf75f83f406c1f7161883c438dac7277d
    --sha256: 19wahfv726fa3mqajpqdqhnl9ica3xmf68i254q45iyjcpj1psqx

  source-repository-package
    type: git
    location: https://github.com/input-output-hk/plutus
    tag: ${plutus-src.rev}
    --sha256: ${plutus-src.outputHash}
    subdir:
      plutus-core
      plutus-ledger-api
      plutus-tx
      plutus-tx-plugin
      prettyprinter-configurable
      stubs/plutus-ghc-stub
      word-array

  source-repository-package
    type: git
    location: https://github.com/HeinrichApfelmus/threepenny-gui
    tag: 4ec92ded05ccf59ba4a874be4b404ac1b6d666b6
    --sha256: 00fvvaf4ir4hskq4a6gggbh2wmdvy8j8kn6s4m1p1vlh8m8mq514

  -- Drops an instance breaking our code. Should be released to Hackage eventually.
  source-repository-package
    type: git
    location: https://github.com/input-output-hk/flat
    tag: ee59880f47ab835dbd73bea0847dab7869fc20d8
    --sha256: 1lrzknw765pz2j97nvv9ip3l1mcpf2zr4n56hwlz0rk7wq7ls4cm

  -- https://github.com/fpco/weigh/pull/47
  source-repository-package
    type: git
    location: https://github.com/TeofilC/weigh.git
    tag: 8a3b2283c3e73a84ad1da6cb35a39d886c44772c
    --sha256: 13cnj7l50ihxhhrfl0j6xv64rw7xiq9c8nbwzqdzr6lkk3w7awmx

  source-repository-package
    type: git
    location: https://github.com/haskell-works/hw-aeson
    tag: 6dc309ff4260c71d9a18c220cbae8aa1dfe2a02e
    --sha256: 08zxzkk1fy8xrvl46lhzmpyisizl0nzl1n00g417vc0l170wsr9j

  package cryptonite
    -- Using RDRAND instead of /dev/urandom as an entropy source for key
    -- generation is dubious. Set the flag so we use /dev/urandom by default.
    flags: -support_rdrand

  package snap-server
    flags: +openssl

  package comonad
    flags: -test-doctests

  -- Have to specify  '-Werror' for each package until this is released:
  -- https://github.com/haskell/cabal/issues/3579
  ${lib.concatMapStrings (p:
  ''

  package ${p.identifier.name}
    ghc-options: -Werror
  '') packages}''
