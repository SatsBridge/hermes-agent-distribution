{
  rustPlatform,
  cacert,
  coverageRustPlatform,
  coverageCacert,
  cargo-llvm-cov,
  llvm,
  coveragePython,
  gitHooks,
  treefmtEval,
  runCommand,
  lib,
  prek,
  cargo,
  rustc,
  clippy,
  rustfmt,
  mkShell,
}:
let
  version = "0.1.0";
  treefmt = treefmtEval ./treefmt.nix;
  coverage = coverageRustPlatform.buildRustPackage {
    pname = "gh-token-manager-coverage";
    inherit version;
    src = ./.;
    cargoLock.lockFile = ./Cargo.lock;
    doCheck = false;
    nativeBuildInputs = [
      coverageCacert
      cargo-llvm-cov
      llvm
      coveragePython
    ];
    LLVM_COV = "${llvm}/bin/llvm-cov";
    LLVM_PROFDATA = "${llvm}/bin/llvm-profdata";
    RUSTC_BOOTSTRAP = "1";
    postBuild = ''
      mkdir -p coverage
      cargo llvm-cov --manifest-path Cargo.toml --offline --branch --json \
        --output-path coverage/report.json
      python3 check_coverage.py coverage/report.json
    '';
    installPhase = ''
      mkdir -p "$out"
      cp coverage/report.json "$out/coverage.json"
    '';
  };
  git-hooks = gitHooks.run {
    src = ./.;
    rootSrc = lib.mkForce (
      runCommand "gh-token-manager-hook-source" { } ''
        mkdir -p "$out"
        cp -r ${../../../..}/. "$out/"
        cp ${./Cargo.lock} "$out/Cargo.lock"
      ''
    );
    package = prek;
    settings.rust = {
      cargoManifestPath = "pkgs/by-name/gh/gh-token-manager/Cargo.toml";
      check.cargoDeps = rustPlatform.importCargoLock {
        lockFile = ./Cargo.lock;
      };
    };
    hooks.clippy = {
      enable = true;
      packageOverrides = {
        inherit cargo clippy;
      };
      settings = {
        denyWarnings = true;
        offline = false;
      };
    };
    hooks.treefmt = {
      enable = true;
      package = treefmt.config.build.wrapper;
      settings.fail-on-change = true;
    };
  };
  devShell = mkShell {
    packages = [
      cargo
      rustc
      clippy
      rustfmt
      cacert
      cargo-llvm-cov
      llvm
      coveragePython
    ]
    ++ git-hooks.enabledPackages
    ++ [ treefmt.config.build.wrapper ];
    LLVM_COV = "${llvm}/bin/llvm-cov";
    LLVM_PROFDATA = "${llvm}/bin/llvm-profdata";
    shellHook = git-hooks.shellHook;
  };
in
rustPlatform.buildRustPackage {
  pname = "gh-token-manager";
  inherit version;
  src = ./.;
  nativeBuildInputs = [ cacert ];
  cargoLock.lockFile = ./Cargo.lock;
  passthru = {
    inherit
      coverage
      git-hooks
      treefmt
      devShell
      ;
  };
}
