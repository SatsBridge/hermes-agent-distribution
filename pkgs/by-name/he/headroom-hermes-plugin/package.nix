{
  pkgs,
  headroom-proxy,
  headroomSource ? headroom-proxy.passthru.headroomSource,
  stdenvNoCC ? pkgs.stdenvNoCC,
  lib ? pkgs.lib,
  python3Packages ? pkgs.python3Packages,
  writeText ? pkgs.writeText,
}:

pkgs.callPackage ./headroom-hermes-plugin.nix {
  inherit
    stdenvNoCC
    lib
    python3Packages
    writeText
    headroomSource
    ;
}
