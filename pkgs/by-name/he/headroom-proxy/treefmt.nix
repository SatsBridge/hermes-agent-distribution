_: {
  projectRootFile = "pkgs/by-name/he/headroom-proxy/package.nix";
  programs = {
    nixfmt = {
      enable = true;
      strict = true;
    };
    deadnix.enable = true;
    statix.enable = true;
    nixf-diagnose.enable = true;
    rumdl-check.enable = true;
    rumdl-format.enable = true;
  };
  settings.global.excludes = [ "*.lock" ];
}
