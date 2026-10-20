_: {
  projectRootFile = "pkgs/by-name/gh/gh-token-manager/package.nix";

  programs = {
    deadnix.enable = true;
    nixf-diagnose.enable = true;
    nixfmt = {
      enable = true;
      strict = true;
    };
    rumdl-check.enable = true;
    rumdl-format.enable = true;
    rustfmt = {
      enable = true;
      edition = "2024";
    };
    statix.enable = true;
  };

  settings.global.excludes = [ "*.lock" ];
}
