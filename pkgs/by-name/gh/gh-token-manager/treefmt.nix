_: {

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
      edition = "2024";
      enable = true;
    };
    statix.enable = true;
  };
  projectRootFile = "pkgs/by-name/gh/gh-token-manager/package.nix";

  settings.global.excludes = [ "*.lock" ];
}
