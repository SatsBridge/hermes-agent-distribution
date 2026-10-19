_: {
  projectRootFile = "pkgs/by-name/gh/gh-token-manager/package.nix";

  programs.nixfmt.enable = true;
  programs.rustfmt = {
    enable = true;
    edition = "2024";
  };
}
