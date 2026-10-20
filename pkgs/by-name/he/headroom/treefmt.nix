_: {
  projectRootFile = "pkgs/by-name/he/headroom/package.nix";
  programs = {
    deadnix.enable = true;
    nixf-diagnose.enable = true;
    nixfmt = {
      enable = true;
      strict = true;
    };
    rumdl-check.enable = true;
    rumdl-format.enable = true;
    statix.enable = true;
  };
  settings.global.excludes = [ "*.lock" ];
}
