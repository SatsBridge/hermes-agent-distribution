_: {
  projectRootFile = "pkgs/by-name/gh/gh-token-manager/package.nix";

  programs = {
    # Nix
    nixfmt = {
      enable = true;
      strict = true;
    };
    deadnix.enable = true;
    statix.enable = true;
    nixf-diagnose.enable = true;

    # Rust
    rustfmt = {
      enable = true;
      edition = "2024";
    };

    # Markdown
    rumdl-check.enable = true;
    rumdl-format.enable = true;
  };
}
