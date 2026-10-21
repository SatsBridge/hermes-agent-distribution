{
  agent-browser,
  buildNpmPackage,
  # replace to https://github.com/arman-bd/chromiumfish
  # or https://github.com/clearcotelabs/clearcote-browser
  chromium,
  cosign,
  fetchFromGitHub,
  fetchPypi,
  gh,
  gitHooks,
  lib,
  mkShell,
  mnemosyne,
  nodejs,
  olm,
  playwright,
  prek,
  python3,
  rustPlatform,
  stdenv,
  tirith,
  treefmtEval,
  versionCheckHook,
  writeText,
}:

let

  # Upstream pins agent-client-protocol==0.9.0; nixpkgs' 0.11.x regenerated the
  # ACP schema and dropped ModelInfo/SetSessionModelResponse/SessionModelState,
  # which acp_adapter still imports, so hermes-acp fails at startup (#7650).
  agent-client-protocol' = python3.pkgs.agent-client-protocol.overridePythonAttrs (old: {
    # 0.9.0 predates the tests/http suite that nixpkgs' expression disables.
    disabledTestPaths = [ ];
    disabledTests = (old.disabledTests or [ ]) ++ [
      # subprocess spawn exceeds the 2s timeout in the sandbox
      "test_run_agent_stdio_buffer_limit"
    ];
    src = old.src.override {
      hash = "sha256-8Xf2S85yNsP/HhpCw9UqdoDdeDHdggvYcnvJbilAVuU=";
      tag = "0.9.0";
    };
    version = "0.9.0";
  });

  browser-harness = python3.pkgs.buildPythonPackage rec {

    build-system = [ python3.pkgs.setuptools ];

    dependencies = [
      cdp-use
      fetch-use
      python3.pkgs.pillow
      python3.pkgs.websockets
    ];

    meta = with lib; {
      description = "Harness that lets agents drive a browser over CDP";
      homepage = "https://github.com/browser-use/browser-harness";
      license = licenses.mit;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    pname = "browser-harness";

    # Upstream pins setuptools==84.0.0 in build-system.requires.
    pypaBuildFlags = [ "--skip-dependency-check" ];
    pyproject = true;

    pythonImportsCheck = [ "browser_harness" ];

    pythonRelaxDeps = [
      "pillow"
      "websockets"
    ];

    src = fetchPypi {
      hash = "sha256-KE3FR6BCwwn+r9mp9KdLKoZRt5Y+o6xssvLWSIn2qPM=";
      pname = "browser_harness";
      inherit version;
    };
    version = "0.1.13";
  };

  cdp-use = python3.pkgs.buildPythonPackage rec {

    build-system = [ python3.pkgs.hatchling ];

    dependencies = with python3.pkgs; [
      httpx
      typing-extensions
      websockets
    ];

    meta = with lib; {
      description = "Type-safe Python client for the Chrome DevTools Protocol";
      homepage = "https://github.com/browser-use/cdp-use";
      license = licenses.mit;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    pname = "cdp-use";
    pyproject = true;

    pythonImportsCheck = [ "cdp_use" ];

    src = fetchPypi {
      hash = "sha256-DaOjLfRjNqA/9aIrxrxELNfS8tUKEY/UhW8p039tJqA=";
      pname = "cdp_use";
      inherit version;
    };
    version = "1.4.5";
  };

  devShell = mkShell {
    inputsFrom = [ hermes-agent ];
    packages = git-hooks.enabledPackages ++ [ treefmt.config.build.wrapper ];
    inherit (git-hooks) shellHook;
  };

  exa-py = python3.pkgs.buildPythonPackage rec {

    build-system = with python3.pkgs; [ poetry-core ];

    dependencies = with python3.pkgs; [
      httpcore
      httpx
      openai
      pydantic
      python-dotenv
      requests
      typing-extensions
    ];

    meta = with lib; {
      description = "Python SDK for Exa API";
      homepage = "https://github.com/exa-labs/exa-py";
      license = licenses.mit;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    pname = "exa-py";
    pyproject = true;

    pythonImportsCheck = [ "exa_py" ];

    src = fetchPypi {
      hash = "sha256-94HzCxmfEQIzM4RyitrmS7Faa7yr+pfpH9cF+QrP/EU=";
      pname = "exa_py";
      inherit version;
    };
    version = "2.10.2";
  };

  fal-client = python3.pkgs.buildPythonPackage rec {

    build-system = with python3.pkgs; [
      setuptools
      setuptools-scm
    ];

    dependencies = with python3.pkgs; [
      httpx
      httpx-sse
      msgpack
      websockets
    ];

    meta = with lib; {
      description = "Python client for fal.ai";
      homepage = "https://github.com/fal-ai/fal";
      license = licenses.asl20;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    pname = "fal-client";
    pyproject = true;

    pythonImportsCheck = [ "fal_client" ];

    src = fetchPypi {
      hash = "sha256-nhwH0KYbRSqP+0jBmd5fJUPXVG8SMPYxI3BEMSfF6Tc=";
      pname = "fal_client";
      inherit version;
    };
    version = "0.13.1";
  };

  fetch-use = python3.pkgs.buildPythonPackage rec {

    build-system = [ python3.pkgs.hatchling ];

    meta = with lib; {
      description = "Python client for the Browser Use fetch API";
      homepage = "https://github.com/browser-use/fetch-use";
      license = licenses.mit;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    pname = "fetch-use";
    pyproject = true;

    pythonImportsCheck = [ "fetch_use" ];

    src = fetchPypi {
      hash = "sha256-lRGYfUkH7G2sUB4h1mlG0QCY9mtdIbwqukGJzYG6GJo=";
      pname = "fetch_use";
      inherit version;
    };
    version = "0.4.0";
  };

  # Native (PyO3) document-to-markdown converter; PyPI ships wheels only.
  firecrawl-anydoc = python3.pkgs.buildPythonPackage rec {

    buildAndTestSubdir = "python";

    cargoDeps = rustPlatform.fetchCargoVendor {
      hash = "sha256-yhW5HSzVrZCms4x36J2NGIn1e5YLIgjuNKXM9EJ9J8c=";
      name = "anydoc-${version}";
      inherit src;
    };

    meta = with lib; {
      description = "Convert documents to GitHub-Flavored Markdown";
      homepage = "https://github.com/firecrawl/anydoc";
      license = licenses.mit;
      platforms = platforms.unix;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };

    nativeBuildInputs = with rustPlatform; [
      cargoSetupHook
      maturinBuildHook
    ];
    pname = "firecrawl-anydoc";
    pyproject = true;

    pythonImportsCheck = [
      "anydoc"
      "anydoc._anydoc"
    ];

    src = fetchFromGitHub {
      hash = "sha256-rGv3Bh+zmF9xFUgf8RaSmfyB/gfuQ13iC389i6VZIlM=";
      owner = "firecrawl";
      repo = "anydoc";
      tag = "v${version}";
    };
    version = "0.2.4";
  };

  # Upstream extras only warn-and-disable at runtime when missing (#4175), so
  # ship every extra nixpkgs has. Not yet packaged: honcho, daytona, dingtalk,
  # feishu.
  # nixpkgs' firecrawl-py 2.8.0 builds from the firecrawl monorepo tag v2.8.0,
  # whose python-sdk pyproject declares a different SDK version, so the new
  # pythonMetadataCheckPhase fails. Skip the check until nixpkgs fixes the
  # version mismatch.
  firecrawl-py' = python3.pkgs.firecrawl-py.overridePythonAttrs { dontCheckPythonMetadata = true; };
  git-hooks = gitHooks.run {
    hooks.treefmt = {
      enable = true;
      package = treefmt.config.build.wrapper;
      settings.fail-on-change = true;
    };
    package = prek;
    rootSrc = lib.mkForce ../../../..;
    src = ./.;
  };

  hermes-agent = python3.pkgs.buildPythonApplication {

    build-system = with python3.pkgs; [ setuptools ];

    dependencies = hermesDeps;

    doInstallCheck = true;

    # setup.py refuses to build wheels/sdists unless it knows this is a Nix
    # (uv2nix-style) build; upstream gates it behind this env var.
    env.HERMES_NIX_BUILD = "1";

    makeWrapperArgs = [
      "--set"
      "HERMES_TUI_DIR"
      "${hermes-frontend}/lib/hermes-tui"
      "--set"
      "HERMES_WEB_DIST"
      "${hermes-frontend}/share/hermes-web"
      "--set"
      "HERMES_PYTHON"
      "${pythonEnv}/bin/python3"
      "--set"
      "HERMES_PYTHON_SRC_ROOT"
      "${placeholder "out"}/${python3.sitePackages}"
      "--set"
      "HERMES_NODE"
      "${lib.getExe nodejs}"
      # Runtime data is copied to $out/share/hermes in postInstall; point Hermes at it.
      "--set"
      "HERMES_BUNDLED_SKILLS"
      "${placeholder "out"}/share/hermes/skills"
      "--set"
      "HERMES_OPTIONAL_SKILLS"
      "${placeholder "out"}/share/hermes/optional-skills"
      "--set"
      "HERMES_BUNDLED_PLUGINS"
      "${placeholder "out"}/share/hermes/plugins"
      "--set"
      "HERMES_BUNDLED_LOCALES"
      "${placeholder "out"}/share/hermes/locales"
      # Prevent `hermes update` from trying to modify the Nix store.
      "--set"
      "HERMES_MANAGED"
      "nixos"
      # Disable runtime pip installs; absent extras disable cleanly.
      "--set"
      "HERMES_DISABLE_LAZY_INSTALLS"
      "1"
      # node+npm on PATH short-circuits _ensure_tui_node()'s download bootstrap.
      "--prefix"
      "PATH"
      ":"
      "${lib.makeBinPath [
        nodejs
        cosign
        tirith
        agent-browser
        playwright
        chromium
        gh
      ]}"
    ];

    meta = with lib; {
      changelog = "https://github.com/NousResearch/hermes-agent/releases/tag/v${version}";
      description = "Self-improving AI agent by Nous Research — creates skills from experience and runs anywhere";
      homepage = "https://hermes-agent.nousresearch.com/";
      license = licenses.mit;
      mainProgram = "hermes";
      maintainers = with lib.maintainers; [
        aliez-ren
        mulatta
      ];
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    nativeInstallCheckInputs = [ versionCheckHook ];
    optional-dependencies = optionalDeps;

    passthru = {
      category = "AI Assistants";
      inherit devShell git-hooks treefmt;
      inherit hermes-frontend installStamp nemo-relay;
    };

    patches = [
      ./0001-fix-kanban-preserve-declared-home-for-identity-worke.patch
      ./0002-fix-kanban-scope-claims-to-uid-and-refresh-crash-gra.patch
      ./0003-feat-fast-service_tier-flex-one-edit-in-the-centrali.patch
      ./0004-feat-gemini-emit-service_tier-as-a-top-level-generat.patch
      ./0005-fix-tui-send-the-configured-tier-from-TUI-desktop-bu.patch
      ./0006-fix-align-service-tier-flex-runtime-boundaries.patch
      ./0007-fix-tui-reject-invalid-fast-mode-mirror-requests.patch
      ./0008-fix-tui-validate-lazy-service-tier-against-resolved-.patch
      ./0009-feat-openrouter-service-tiers-flex-priority-and-per-.patch
      ./0010-feat-agent-opt-in-TTFT-service-tier-escalation-for-O.patch
      ./0011-fix-agent-principal-review-hardening-for-service-tie.patch
      ./0012-fix-service-tier-preserve-route-and-session-compatib.patch
      ./0013-fix-tui-validate-and-persist-fast-tier-pins.patch
      ./0014-fix-tui-validate-fast-tier-before-worker-writes.patch
      ./0015-fix-tui-complete-live-fast-slash-authority.patch
      ./0016-fix-tui-preserve-fast-pins-across-compute-hosts.patch
      ./0017-fix-tui-preserve-fast-pin-through-host-bootstrap.patch
      ./0018-fix-aux-resolve-service-tiers-across-auxiliary-paths.patch
      ./0019-fix-aux-preserve-tier-intent-through-route-changes.patch
      ./0020-fix-aux-keep-auxiliary-tier-config-route-aware.patch
      ./0021-fix-aux-omit-empty-service-tier-fields.patch
      ./0022-fix-curator-preserve-auxiliary-tier-on-fallback.patch
      ./0023-fix-aux-retain-service-tier-through-Codex-adapter.patch
    ];
    pname = "hermes-agent";

    # Upstream keeps runtime data outside site-packages and locates it through
    # wrapper environment variables. Preserve that layout because setuptools
    # intentionally omits plugin manifests from the wheel since 2026.8.3.
    postInstall = ''
      mkdir -p $out/share/hermes
      cp -r ${src}/skills $out/share/hermes/skills
      cp -r ${src}/optional-skills $out/share/hermes/optional-skills
      cp -r ${src}/plugins $out/share/hermes/plugins
      cp -r ${src}/locales $out/share/hermes/locales
      # The sources only carry a 0.0.0 placeholder version.
      cp ${installStamp} $out/${python3.sitePackages}/install-stamp.json
    '';

    # #4364: wrapper must wire up the TUI and a deps-capable gateway python.
    postInstallCheck = ''
      grep -q HERMES_TUI_DIR $out/bin/hermes
      grep -q HERMES_WEB_DIST $out/bin/hermes
      grep -q HERMES_PYTHON $out/bin/hermes
      grep -q HERMES_PYTHON_SRC_ROOT $out/bin/hermes
      grep -q HERMES_BUNDLED_SKILLS $out/bin/hermes
      grep -q HERMES_OPTIONAL_SKILLS $out/bin/hermes
      grep -q HERMES_BUNDLED_PLUGINS $out/bin/hermes
      grep -q HERMES_BUNDLED_LOCALES $out/bin/hermes
      test -f $out/share/hermes/locales/en.yaml
      grep -q HERMES_MANAGED $out/bin/hermes
      test -f ${hermes-frontend}/lib/hermes-tui/dist/entry.js
      test -f ${hermes-frontend}/share/hermes-web/index.html
      test -d $out/share/hermes/skills
      test -d $out/share/hermes/optional-skills
      test -n "$(find $out/share/hermes/plugins -name plugin.yaml -print -quit)"
      ${pythonEnv}/bin/python3 -c 'import dotenv, tenacity, openai'
      # Slash workers run HERMES_PYTHON with PYTHONPATH=HERMES_PYTHON_SRC_ROOT.
      PYTHONPATH="$out/${python3.sitePackages}" \
        ${pythonEnv}/bin/python3 -c 'import tui_gateway.slash_worker, ruamel.yaml'
      # #7725: DaemonThreadPoolExecutor mirrors CPython ThreadPoolExecutor
      # internals; assert submit() actually executes work on this Python.
      PYTHONPATH="$out/${python3.sitePackages}" \
        ${pythonEnv}/bin/python3 -c 'from tools.daemon_pool import DaemonThreadPoolExecutor; assert DaemonThreadPoolExecutor(max_workers=1).submit(lambda: 42).result(timeout=30) == 42'
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      # Matrix E2EE: mautrix.crypto must import and the disable switch wired in.
      ${pythonEnv}/bin/python3 -c 'import mautrix.crypto, asyncpg, aiosqlite'
      grep -q HERMES_DISABLE_LAZY_INSTALLS $out/bin/hermes
    '';

    # These re-exec sys.executable, which is the bare interpreter without Hermes'
    # dependencies under Nix. Use the wrapper-provided env.
    postPatch = ''
      substituteInPlace tui_gateway/server.py \
        --replace-fail 'argv = [sys.executable, "-m", "tui_gateway.slash_worker"' \
          'argv = [os.environ.get("HERMES_PYTHON", sys.executable), "-m", "tui_gateway.slash_worker"'
      substituteInPlace tools/browser_use_cli.py \
        --replace-fail 'return [sys.executable, "-m", "browser_harness.run"]' \
          'return [os.environ.get("HERMES_PYTHON", sys.executable), "-m", "browser_harness.run"]'
      substituteInPlace hermes_cli/doctor_platform.py \
        --replace-fail '[sys.executable, "-c", "import hermes_cli.web_server"]' \
          '[os.environ.get("HERMES_PYTHON", sys.executable), "-c", "import hermes_cli.web_server"]'
      substituteInPlace hermes_cli/kanban_db_dispatch.py \
        --replace-fail 'return [sys.executable, "-m", "hermes_cli.main"]' \
          'return [os.environ.get("HERMES_PYTHON", sys.executable), "-m", "hermes_cli.main"]'
    '';
    pyproject = true;

    pythonImportsCheck = [
      "hermes_cli"
      "hermes_cli.dashboard_auth"
      "hermes_cli.proxy"
      # #7650: acp_adapter needs the pre-0.11 ACP schema; assert it imports.
      "acp_adapter.server"
      # #4175: adapters swallow ImportError, so assert these import.
      "slack_bolt"
      "discord"
      "telegram.ext"
      "croniter"
      # relay_runtime imports this lazily and silently degrades to a noop
      # runtime when missing, so assert it imports.
      "nemo_relay"
      "browser_harness"
    ];

    pythonRelaxDeps = [
      "openai"
      "python-dotenv"
      "tenacity"
      "ruamel.yaml"
      "requests"
      "pydantic"
      "pathspec"
      "firecrawl-py"
      "pyjwt"
      "cryptography"
      "certifi"
      "packaging"
      "urllib3"
      "websockets"
      # nixpkgs moved past upstream's == pins
      "rich"
      "pillow"
      "croniter"
    ];

    # Only used by upstream's icon generator, which is not installed.
    pythonRemoveDeps = [ "resvg-py" ];
    inherit src version;
    versionCheckProgramArg = [ "--version" ];
  };

  # Upstream moved ui-tui/ and web/ into npm workspaces with a single root
  # package-lock.json, so both frontends must be built from the repo root.
  # `hermes --tui` runs the compiled Ink/React bundle via HERMES_TUI_DIR
  # (hermes_cli/main.py:_make_tui_argv fast-path, #4364) and
  # `hermes dashboard` serves the Vite app via HERMES_WEB_DIST.
  hermes-frontend = buildNpmPackage {

    buildPhase = ''
      runHook preBuild
      npm run build --workspace ui-tui
      node scripts/build/web.mjs --source "$PWD" --icons "$PWD" --out "$TMPDIR/web-dist"
      runHook postBuild
    '';
    env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

    # dist/entry.js is a self-contained esbuild bundle; package.json is kept
    # so node resolves it as an ES module.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/hermes-tui $out/share/hermes-web
      cp -r ui-tui/dist ui-tui/package.json $out/lib/hermes-tui/
      cp -r "$TMPDIR/web-dist"/. $out/share/hermes-web/
      runHook postInstall
    '';
    npmDepsHash = "sha256-45CV8Qavo5UQlUfSQuWzhZK1Xicx9iW8dDDsDvAM2Dc=";

    # The apps/desktop workspace pulls in electron; skip its binary download
    # and all install scripts — the esbuild/vite builds below don't need them.
    # Upstream's .npmrc sets engine-strict=true and package.json rejects the
    # npm range shipped with nixpkgs' nodejs to work around a min-release-age
    # bug, which is irrelevant for the offline install here.
    npmFlags = [
      "--ignore-scripts"
      "--engine-strict=false"
    ];
    pname = "hermes-frontend";
    inherit src version;
  };

  hermesDeps =
    with python3.pkgs;
    [
      # Core
      openai
      anthropic
      snowballstemmer
      python-dotenv
      fire
      httpx
      rich
      tenacity
      pathspec
      pillow
      ruamel-yaml
      tomli-w
      truststore
      resvg-py
      requests
      jinja2
      pydantic
      firecrawl-anydoc
      # Interactive CLI
      prompt-toolkit
      # Cron scheduler
      croniter
      # Process / PID management
      psutil
      # MCP
      mcp
      # Tools
      exa-py
      firecrawl-py'
      parallel-web
      fal-client
      browser-harness
      # Text-to-speech
      edge-tts
      # Skills Hub
      pyjwt
      cryptography
      # Relay lifecycle + shared metrics
      nemo-relay
    ]
    # faster-whisper -> av SIGKILLs during import on darwin; voice is optional.
    ++ lib.optionals stdenv.hostPlatform.isLinux [ faster-whisper ]
    ++ optionalDeps.gateway
    ++ optionalDeps.misc
    ++ optionalDeps.propagate;

  installStamp = writeText "install-stamp.json" (
    builtins.toJSON {
      baseVersion = version;
      commit = rev;
      dirty = false;
      displayVersion = version;
      distance = 0;
      distribution = "nix";
      # Desktop: use an external Hermes instead of a bundled one.
      payload = "bootstrap";
      schemaVersion = 2;
      source = "nix";
      updateMechanism = "external";
    }
  );
  # Native (PyO3) runtime for hermes' Relay lifecycle and shared metrics.
  # PyPI ships wheels only, so build from source with maturin.
  # Version is kept in range of hermes' pyproject constraint by update.py.
  nemo-relay = python3.pkgs.buildPythonPackage rec {

    cargoDeps = rustPlatform.fetchCargoVendor {
      hash = "sha256-P9+/lvxQVm+H1+qM8lPo2aXMLJTHM1F8HWS7x0I2jPs=";
      name = "nemo-relay-${version}";
      inherit src;
    };

    meta = with lib; {
      description = "Python bindings for the NeMo Relay agent runtime";
      homepage = "https://github.com/NVIDIA/NeMo-Relay";
      license = licenses.asl20;
      platforms = platforms.unix;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };

    nativeBuildInputs =
      with rustPlatform;
      [
        cargoSetupHook
        maturinBuildHook
      ]
      # Tags lag the workspace Cargo.toml version that pyproject derives from.
      ++ [ python3.pkgs.pyprojectVersionPatchHook ];
    pname = "nemo-relay";
    pyproject = true;

    pythonImportsCheck = [
      "nemo_relay"
      "nemo_relay._native"
    ];

    src = fetchFromGitHub {
      hash = "sha256-+2jhLqjcYUWBhuwNMaVK/ICtnrwYuc5gtCo6b8EGp68=";
      owner = "NVIDIA";
      repo = "NeMo-Relay";
      tag = version;
    };
    version = "0.10.3";
  };

  optionalDeps = with python3.pkgs; {
    gateway = [
      # [messaging] / [slack]
      slack-bolt'
      slack-sdk
      python-telegram-bot
      discordpy
      aiohttp
      # [cron]
      croniter
      # [web]
      fastapi
      httptools
      uvicorn
      # [markdown] — used by matrix and other formatters
      markdown
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      # [matrix] — nixpkgs mautrix lacks the encryption extra, so add its
      # crypto deps explicitly.
      mautrix
      (python-olm.override { inherit olm; })
      unpaddedbase64
      pycryptodome
      base58
      aiosqlite
      asyncpg
      aiohttp-socks
    ];
    misc = [
      # [cli]
      simple-term-menu
      # [pty]
      ptyprocess
      # [acp]
      agent-client-protocol'
      # [voice]
      sounddevice
      numpy
      # [tts-premium]
      elevenlabs
      # [mistral]
      mistralai
      # [bedrock]
      boto3
      # [modal]
      modal
      # web_search backend hermes would otherwise try to pip-install (#8259)
      ddgs
    ];
    propagate = [
      tiktoken
      mnemosyne
    ];
  };

  parallel-web = python3.pkgs.buildPythonPackage rec {

    build-system = with python3.pkgs; [
      hatchling
      hatch-fancy-pypi-readme
    ];

    dependencies = with python3.pkgs; [
      anyio
      distro
      httpx
      pydantic
      sniffio
      typing-extensions
    ];

    meta = with lib; {
      description = "Python SDK for Parallel Web API";
      homepage = "https://github.com/parallel-web/parallel-sdk-python";
      license = licenses.asl20;
      platforms = platforms.all;
      sourceProvenance = with sourceTypes; [ fromSource ];
    };
    pname = "parallel-web";

    # Upstream pins hatchling==1.26.3 in build-system.requires; pythonRelaxDeps
    # only touches runtime metadata, so skip the build-time pin check.
    pypaBuildFlags = [ "--skip-dependency-check" ];
    pyproject = true;

    pythonImportsCheck = [ "parallel" ];

    src = fetchPypi {
      hash = "sha256-WZtajzh9w1x9yMgeNy6t9pWKQKys6li/Fw38ZjwAPac=";
      pname = "parallel_web";
      inherit version;
    };
    version = "0.4.2";
  };

  # The TUI spawns `$HERMES_PYTHON -m tui_gateway.entry`; sys.executable is the
  # bare interpreter, so give it an env with the runtime deps. The dashboard
  # PTY path copies wrapper env into a nested Node subprocess, which then
  # resolves the gateway import root from HERMES_PYTHON_SRC_ROOT.
  pythonEnv = python3.withPackages (_: hermesDeps);
  rev = "d923a5eb487a17c0a68801bba9ef0f56c81040a8";

  # pyramid dropped its pkg_resources shim on python 3.14, so slack-bolt's
  # pyramid adapter tests fail at collection with ModuleNotFoundError.
  # The async assistant scenario tests wait on real timers and time out on
  # loaded builders.
  # pkg-resources-backport tests need jaraco-path, broken on darwin
  slack-bolt' =
    #(python3.pkgs.slack-bolt.override {
    #  pkg-resources-backport = python3.pkgs.pkg-resources-backport.overridePythonAttrs {
    #    doCheck = !stdenv.hostPlatform.isDarwin;
    #  };
    #})
    python3.pkgs.slack-bolt.overridePythonAttrs (old: {
      disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
        "tests/adapter_tests/pyramid/"
        "tests/scenario_tests_async/test_events_assistant.py"
      ];
    });

  src = fetchFromGitHub {
    hash = "sha256-Zs5Jr2BZ89RHbyj2WX2y4hIh4Vuwz8mJvGJooWytCk4=";
    owner = "NousResearch";
    # contributors/emails/ holds paths differing only in case; they collapse
    # on case-insensitive stores (APFS) so the NAR hash diverges between
    # Linux and darwin. Unused at build/runtime. Upstream:
    # NousResearch/hermes-agent#88257
    postFetch = ''
      rm -rf "$out/contributors"
    '';
    repo = "hermes-agent";
    tag = "v${version}";
  };
  treefmt = treefmtEval ./treefmt.nix;

  version = "0.22.2";
in
hermes-agent
