{
  lib,
  stdenvNoCC,
  python3Packages,
  writeText,
  headroomSource,
}:

import ./headroom-hermes-plugin.nix {
  inherit
    stdenvNoCC
    lib
    python3Packages
    writeText
    headroomSource
    ;
}
