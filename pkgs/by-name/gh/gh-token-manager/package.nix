{
  rustPlatform,
  cacert,
}:
rustPlatform.buildRustPackage {
  pname = "gh-token-manager";
  version = "0.1.0";
  src = ../../../../gh-token-manager;
  nativeBuildInputs = [ cacert ];
  cargoLock.lockFile = ../../../../gh-token-manager/Cargo.lock;
}
