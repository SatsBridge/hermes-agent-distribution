# Headroom upstream source, pinned to the latest release (v0.30.0) and fetched
# with fetchFromGitHub — the pin lives here, not in a flake input, so consumer
# flakes that depend on this one never inherit a Headroom input.
#
# `applyPatches` layers the surgical patches (see nix/patches/) onto the raw
# tree; both the Rust and Python builds consume the patched result.
{ pkgs }:
let
  rev = "728b33088b25c390d9b06082afab058e1dc7f028"; # tag v0.30.0
  version = "0.30.0";

  raw = pkgs.fetchFromGitHub {
    owner = "headroomlabs-ai";
    repo = "headroom";
    inherit rev;
    hash = "sha256-BxZq6UzmLae7eNrE7iUuunM3hRM4E41i4j6LsKFyFdk=";
  };

  src = pkgs.applyPatches {
    name = "headroom-src-${version}-patched";
    src = raw;
    patches = [ ./patches/0001-core-ort-load-dynamic.patch ];
  };
in
{
  inherit src version rev;
}
