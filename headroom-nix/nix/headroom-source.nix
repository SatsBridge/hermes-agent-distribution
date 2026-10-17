# Headroom upstream source, pinned to release v0.41.0 and fetched
# with fetchFromGitHub — the pin lives here, not in a flake input, so consumer
# flakes that depend on this one never inherit a Headroom input.
{ pkgs }:
let
  rev = "76133cff59b71284399bf760c5578dc373c97231"; # tag v0.41.0
  version = "0.41.0";

  raw = pkgs.fetchFromGitHub {
    owner = "headroomlabs-ai";
    repo = "headroom";
    inherit rev;
    hash = "sha256-ITVrw5ruGnNI9t7pq+0Z6gsnqDDAB/5v7I3oOQM5AtE=";
  };

in
{
  src = raw;
  inherit version rev;
}
