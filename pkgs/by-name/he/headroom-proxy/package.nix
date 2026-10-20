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
  clippy,
  cmake,
  gitHooks,
  headroom-source,
  lib,
  libiconv,
  makeWrapper,
  mkShell,
  onnxruntime,
  perl,
  pkg-config,
  prek,
  python3,
  rustPlatform,
  stdenv,
  treefmtEval,
}:
let
  # ONNX Runtime shared library that `ort` dlopens at runtime (load-dynamic;
  # see patches/0001). Wired at build, test, and run time.
  ortDylib = "${lib.getLib onnxruntime}/lib/libonnxruntime${stdenv.hostPlatform.extensions.sharedLibrary}";

  commonArgs = {
    pname = "headroom-proxy";
    inherit (headroom-source) version;
    inherit (headroom-source) src;
    cargoLock = {
      lockFile = "${headroom-source.src}/Cargo.lock";
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

    # `e2e_real` spawns the Python proxy and hits live provider APIs; it
    # self-skips without HEADROOM_E2E=1 but is excluded here so the target is
    # not even considered. Every hermetic wiremock-backed integration test in
    # the crate still runs.
    checkFlags = [ "--skip=e2e_real" ];

  };
  headroom-proxy = rustPlatform.buildRustPackage (
    commonArgs
    // {
      nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ makeWrapper ];

      # Wrap the binary so it always finds libonnxruntime regardless of the
      # caller's environment.
      postInstall = ''
        wrapProgram $out/bin/headroom-proxy \
          --set-default ORT_DYLIB_PATH "${ortDylib}"
        ${python3}/bin/python3 -c 'import ctypes; ctypes.CDLL("${ortDylib}")'
      '';

      passthru = {
        inherit
          clippy
          devShell
          git-hooks
          treefmt
          ;
      };

      meta = {
        description = "Headroom transparent reverse proxy (Rust, axum)";
        homepage = "https://github.com/headroomlabs-ai/headroom";
        mainProgram = "headroom-proxy";
        platforms = lib.platforms.unix;
      };
    }
  );

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

  devShell = mkShell {
    inputsFrom = [ headroom-proxy ];
    packages = git-hooks.enabledPackages ++ [ treefmt.config.build.wrapper ];
    inherit (git-hooks) shellHook;
  };
in
headroom-proxy
