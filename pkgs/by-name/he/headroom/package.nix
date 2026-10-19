{
  pkgs,
  headroom-proxy,
  headroom-py,
  codebaseMemoryMcp,
  onnxruntime,
  rtk,
  ...
}:

pkgs.callPackage ./headroom.nix {
  headroomSource = headroom-proxy.passthru.headroomSource;
  python3Packages = headroom-py.passthru.python3Packages;
  inherit headroom-py headroom-proxy codebaseMemoryMcp;
  inherit onnxruntime rtk;
}
