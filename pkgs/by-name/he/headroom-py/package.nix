{
  pkgs,
  unstable,
  headroom-proxy,
  onnxruntime,
  ...
}:

unstable.callPackage ./headroom-py.nix {
  headroomSource = headroom-proxy.passthru.headroomSource;
  python3Packages = import ./headroom-python.nix { inherit pkgs unstable; };
  inherit onnxruntime;
}
