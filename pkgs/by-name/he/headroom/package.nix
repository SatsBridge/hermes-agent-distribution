# headroom: the full Python distribution and `headroom` CLI.
#
# Composition over recompile. The slow Rust compile already happened in
# `headroom-py/package.nix`, which carries just `headroom/_core.abi3.so`. This package
# installs the pure-Python `headroom/` tree straight from source, drops that
# prebuilt `_core.abi3.so` in beside it, and layers on every optional-extra
# runtime dependency so the CLI and all non-dev features work fully OFFLINE.
# Because the extension is copied in (not rebuilt), `format = "other"` is used
# instead of the maturin `pyproject` build — we still get buildPythonPackage's
# dependency propagation, wrapping, and import check, without a second Rust
# build. headroom-py is therefore a build input here rather than a runtime
# `dependencies` entry: a runtime entry would put a second, `_core`-only
# `headroom/` directory on sys.path and shadow this complete one.
#
# The upstream pytest suite runs against this installed tree with the real
# dependency set. Only individual sandbox-incompatible or variant-inapplicable
# tests are deselected, with reasons below.
{
  ast-grep,
  cacert,
  cargo,
  codebase-memory-mcp,
  difftastic,
  fetchurl,
  git,
  gitHooks,
  headroom-proxy,
  headroom-py,
  headroom-python-pkgs,
  headroom-source,
  lib,
  makeWrapper,
  maturin,
  mkShell,
  onnxruntime,
  prek,
  rtk,
  runCommand,
  rustc,
  scc,
  stdenv,
  treefmtEval,
  uv,
  writeText,
}:
let

  buildInfo = writeText "headroom-build-info.py" ''
    BUILD_VERSION = "${headroom-source.version}"
  '';

  # Provide every subprocess tool on PATH; CBM and the other tools are Nix-built.
  bundledTools = builtins.attrValues {
    inherit ast-grep scc;
    inherit codebase-memory-mcp;
    difft = difftastic;
    inherit rtk;
  };

  # `-k` matches disabled test-name substrings; `--ignore` excludes whole files.
  # `-m` drops the slow / real-LLM / live-network marked cases.
  deselectArgs = (map (p: "--ignore=${p}") disabledTestPaths) ++ [
    "-k"
    ("not (" + lib.concatStringsSep " or " disabledTests + ")")
    "-m"
    "not slow and not real_llm and not live"
  ];

  devShell = mkShell {
    inputsFrom = [
      headroom-proxy
      headroom
    ];
    packages =
      git-hooks.enabledPackages
      ++ builtins.attrValues {
        inherit
          cargo
          maturin
          rustc
          uv
          ;
      }
      ++ [ treefmt.config.build.wrapper ];
    inherit (git-hooks) shellHook;
  };

  # Exclude individual tests only for sandbox limits, test-harness assumptions,
  # or missing-extra cases that do not apply to the full runtime package.
  disabledTestPaths = [
    "tests/test_memory/test_qdrant_env.py" # needs a live qdrant
    "tests/test_install/test_native_installers.py" # bash installers + docker
    "tests/test_install/test_runtime.py" # runtime locks / process spawn
    "tests/test_evals/test_html_oss_benchmarks.py" # downloads a HuggingFace dataset
  ];

  disabledTests = [
    "test_fastembed_uses_rustls_features" # asserts pre-patch Cargo.toml feature
    "test_codex_launch_env_routes_messages_through_headroom" # spawns real proxy
    "test_codex_install_env_routes_messages_through_headroom"
    "test_init_codex_config_routes_messages_through_headroom"
    "test_provider_scope_codex_config_routes_messages_through_headroom"
    "test_dynamic_detector_import_skips_optional_ml_dependencies" # subprocess env
    # Missing-extra tests are invalid for the full runtime package and can start a real proxy.
    "test_proxy_command_exits_when_mcp_missing"
    "test_ensure_proxy_dependencies_exits_when_fastapi_missing"
    "test_register_claude_hooks_survives_forked_daemon" # needs /bin/bash
    "test_switching_provider_recaptures" # tmpfs identical st_mtime_ns
    "test_official_resets_a_captured_third_party_upstream" # same tmpfs mtime quirk
    "test_code_graph_watcher_init_start_stop_and_event_filtering" # same mtime quirk
    "test_no_native_tls_in_wheel_build_tree" # spawns cargo (no registry access)
    "test_harness_runs_against_mock_proxy_and_exits_zero" # spawns a mock proxy process
    # cert_store_stats() asserts the host CA bundle has >1 root; the build
    # sandbox exposes a single-cert store.
    "test_toggle_off_returns_relaxed_context"
    "test_node_extra_ca_certs_is_additive"
    # `headroom mcp status` shells out to a helper the CliRunner subprocess env
    # cannot locate inside the sandbox.
    "test_status_configured"
    "test_status_not_configured"
    # Persistent-wrap restart checks depend on observing an idle/stale proxy
    # process transition; the Nix sandbox process model makes the synthetic
    # restart probe non-deterministic.
    "test_ensure_proxy_restarts_idle_stale_persistent_deployment"
    "test_ensure_proxy_restarts_idle_stale_ephemeral_proxy"
    # These depend on a live process/PID or POSIX /usr/bin layout unavailable in the sandbox.
    "test_ensure_proxy_stale_idle_restart_failures_are_actionable"
    "test_sighup_on_launch_tool_releases_the_proxy"
    "test_seized_gil_is_dumped_and_exited"
    "test_healthy_process_is_never_shot"
    "test_swapped_stderr_does_not_kill_the_heartbeat"
    # These fixtures use public upstream hosts; the proxy's SSRF guard correctly rejects them offline.
    "test_contract_disabled_by_env"
    "test_claude_proxy_preserves_tool_use_items"
    "test_claude_proxy_bypass_header_skips_compression"
    "test_claude_proxy_no_model_forwarded_unchanged"
    "test_claude_proxy_compression_applies_to_chat_messages"
    "test_header_passed_as_upstream_base_url"
    "test_header_value_is_trimmed_and_trailing_slash_stripped"
    "test_chat_upstream_reconstruction_base_fails_head_passes"
    "test_responses_upstream_reconstruction_base_fails_head_passes"
    "test_query_string_is_preserved_for_reconstructed_upstream_paths"
    "test_opencode_zen_reconstructed_chat_path_records_zen_provider"
    # These assert unavailable installed extras, CLI test imports, or model readiness.
    "test_ordinary_install_does_not_adopt_serena"
    "test_cli_stateless_flag_exports_env_for_children"
    # These load HuggingFace-hosted embedding models at test time. The models are
    # small enough to package later, but not yet present in the offline build
    # cache, so keep the sandbox closed rather than allowing runtime downloads.
    "test_cpu_uses_dedicated_thread_capped_executor"
    "test_cpu_embed_workers_are_thread_capped"
    "test_embed_single"
    "test_embed_batch"
    "test_similar_texts_have_high_similarity"
    "test_semantic_match"
    "test_paraphrase_match"
    "test_batch_efficiency"
    "test_hybrid_scoring"
  ];

  git-hooks = gitHooks.run {
    hooks = {
      convco.enable = true;
      treefmt = {
        enable = true;
        package = treefmt.config.build.wrapper;
        settings.fail-on-change = true;
      };
    };
    package = prek;
    rootSrc = lib.mkForce ../../../..;
    src = ./.;
  };

  headroom = py.buildPythonPackage {
    checkPhase = ''
      runHook preCheck

      # pytest collects from the unpacked source root, where the in-tree
      # `headroom/` (no compiled extension) shadows the installed one. Drop the
      # prebuilt `_core` in beside the sources so `import headroom._core` resolves.
      cp ${headroom-py}/${python.sitePackages}/headroom/${headroom-py.passthru.coreLib} \
        headroom/${headroom-py.passthru.coreLib}

      export TIKTOKEN_CACHE_DIR=${tiktokenCache}
      # nixpkgs sets HOME=/homeless-shelter (non-writable); several tests write
      # under $HOME (rtk/wrap setup, memory db). Point it at a writable temp dir.
      export HOME=$(mktemp -d)
      export USER=hermes LOGNAME=hermes
      # nixpkgs' stdenv forces SSL_CERT_FILE=/no-cert-file.crt for hermeticity.
      # The proxy startup builds an httpx.AsyncClient, and httpx reads that var to
      # seed its SSL context — a nonexistent path makes ssl.create_default_context
      # raise FileNotFoundError, breaking every proxy-startup test (which use
      # TestClient / wiremock, not real network). Point it at a real CA bundle so
      # the context builds; no test makes an outbound TLS connection.
      export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      export NIX_SSL_CERT_FILE=$SSL_CERT_FILE
      export LITELLM_LOCAL_MODEL_COST_MAP=True
      export ORT_DYLIB_PATH=${ortDylib}
      # The proxy's /readyz and /health probe the configured upstream API with a
      # HEAD request at startup; with no network in the sandbox that probe fails
      # and the health checks report "unhealthy" (503). This is Headroom's own
      # documented opt-out for environments that can't reach the upstream — it
      # only suppresses the network probe, every other health component still
      # reports for real. Tests that exercise the probe itself override this per
      # test via monkeypatch (setenv/delenv), so the global default is safe.
      export HEADROOM_SKIP_UPSTREAM_CHECK=1
      # Model artifacts are not vendored; prevent HuggingFace clients from retrying egress.
      export HF_HUB_OFFLINE=1
      export TRANSFORMERS_OFFLINE=1
      # difft/scc/rtk/ast-grep resolve from PATH (no GitHub fetch). Belt-and-braces:
      # if any code path still tries to fetch a binary, fail closed instead of
      # reaching the network — the sandbox has none anyway.
      export PATH=${lib.makeBinPath bundledTools}:$PATH
      export HEADROOM_BINARIES_OFFLINE=1

      ${python.interpreter} ${./check-extra-dependencies.py}

      # Preserve the Nix upstream-health opt-out; test-local HEADROOM flags stay scrubbed.
      substituteInPlace tests/conftest.py \
        --replace-fail 'if key.startswith("HEADROOM_"):' \
                       'if key.startswith("HEADROOM_") and key != "HEADROOM_SKIP_UPSTREAM_CHECK":'

      ${py.python.interpreter} -m pytest -p no:cacheprovider -q \
        ${lib.escapeShellArgs deselectArgs}

      runHook postCheck
    '';

    dependencies = runtimeDeps;
    dontBuild = true;

    # `format = "other"` gives us the default stdenv phases; there is nothing to
    # configure or compile here (the extension is prebuilt in headroom-py and the
    # Python code is installed verbatim), so those phases are skipped. The custom
    # installPhase below does all the work.
    dontConfigure = true;

    # The extension is copied from headroom-py, not rebuilt, so there is no
    # pyproject/maturin build step — install the source tree ourselves.
    format = "other";

    # Install the pure-Python `headroom/` package and its data files verbatim,
    # then drop the prebuilt compiled extension in beside them and write the
    # `headroom` console-script (pyproject: `headroom = headroom.cli:main`).
    # wrapPythonProgramsHook wraps that script in postFixup, adding the runtime
    # dependencies (propagated) and the makeWrapperArgs above.
    installPhase = ''
      runHook preInstall

      site="$out/${python.sitePackages}"
      mkdir -p "$site"
      cp -r headroom "$site/"
      cp ${headroom-py}/${python.sitePackages}/headroom/${headroom-py.passthru.coreLib} \
        "$site/headroom/${headroom-py.passthru.coreLib}"
      cp ${buildInfo} "$site/headroom/_build_info.py"

      mkdir -p "$out/bin"
      # The console-script body from pyproject (`headroom = headroom.cli:main`),
      # with the interpreter shebang patched in. wrapPythonProgramsHook then wraps
      # it with the propagated deps' PYTHONPATH and makeWrapperArgs.
      {
        echo "#!${python.interpreter}"
        cat ${launcher}
      } > "$out/bin/headroom"
      chmod +x "$out/bin/headroom"

      runHook postInstall
    '';

    # Extra wrapper arguments applied by wrapPythonProgramsHook (which also injects
    # the propagated dependencies onto PYTHONPATH): the offline CLI tools on PATH
    # and libonnxruntime for the compiled core.
    # Keep LiteLLM on its bundled map; a refresh would violate the offline runtime.
    makeWrapperArgs = [
      # Prevent a caller's Python path from shadowing the pinned package set.
      "--unset"
      "PYTHONPATH"
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath bundledTools)
      "--set-default"
      "LITELLM_LOCAL_MODEL_COST_MAP"
      "True"
      "--set"
      "HEADROOM_BINARIES_OFFLINE"
      "1"
      "--set"
      "DO_NOT_TRACK"
      "1"
      "--set-default"
      "ORT_DYLIB_PATH"
      ortDylib
    ];

    meta = {
      description = "Headroom context-optimization layer for LLM apps (Python + Rust core)";
      homepage = "https://github.com/headroomlabs-ai/headroom";
      mainProgram = "headroom";
      platforms = lib.platforms.unix;
    };

    nativeBuildInputs = [ makeWrapper ];

    # Full offline test run against the installed source with the real dependency
    # set. Only individual network / process-spawn cases are deselected, each with
    # a reason above.
    # Test-only dependencies; these do not enter the runtime closure.
    nativeCheckInputs =
      builtins.attrValues {
        inherit (py)
          packaging
          pytest
          pytest-asyncio
          respx
          socksio
          ;
      }
      ++ bundledTools
      ++ [ git ];

    passthru = {
      inherit devShell git-hooks;
      proxy = headroom-proxy;
      inherit tiktokenCache treefmt;
    };
    pname = "headroom";

    pythonImportsCheck = [
      "headroom"
      "headroom._core"
      "headroom._build_info"
    ];
    src = headroom-source;
    inherit (headroom-source) version;
  };

  # The `headroom = headroom.cli:main` console-script body (a shebang is
  # prepended at install time).
  launcher = writeText "headroom-launcher.py" ''
    import sys

    from headroom.cli import main

    sys.exit(main())
  '';
  ortDylib = "${onnxruntime}/lib/libonnxruntime${stdenv.hostPlatform.extensions.sharedLibrary}";
  py = headroom-python-pkgs;
  inherit (headroom-python-pkgs) python;

  # All applicable optional extras except dev, including extras not selected by
  # upstream's narrower `[all]`; see check-extra-dependencies.py.
  runtimeDeps = [
    py.litellm
  ]
  ++ builtins.attrValues {
    inherit (py)
      # [proxy]
      accelerate
      agno
      anthropic
      any-llm-sdk
      autogen-agentchat # httpx[http2] extra — required by the proxy's HTTP/2 client
      awscrt
      boto3
      botocore
      click
      datasets
      fastapi
      gunicorn
      h2
      # transformers 5.x (nixpkgs) needs huggingface-hub >=1.5.
      hnswlib
      httpx
      huggingface-hub
      jinja2
      # core (from pyproject [project.dependencies])
      langchain-core
      langchain-openai
      langgraph
      magika
      mcp
      mem0ai
      neo4j
      numpy
      # [code]
      onnxruntime
      openai
      # [vector] and [memory-stack]
      openpyxl
      opentelemetry-api
      opentelemetry-exporter-otlp-proto-http
      opentelemetry-sdk
      # [relevance]
      orjson
      # [image]
      pillow
      pydantic
      pyyaml
      # [reports]
      qdrant-client
      # [otel]
      rapidocr
      rich
      # [spreadsheet]
      scikit-learn
      sentence-transformers
      # [html]
      sentencepiece
      # [evals]
      sqlite-vec
      strands-agents
      tiktoken
      # [memory]
      tomlkit
      # [anyllm]
      torch
      # [langchain] and [langgraph]
      trafilatura
      transformers
      tree-sitter
      # [agno], [strands], [autogen], [voice-train], and [bedrock]
      tree-sitter-language-pack
      truststore
      uvicorn
      watchdog
      websockets
      xlrd
      zstandard
      ;
  }
  # nixpkgs marks fastembed unsupported on aarch64-linux.
  ++ lib.optionals (stdenv.hostPlatform.system != "aarch64-linux") [ py.fastembed ];

  tiktokenCache = runCommand "tiktoken-cache" { } (
    ''
      mkdir -p "$out"
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: file:
        let
          key = builtins.hashString "sha1" url;
          url = "https://openaipublic.blob.core.windows.net/encodings/${name}.tiktoken";
        in
        ''cp ${file} "$out/${key}"''
      ) tiktokenEncodings
    )
  );

  # tiktoken downloads its BPE vocab from openaipublic.blob.core.windows.net the
  # first time an encoding is used. The sandbox has no network, so the ~445
  # tokenizer-backed unit tests would fail with ConnectionError. Pre-seed
  # tiktoken's on-disk cache instead: it reads
  # `$TIKTOKEN_CACHE_DIR/<sha1(url)>` before fetching (tiktoken/load.py). The
  # vocab files are fetched as fixed-output derivations (content-addressed → the
  # one place the Nix sandbox permits network), so the check phase stays offline
  # and the tests run rather than being skipped.
  tiktokenEncodings = {
    "cl100k_base" = fetchurl {
      hash = "sha256-Ijkht27pm96ZW3/3OFE+7xAPtR0YyTWXoRO8/+hlsqc=";
      url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
    };
    "o200k_base" = fetchurl {
      hash = "sha256-RGqVOMtsNI41FhINfAiwn1fDZJXirP/+WaW/iwz7Gi0=";
      url = "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken";
    };
    "p50k_base" = fetchurl {
      hash = "sha256-lLXKff9NAHZ7wlb90bJ+Wxc2HXuKX5aFR/nyPrcNIGk=";
      url = "https://openaipublic.blob.core.windows.net/encodings/p50k_base.tiktoken";
    };
    "r50k_base" = fetchurl {
      hash = "sha256-MGzSfwPBpxTspxCOA9ZrfcBCq+jCWLRMGZp+2YON2TA=";
      url = "https://openaipublic.blob.core.windows.net/encodings/r50k_base.tiktoken";
    };
  };

  treefmt = treefmtEval ./treefmt.nix;
in
headroom
