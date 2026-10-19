{
  pkgs,
  ghTokenManagerPackage,
  coveragePkgs,
  gitHooks,
}:
let
  package = ghTokenManagerPackage;
  coverage = coveragePkgs.rustPlatform.buildRustPackage {
    pname = "gh-token-manager-coverage";
    version = "0.1.0";
    src = ../pkgs/by-name/gh/gh-token-manager;
    cargoLock.lockFile = ../pkgs/by-name/gh/gh-token-manager/Cargo.lock;
    doCheck = false;
    nativeBuildInputs = [
      coveragePkgs.cacert
      coveragePkgs.cargo-llvm-cov
      coveragePkgs.llvmPackages.llvm
      coveragePkgs.python3
    ];
    LLVM_COV = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-cov";
    LLVM_PROFDATA = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-profdata";
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
  pre-commit-check = gitHooks.run {
    src = ./.;
    rootSrc = pkgs.lib.mkForce (
      pkgs.runCommand "gh-token-manager-hook-source" { } ''
        mkdir -p "$out"
        cp -r ${../.}/. "$out/"
        cp ${../pkgs/by-name/gh/gh-token-manager/Cargo.lock} "$out/Cargo.lock"
      ''
    );
    package = pkgs.prek;
    settings.rust = {
      cargoManifestPath = "pkgs/by-name/gh/gh-token-manager/Cargo.toml";
      check.cargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../pkgs/by-name/gh/gh-token-manager/Cargo.lock;
      };
    };
    hooks.clippy = {
      enable = true;
      packageOverrides = {
        inherit (pkgs) cargo clippy;
      };
      settings = {
        denyWarnings = true;
        offline = false;
      };
    };
  };
  devShell =
    let
      tools = builtins.attrValues {
        inherit (pkgs)
          cargo
          rustc
          clippy
          rustfmt
          cacert
          ;
      };
    in
    pkgs.mkShell {
      packages =
        tools
        ++ [
          coveragePkgs.cargo-llvm-cov
          coveragePkgs.llvmPackages.llvm
          coveragePkgs.python3
        ]
        ++ pre-commit-check.enabledPackages;
      LLVM_COV = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-cov";
      LLVM_PROFDATA = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-profdata";
      shellHook = pre-commit-check.shellHook;
    };
in
{
  inherit package coverage devShell;
  pre-commit-check = pre-commit-check;
}
