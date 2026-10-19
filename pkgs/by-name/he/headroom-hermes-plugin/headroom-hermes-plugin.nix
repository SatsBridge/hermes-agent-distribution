# headroom-hermes-plugin: the Hermes-Agent CCR retrieve plugin that lives at
# plugins/hermes in the Headroom tree.
#
# It is not a PyPI distribution — it is a Hermes *user plugin*: a directory
# (headroom_retrieve/) that a user drops into ~/.hermes/plugins/ and enables in
# config.yaml. So this package just installs that directory verbatim under
# share/hermes/plugins/, with a wrapper env exposing httpx (its only third-party
# import; `tools.registry` is provided by the Hermes runtime that loads it).
{
  stdenvNoCC,
  lib,
  python3Packages,
  writeText,
  headroomSource,
}:
let
  inherit (python3Packages) python;
  # The Python environment the Hermes host loads the plugin under: it must carry
  # httpx (the plugin's only third-party import). Bound here so the same
  # interpreter both backs propagatedBuildInputs and drives the install check.
  pluginPython = python.withPackages (ps: [ ps.httpx ]);

  # Install-check interpreter: the runtime env plus pyyaml (to read plugin.yaml)
  # for the structural verification. Kept separate from propagatedBuildInputs so
  # pyyaml is a test-only input, never leaked onto the plugin's runtime path.
  checkPython = python.withPackages (ps: builtins.attrValues { inherit (ps) httpx pyyaml; });

  # tools.registry is provided by the Hermes runtime that loads the plugin. This
  # stub stands in for it during the install check so the module imports without
  # a live host; it is a test fixture, never installed.
  toolsRegistryStub = writeText "tools-registry-stub.py" ''
    def tool_error(msg):
        return {"error": msg}


    def tool_result(data):
        return {"result": data}
  '';

  # Structural verification of the installed plugin — the "tests" for a
  # copy-only component. Passed HEADROOM_PLUGIN_DIR by the install check.
  verifyScript = writeText "verify-headroom-hermes-plugin.py" ''
    import os
    import pathlib

    import yaml

    import headroom_retrieve as hr

    plugindir = pathlib.Path(hr.__file__).parent

    manifest = yaml.safe_load((plugindir / "plugin.yaml").read_text())
    assert manifest["name"] == "headroom_retrieve", manifest
    assert "headroom_retrieve" in manifest["provides_tools"], manifest

    assert callable(hr.register), "register() missing"
    assert callable(hr._handle_headroom_retrieve), "handler missing"
    assert (
        hr.HEADROOM_RETRIEVE_SCHEMA["name"] == "headroom_retrieve"
    ), hr.HEADROOM_RETRIEVE_SCHEMA

    # register(ctx) must register a tool named headroom_retrieve with a handler.
    captured = {}


    class _Ctx:
        def register_tool(self, **kw):
            captured.update(kw)


    hr.register(_Ctx())
    assert captured.get("name") == "headroom_retrieve", captured
    assert callable(captured.get("handler")), captured
    print("headroom-hermes-plugin: public surface OK")
  '';
in
stdenvNoCC.mkDerivation {
  pname = "headroom-hermes-plugin";
  inherit (headroomSource) version;
  inherit (headroomSource) src;

  # Bring httpx onto PYTHONPATH via a .pth-free wrapper: the plugin is imported
  # by the Hermes process, so record the dependency in passthru and expose a
  # ready-to-use PYTHONPATH fragment consumers can source.
  propagatedBuildInputs = [ pluginPython ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dest="$out/share/hermes/plugins"
    mkdir -p "$dest"
    cp -r plugins/hermes/headroom_retrieve "$dest/"
    # A README next to the plugin so `nix run`/manual installers find the
    # enable instructions without going back to the source tree.
    install -Dm644 plugins/hermes/README.md "$out/share/doc/headroom-hermes-plugin/README.md"
    runHook postInstall
  '';

  # The plugin ships no test suite of its own (it is a copy-only directory), so
  # the "tests" for this component are structural verification against the
  # installed tree — the same guarantees a maturin `pythonImportsCheck` gives a
  # wheel, adapted to a host-loaded plugin:
  #   1. every .py file byte-compiles (catches syntax errors the copy would
  #      otherwise ship silently),
  #   2. httpx — the plugin's sole third-party import — resolves from the
  #      propagated environment,
  #   3. the plugin's public surface is intact: plugin.yaml declares the
  #      headroom_retrieve tool, and the module exposes register()/the handler/
  #      the schema once `tools.registry` (host-provided) is stubbed in.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ checkPython ];
  installCheckPhase = ''
    runHook preInstallCheck

    plugindir="$out/share/hermes/plugins/headroom_retrieve"

    echo "checking installed layout"
    test -f "$plugindir/__init__.py"
    test -f "$plugindir/plugin.yaml"
    test -f "$out/share/doc/headroom-hermes-plugin/README.md"

    echo "byte-compiling the plugin (syntax check)"
    ${checkPython.interpreter} -m compileall -q "$plugindir"

    echo "checking httpx resolves from the propagated environment"
    ${pluginPython.interpreter} -c 'import httpx'

    echo "checking the plugin's public surface (with a tools.registry stub)"
    stubdir="$(mktemp -d)"
    mkdir -p "$stubdir/tools"
    : > "$stubdir/tools/__init__.py"
    cp ${toolsRegistryStub} "$stubdir/tools/registry.py"
    # The plugin dir goes on the path so `headroom_retrieve` imports as a
    # top-level package, matching how the Hermes loader imports it.
    PYTHONPATH="$stubdir:$out/share/hermes/plugins''${PYTHONPATH:+:$PYTHONPATH}" \
      ${checkPython.interpreter} ${verifyScript}

    runHook postInstallCheck
  '';

  meta = {
    description = "Hermes-Agent CCR retrieve plugin for the Headroom proxy";
    homepage = "https://github.com/headroomlabs-ai/headroom";
    platforms = lib.platforms.all;
  };
}
