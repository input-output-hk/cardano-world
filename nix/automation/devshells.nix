{
  inputs,
  cell,
}: let
  inherit (inputs.std) std;
  inherit (inputs) capsules bitte-cells bitte nixpkgs;
  inherit (inputs.cells) cardano;

  # FIXME: this is a work around just to get access
  # to 'awsAutoScalingGroups'
  # TODO: std ize bitte properly to make this interface nicer
  bitte' = inputs.bitte.lib.mkBitteStack {
    inherit inputs;
    inherit (inputs) self;
    domain = "world.dev.cardano.org";
    bitteProfile = inputs.cells.metal.bitteProfile.default;
    hydrationProfile = inputs.cells.cloud.hydrationProfiles.default;
    deploySshKey = "not-a-key";
  };

  cardanoWorld = {
    extraModulesPath,
    pkgs,
    ...
  }: {
    name = nixpkgs.lib.mkForce "Cardano World";
    imports = [
      std.devshellProfiles.default
      bitte.devshellModule
    ];
    bitte = {
      domain = "world.dev.cardano.org";
      cluster = "cardano";
      namespace = "vasil-dev";
      provider = "AWS";
      cert = null;
      aws_profile = "cardano";
      aws_region = "eu-central-1";
      aws_autoscaling_groups =
        bitte'.clusters.cardano._proto.config.cluster.awsAutoScalingGroups;
    };
  };
in {
  dev = std.lib.mkShell {
    imports = [
      cardanoWorld
      capsules.base
      capsules.cloud
      capsules.integrations
      inputs.cells.cardano.devshellProfiles.dev
    ];
  };
  devops = std.lib.mkShell {
    imports = [
      cardanoWorld
      capsules.base
      capsules.cloud
      capsules.integrations
      inputs.cells.cardano.devshellProfiles.world
    ];
  };
  ops = std.lib.mkShell {
    imports = [
      cardanoWorld
      capsules.base
      capsules.cloud
      capsules.hooks
      capsules.metal
      capsules.integrations
      capsules.tools
      bitte-cells.patroni.devshellProfiles.default
      inputs.cells.cardano.devshellProfiles.world
    ];
  };
  minimal = std.lib.mkShell {
    imports = [
      cardanoWorld
      inputs.cells.cardano.devshellProfiles.minimal
    ];
  };
}
