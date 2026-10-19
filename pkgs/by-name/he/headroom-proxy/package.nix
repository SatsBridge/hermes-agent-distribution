{
  pkgs,
  unstable,
  headroomSource ? import ./headroom-source.nix { inherit pkgs; },
  lib ? unstable.lib,
  rustPlatform ? unstable.rustPlatform,
  pkg-config ? unstable.pkg-config,
  cmake ? unstable.cmake,
  perl ? unstable.perl,
  makeWrapper ? unstable.makeWrapper,
  clippy ? unstable.clippy,
  python3 ? unstable.python3,
  onnxruntime ? unstable.onnxruntime,
  stdenv ? unstable.stdenv,
  libiconv ? unstable.libiconv,
}:

unstable.callPackage ./proxy.nix {
  inherit
    lib
    rustPlatform
    pkg-config
    cmake
    perl
    makeWrapper
    clippy
    python3
    onnxruntime
    stdenv
    libiconv
    headroomSource
    ;
}
