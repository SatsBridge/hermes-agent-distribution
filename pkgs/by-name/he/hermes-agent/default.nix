{
  pkgs,
  perSystem,
  flake,
  ...
}:
pkgs.callPackage ./package.nix {
  inherit flake;
  inherit (pkgs) python3;
  inherit (perSystem.self) versionCheckHomeHook;
}
