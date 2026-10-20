{ applyPatches, fetchFromGitHub }:
let
  src = applyPatches {
    name = "headroom-${version}-source-patched";
    patches = [
      ./patches/0001-hermeticize-upstream-tests.patch
      ./patches/0002-import-cli-command-unambiguously.patch
    ];
    src = fetchFromGitHub {
      hash = "sha256-ITVrw5ruGnNI9t7pq+0Z6gsnqDDAB/5v7I3oOQM5AtE=";
      owner = "headroomlabs-ai";
      repo = "headroom";
      rev = "76133cff59b71284399bf760c5578dc373c97231";
    };
    inherit version;
  };
  version = "0.41.0";
in
src
