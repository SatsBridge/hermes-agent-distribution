{
  pkgs,
  unstable,
  headroom-proxy,
  headroomSource ? headroom-proxy.passthru.headroomSource,
  python3Packages ? import ./headroom-python.nix { inherit pkgs unstable; },
  lib ? unstable.lib,
  writeText ? unstable.writeText,
  rustPlatform ? unstable.rustPlatform,
  pkg-config ? unstable.pkg-config,
  cmake ? unstable.cmake,
  perl ? unstable.perl,
  onnxruntime ? unstable.onnxruntime,
  stdenv ? unstable.stdenv,
}:

unstable.callPackage ./headroom-py.nix {
  inherit
    lib
    writeText
    rustPlatform
    pkg-config
    cmake
    perl
    onnxruntime
    stdenv
    ;
  inherit headroomSource python3Packages;
}
