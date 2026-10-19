# treefmt-nix configuration shared by `nix fmt`, the treefmt git hook, and the
# devShell. Every formatter listed in the packaging brief is enabled here.
_: {
  projectRootFile = "pkgs/by-name/he/headroom-py/package.nix";

  programs = {
    # Nix
    nixfmt = {
      enable = true;
      strict = true;
    };
    deadnix.enable = true;
    statix.enable = true;
    nixf-diagnose.enable = true;

    # Markdown
    rumdl-check.enable = true;
    rumdl-format.enable = true;
  };

  settings.global.excludes = [
    # Lockfiles and generated data — never hand-formatted.
    "*.lock"
  ];
}
