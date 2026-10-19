{ pkgs, headroom-proxy, ... }:

pkgs.callPackage ./headroom-hermes-plugin.nix {
  headroomSource = headroom-proxy.passthru.headroomSource;
}
