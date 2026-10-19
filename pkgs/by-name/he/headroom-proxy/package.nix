{
  pkgs,
  unstable,
  onnxruntime,
  ...
}:

unstable.callPackage ./proxy.nix {
  headroomSource = import ./headroom-source.nix { inherit pkgs; };
  inherit onnxruntime;
}
