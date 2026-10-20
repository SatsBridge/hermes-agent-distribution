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
    statix.enable = true;
  };
  projectRootFile = "pkgs/by-name/he/headroom-py/package.nix";
  settings.global.excludes = [ "*.lock" ];
}
