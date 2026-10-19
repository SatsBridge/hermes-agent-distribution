_: {
  projectRootFile = "pkgs/by-name/gh/gh-token-manager/package.nix";

  programs = {
    nixfmt = {
      enable = true;
      strict = true;
    };
    deadnix.enable = true;
    statix.enable = true;
    nixf-diagnose.enable = true;
    rustfmt = {
      enable = true;
      edition = "2024";
    };
    rumdl-check.enable = true;
    rumdl-format.enable = true;
  };

  settings.global.excludes = [ "*.lock" ];
}
