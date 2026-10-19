{ applyPatches, fetchFromGitHub }:
let
  version = "0.41.0";
  src = applyPatches {
    name = "headroom-${version}-source-patched";
    inherit version;
    src = fetchFromGitHub {
      owner = "headroomlabs-ai";
      repo = "headroom";
      rev = "76133cff59b71284399bf760c5578dc373c97231";
      hash = "sha256-ITVrw5ruGnNI9t7pq+0Z6gsnqDDAB/5v7I3oOQM5AtE=";
    };
    patches = [
      ./patches/0001-hermeticize-upstream-tests.patch
      ./patches/0002-import-cli-command-unambiguously.patch
    ];
  };
in
src
