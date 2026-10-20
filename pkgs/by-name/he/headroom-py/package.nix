# headroom-py: the compiled Rust extension `headroom._core` as a standalone
# Python package.
#
# maturin's `python-source = "."` makes the wheel carry the *entire* pure-Python
# `headroom/` tree (407 files, ~42 MB of templates/configs) alongside the
# compiled `_core.abi3.so`. That pure-Python code, and the runtime dependencies
# it imports, belong to the `headroom` package — not here. So this build keeps
# only the load-bearing artifact: the `.so`. Stripped to just `_core`, it needs
# no runtime dependencies and no `pythonRelaxDeps`/`pythonRemoveDeps` fix-ups.
#
# The point of the split is caching: the slow Rust compile lands in this small,
# self-contained derivation, and `pkgs/by-name/he/headroom/package.nix` copies
# the `.so` out of it
# instead of recompiling.
{
  cmake,
  gitHooks,
  headroom-python-pkgs,
  headroom-source,
  lib,
  mkShell,
  onnxruntime,
  perl,
  pkg-config,
  prek,
  rustPlatform,
  stdenv,
  treefmtEval,
  writeText,
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
  ortDylib = "${onnxruntime}/lib/libonnxruntime${stdenv.hostPlatform.extensions.sharedLibrary}";

  # Load the stripped extension by file path (the `headroom` package it lived in
  # is gone) and confirm it initialises — the moral equivalent of
  # pythonImportsCheck for a bare `.so`.
  loadCheck = writeText "headroom-py-load-check.py" ''
    import importlib.util
    import sys

    spec = importlib.util.spec_from_file_location("_core", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    print("headroom-py: _core loads OK")
  '';

  headroom-py = headroom-python-pkgs.buildPythonPackage {
    pname = "headroom-py";
    inherit (headroom-source) version;
    pyproject = true;
    inherit (headroom-source) src;

    nativeBuildInputs = builtins.attrValues {
      inherit (rustPlatform) cargoSetupHook maturinBuildHook;
      inherit cmake perl pkg-config;
    };

    # Reproducible Cargo vendoring from the committed lockfile.
    cargoDeps = rustPlatform.importCargoLock { lockFile = "${headroom-source.src}/Cargo.lock"; };

    # ONNX Runtime that fastembed (linked into _core) dlopens at runtime.
    buildInputs = [ onnxruntime ];

    # _core dlopens libonnxruntime; make it resolvable at build and check time.
    env.ORT_DYLIB_PATH = ortDylib;

    # cmake is present for aws-lc-rs/rusqlite codegen only; there is no
    # CMakeLists.txt to configure.
    dontUseCmakeConfigure = true;

    # Discard everything the wheel installed except the compiled extension. What
    # remains is `<site-packages>/headroom/_core.abi3.so` and nothing else, so no
    # pure-Python module here can pull in a runtime dependency. Run in postFixup,
    # after the bin-wrapping hooks, so the now-dangling `bin/headroom` wrapper
    # (its Python code is gone) is removed too.
    postFixup = ''
      rm -rf "$out/bin"
      find "$out/lib" -depth -mindepth 1 \
        ! -path "*/headroom" \
        ! -path "*/headroom/_core*.so" \
        -delete 2>/dev/null || true
    '';

    # The stripped package has no importable `headroom` package (its __init__ was
    # removed), so a plain `pythonImportsCheck` would fail. Verify the extension
    # is present and dynamically loadable instead.
    doCheck = false;
    dontCheckPythonMetadata = true; # The wheel's distribution name is headroom-ai.
    dontCheckRuntimeDeps = true;
    installCheckPhase = ''
      runHook preInstallCheck
      so=$(find "$out" -name '_core*.so' -print -quit)
      test -n "$so"
      ${headroom-python-pkgs.python.interpreter} ${loadCheck} "$so"
      runHook postInstallCheck
    '';

    # The compiled extension's filename, so `headroom/package.nix` can copy it into the
    # full package's tree without hunting for it.
    passthru = {
      coreLib = "_core.abi3.so";
      inherit devShell git-hooks treefmt;
    };

    meta = {
      description = "Headroom compiled Rust core (headroom._core) as a Python distribution";
      homepage = "https://github.com/headroomlabs-ai/headroom";
      platforms = lib.platforms.unix;
    };
  };

  devShell = mkShell {
    inputsFrom = [ headroom-py ];
    packages = git-hooks.enabledPackages ++ [ treefmt.config.build.wrapper ];
    inherit (git-hooks) shellHook;
  };
in
headroom-py
