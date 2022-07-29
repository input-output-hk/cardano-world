############################################################################
# Builds Haskell packages with Haskell.nix
############################################################################
{ haskell-nix
, # ogmios project root directory
  src
}:
haskell-nix.cabalProject' {
  name = "ogmios";
  src = haskell-nix.haskellLib.cleanSourceWith {
    name = "ogmios-src";
    inherit src;
    subDir = "server";
    filter = path: type:
      builtins.all (x: x) [
        (baseNameOf path != "package.yaml")
      ];
  };
  compiler-nix-name = "ghc8107";
  modules = [
    {
      doHaddock = false;
      doCheck = false;
    }
    ({ pkgs, ... }: {
      # Use the VRF fork of libsodium
      packages = pkgs.lib.genAttrs [ "cardano-crypto-praos" "cardano-crypto-class" ] (_: {
        components.library.pkgconfig = pkgs.lib.mkForce [ [ pkgs.libsodium-vrf ] ];
      });
    })
  ];
}
