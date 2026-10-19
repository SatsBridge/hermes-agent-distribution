{
  lib,
  writeText,
  python3Packages,
  rustPlatform,
  pkg-config,
  cmake,
  perl,
  onnxruntime,
  stdenv,
  headroomSource,
}:

import ./headroom-py.nix {
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
