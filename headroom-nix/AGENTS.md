# AGENTS.md

Nix packaging for [Headroom](https://github.com/headroomlabs-ai/headroom). This
repo holds only a flake, patches, and docs — the Headroom source is fetched with
`fetchFromGitHub`, never vendored.

## What this builds

From one pinned upstream release (`nix/headroom-source.nix`):

- `headroom-proxy` — the Rust reverse-proxy binary (`crates/headroom-proxy`).
- `headroom-py` — the maturin wheel carrying the compiled extension
  `headroom._core` (from `crates/headroom-py`) plus the pure-Python `headroom/`
  tree. Minimal deps; import-checked only.
- `headroom` — the full CLI: `headroom-py` composed with every optional non-dev
  runtime dependency, tested against the upstream pytest suite. The default
  package and app.
- `headroom-hermes-plugin` — the Hermes-Agent CCR retrieve plugin
  (`plugins/hermes`) installed as a drop-in user plugin.

## Commands

- `nix flake check` — builds every package, runs their test suites, clippy, and
  the git-hooks bundle (treefmt with fail-on-change).
- `nix build .#<pkg>` — build one (`headroom`, `headroom-proxy`, `headroom-py`,
  `headroom-hermes-plugin`).
- `nix run` runs `headroom`; `nix run .#headroom-proxy` runs the proxy.
- `nix fmt` — treefmt.
- `nix develop` — dev shell (rust, maturin, uv, treefmt, hooks).

## Layout

- `nix/default.nix` — per-system assembly; produces packages/apps/checks/
  formatter/devShell that `flake.nix` maps over the systems.
- `nix/headroom-source.nix` — the `fetchFromGitHub` pin + `applyPatches`.
- `nix/proxy.nix` — `rustPlatform.buildRustPackage` of the Rust binary.
- `nix/headroom-py.nix` — maturin build of the compiled distribution.
- `nix/headroom.nix` — composes `headroom-py` + runtime extras + the CLI + tests.
- `nix/rtk.nix` — the `rtk` CLI, taken from nixpkgs-unstable (0.43.0).
- `nix/headroom-hermes-plugin.nix` — installs the Hermes plugin tree.
- `nix/treefmt.nix` — formatter set.
- `nix/patches/` — surgical patches applied to the fetched source.

## Non-obvious facts (read before editing)

- **Toolchain.** `rust-toolchain.toml` pins 1.95.0 and the MSRV is 1.80;
  nixos-26.05 ships 1.95.0, so the stock nixpkgs toolchain is used — no fenix.
  If a future release needs a newer rustc than nixpkgs has, add fenix rather
  than overriding nixpkgs.

- **The Rust workspace is not fully cargo-buildable.** `crates/headroom-py` is a
  pyo3 cdylib that only builds through maturin (needs `extension-module`), so
  `proxy.nix` scopes to `crates/headroom-proxy` via `buildAndTestSubdir` and the
  Python side goes through maturin.

- **Two Python packages, one wheel.** maturin emits a single `headroom-ai` wheel
  (Python code + `_core`). `headroom-py` is that wheel with a minimal import
  check; `headroom` composes it with the runtime extras and runs the tests, so
  the slow Rust compile and the dependency-heavy assembly are separate,
  cacheable derivations.

- **Version gaps: unstable first, then in-place bump.** Where nixpkgs 26.05 is
  below Headroom's floor: `rtk` is taken from nixpkgs-unstable (a standalone
  binary, safe across nixpkgs), and `litellm` is bumped in place in
  `nix/headroom.nix` (a Python dep, kept on our own python to avoid ABI mixing).
  See `nix/changes.md` for the per-extra coverage matrix and remaining gaps.

- **Runtime binaries are build inputs, never downloaded.** Headroom shells out
  to `ast-grep`, `difft`, `scc`, and `rtk`, fetching the last three from GitHub
  releases on first use. All four are put on the `headroom` CLI's PATH (and the
  test PATH) from nixpkgs, so `binaries.which()` / `rtk.get_rtk_path()` resolve
  them and nothing hits the network. `HEADROOM_BINARIES_OFFLINE=1` fails the
  build closed if a fetch is ever attempted.

- **Tests that need the network are skipped, not disabled.** The proxy's
  `e2e_real` target hits live provider APIs (skipped via `--skip=e2e_real`);
  every wiremock-backed integration test still runs. The Python suite deselects
  only individual network / process-spawn / no-`/bin/bash` cases via
  `disabledTests` / `disabledTestPaths`, each with a reason in `nix/headroom.nix`.
  Do not broaden these skips; they exist only because the sandbox has no network
  or process-spawn ability.

## Editing patches

Patches must be surgical: one problem each, minimal diff, tests never disabled.
Add a file under `nix/patches/` and list it in `headroom-source.nix`. Prefer
patching to switching build strategy.
