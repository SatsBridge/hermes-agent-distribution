{
  pkgs,
  unstable,
  headroom-proxy,
  headroom-py,
  codebaseMemoryMcp,
  headroomSource ? headroom-proxy.passthru.headroomSource,
  python3Packages ? headroom-py.passthru.python3Packages,
  rtk ? unstable.rtk,
  onnxruntime ? unstable.onnxruntime,
  lib ? pkgs.lib,
  stdenv ? pkgs.stdenv,
  makeWrapper ? pkgs.makeWrapper,
  writeText ? pkgs.writeText,
  fetchurl ? pkgs.fetchurl,
  runCommand ? pkgs.runCommand,
  cacert ? pkgs.cacert,
  ast-grep ? pkgs.ast-grep,
  difftastic ? pkgs.difftastic,
  scc ? pkgs.scc,
  git ? pkgs.git,
}:

pkgs.callPackage ./headroom.nix {
  inherit
    lib
    stdenv
    python3Packages
    makeWrapper
    writeText
    fetchurl
    runCommand
    cacert
    onnxruntime
    ast-grep
    difftastic
    scc
    git
    headroomSource
    headroom-py
    headroom-proxy
    rtk
    codebaseMemoryMcp
    ;
}
