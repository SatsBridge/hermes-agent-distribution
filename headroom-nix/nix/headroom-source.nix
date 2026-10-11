# Headroom upstream source, pinned to release v0.40.0 and fetched
# with fetchFromGitHub — the pin lives here, not in a flake input, so consumer
# flakes that depend on this one never inherit a Headroom input.
{ pkgs }:
let
  rev = "855390d6110e0bbb199d9b97025baac16c2f5cf3"; # tag v0.40.0
  version = "0.40.0";

  raw = pkgs.fetchFromGitHub {
    owner = "headroomlabs-ai";
    repo = "headroom";
    inherit rev;
    hash = "sha256-5tNeUVybEXufNiQ0Qa28U1mY5nil6sYFy5/UKb/BACQ=";
  };

in
{
  src = raw;
  inherit version rev;
}
