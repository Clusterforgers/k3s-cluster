{ lib, ... }: {
  options.flake = {
    # flake-parts doesn't know about Home Manager natively,
    # so we still need to tell it how to merge homeModules.
    homeModules = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
    };
  };
}
