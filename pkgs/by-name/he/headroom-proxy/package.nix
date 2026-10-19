# headroom-proxy: the Rust reverse-proxy binary.
#
# Built with `rustPlatform.buildRustPackage` (no crane): the workspace vendors
# cleanly from the committed Cargo.lock and only the proxy binary crate is
# needed, so the stock nixpkgs Rust platform is enough. `buildAndTestSubdir`
# scopes the build/test to `crates/headroom-proxy` (the workspace also holds the
# headroom-py cdylib, which must go through maturin, plus core/parity).
#
# The clippy lint is exposed via `passthru.clippy` for the flake's checks.
{
  lib,
  rustPlatform,
  pkg-config,
  cmake,
  perl,
  makeWrapper,
  clippy,
  python3,
  onnxruntime,
  stdenv,
  libiconv,
  headroomSource,
  gitHooks,
  treefmtEval,
  mkShell,
  prek,
}:
let
  treefmt = treefmtEval ./treefmt.nix;
  git-hooks = gitHooks.run {
    src = ./.;
    rootSrc = lib.mkForce ../../../..;
    package = prek;
    hooks.treefmt = {
      enable = true;
      package = treefmt.config.build.wrapper;
      settings.fail-on-change = true;
    };
  };
  # ONNX Runtime shared library that `ort` dlopens at runtime (load-dynamic;
  # see patches/0001). Wired at build, test, and run time.
  ortDylib = "${lib.getLib onnxruntime}/lib/libonnxruntime${stdenv.hostPlatform.extensions.sharedLibrary}";

  commonArgs = {
    pname = "headroom-proxy";
    inherit (headroomSource) version;
    inherit (headroomSource) src;

    cargoLock = {
      lockFile = "${headroomSource.src}/Cargo.lock";
    };

    buildAndTestSubdir = "crates/headroom-proxy";
    checkType = "debug";

    strictDeps = true;

    nativeBuildInputs = [
      pkg-config
      cmake # aws-lc-rs / rusqlite build tooling
      perl # aws-lc-rs codegen
    ];

    buildInputs = [ onnxruntime ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ libiconv ];

    # cmake is only present for aws-lc-rs/rusqlite codegen; the crate has no
    # CMakeLists.txt, so stop the cmake hook from trying to configure one.
    dontUseCmakeConfigure = true;

    # ort load-dynamic: resolve libonnxruntime without a network fetch.
    env.ORT_DYLIB_PATH = ortDylib;
  };

  clippyCheck = rustPlatform.buildRustPackage (
    commonArgs
    // {
      pname = "headroom-proxy-clippy";
      nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ clippy ];
      buildPhase = ''
        runHook preBuild
        cargo clippy --release -p headroom-proxy --all-targets -- --deny warnings
        runHook postBuild
      '';
      doCheck = false;
      installPhase = "touch $out";
    }
  );
  headroom-proxy = rustPlatform.buildRustPackage (
    commonArgs
    // {
      nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ makeWrapper ];

      # `e2e_real` spawns the Python proxy and hits live provider APIs; it
      # self-skips without HEADROOM_E2E=1 but is excluded here so the target is
      # not even considered. Every hermetic wiremock-backed integration test in
      # the crate still runs.
      checkFlags = [ "--skip=e2e_real" ];

      # Wrap the binary so it always finds libonnxruntime regardless of the
      # caller's environment.
      postInstall = ''
        wrapProgram $out/bin/headroom-proxy \
          --set-default ORT_DYLIB_PATH "${ortDylib}"
        ${python3}/bin/python3 -c 'import ctypes; ctypes.CDLL("${ortDylib}")'
      '';

      passthru = {
        inherit headroomSource;
        clippy = clippyCheck;
        inherit treefmt git-hooks devShell;
      };

      meta = {
        description = "Headroom transparent reverse proxy (Rust, axum)";
        homepage = "https://github.com/headroomlabs-ai/headroom";
        mainProgram = "headroom-proxy";
        platforms = lib.platforms.unix;
      };
    }
  );
  devShell = mkShell {
    inputsFrom = [ headroom-proxy ];
    packages = git-hooks.enabledPackages ++ [ treefmt.config.build.wrapper ];
    inherit (git-hooks) shellHook;
  };
in
headroom-proxy
