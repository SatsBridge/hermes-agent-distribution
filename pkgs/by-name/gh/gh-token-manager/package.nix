{
  cacert,
  cargo,
  cargo-llvm-cov,
  clippy,
  gitHooks,
  lib,
  llvm,
  mkShell,
  prek,
  python3,
  runCommand,
  rustPlatform,
  rustc,
  rustfmt,
  treefmtEval,
}:
let
  coverage = rustPlatform.buildRustPackage {
    cargoLock.lockFile = ./Cargo.lock;
    doCheck = false;
    inherit version;
    installPhase = ''
      mkdir -p "$out"
      cp coverage/report.json "$out/coverage.json"
    '';
    LLVM_COV = "${llvm}/bin/llvm-cov";
    LLVM_PROFDATA = "${llvm}/bin/llvm-profdata";
    nativeBuildInputs = [
      cacert
      cargo-llvm-cov
      llvm
      python3
    ];
    pname = "gh-token-manager-coverage";
    postBuild = ''
      mkdir -p coverage
      cargo llvm-cov --manifest-path Cargo.toml --offline --branch --json \
        --output-path coverage/report.json
      python3 check_coverage.py coverage/report.json
    '';
    RUSTC_BOOTSTRAP = "1";
    src = ./.;
  };
  devShell = mkShell {
    LLVM_COV = "${llvm}/bin/llvm-cov";
    LLVM_PROFDATA = "${llvm}/bin/llvm-profdata";
    packages = [
      cargo
      rustc
      clippy
      rustfmt
      cacert
      cargo-llvm-cov
      llvm
      python3
    ]
    ++ git-hooks.enabledPackages
    ++ [ treefmt.config.build.wrapper ];
    inherit (git-hooks) shellHook;
  };
  git-hooks = gitHooks.run {
    hooks = {
      clippy = {
        enable = true;
        packageOverrides = { inherit cargo clippy; };
        settings = {
          denyWarnings = true;
          offline = false;
        };
      };
      treefmt = {
        enable = true;
        package = treefmt.config.build.wrapper;
        settings.fail-on-change = true;
      };
    };
    package = prek;
    rootSrc = lib.mkForce (
      runCommand "gh-token-manager-hook-source" { } ''
        mkdir -p "$out"
        cp -r ${../../../..}/. "$out/"
        cp ${./Cargo.lock} "$out/Cargo.lock"
      ''
    );
    settings.rust = {
      cargoManifestPath = "pkgs/by-name/gh/gh-token-manager/Cargo.toml";
      check.cargoDeps = rustPlatform.importCargoLock { lockFile = ./Cargo.lock; };
    };
    src = ./.;
  };
  treefmt = treefmtEval ./treefmt.nix;
  version = "0.1.0";
in
rustPlatform.buildRustPackage {
  cargoLock.lockFile = ./Cargo.lock;
  inherit version;
  nativeBuildInputs = [ cacert ];
  passthru = {
    inherit
      coverage
      devShell
      git-hooks
      treefmt
      ;
  };
  pname = "gh-token-manager";
  src = ./.;
}
