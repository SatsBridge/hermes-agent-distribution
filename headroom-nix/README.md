# Headroom on Nix

This directory packages [Headroom](https://github.com/headroomlabs-ai/headroom)
for Nix as part of the Hermes Agent distribution flake. Headroom sits in front
of LLM APIs and trims token usage; its reproducible Nix packages are exposed by
the parent flake.

None of Headroom's source lives here. The flake fetches and builds a pinned
release with `fetchFromGitHub`. The release, commit, and source hash are pinned
in `headroom-nix/nix/headroom-source.nix`.

## The packages

- **`headroom`** — the full command-line tool. It bundles the compiled core, the
  Python code, and every platform-applicable optional dependency except `dev`,
  including extras outside upstream's narrower `[all]` set. Python packages
  missing from nixpkgs are built from pinned source distributions. `fastembed`
  is omitted on aarch64-linux because nixpkgs does not support it there. The
  wrapper provides `codebase-memory-mcp` v0.11.0 from the pinned source flake
  and forces binary-download and telemetry opt-outs.
- **`headroom-proxy`** — the Rust reverse proxy (axum + tokio): one binary you
  point your LLM client at.
- **`headroom-py`** — the compiled Rust extension `headroom._core`, built as a
  separate package to keep the extension build cacheable.
- **`headroom-hermes-plugin`** — the retrieve plugin for
  [Hermes Agent](https://hermes-agent.nousresearch.com/). Installs a
  `headroom_retrieve` plugin directory you copy into `~/.hermes/plugins/`.

## Requirements

Nix with flakes enabled. Nothing else — the Rust and Python toolchains, maturin,
and ONNX Runtime all come from the flake.

## Packages in the parent flake

From the project root, build or run the packages by name:

```sh
nix build .#headroom
nix build .#headroom-proxy
nix build .#headroom-py
nix build .#headroom-hermes-plugin
nix run .#headroom -- --help
nix develop .#headroom
```

The root flake keeps `default` assigned to `gh-token-manager`; Headroom has
explicit package and app names instead.

## A note on ONNX Runtime

Headroom's core links `fastembed`, which normally downloads an ONNX Runtime
binary during the build. That fails in Nix's network-less sandbox, so the
packages load ONNX Runtime dynamically from the Nix store instead. The binaries
are wrapped to find it, so you don't set anything. If you build in an unusual
environment and hit a "cannot find libonnxruntime" error, point
`ORT_DYLIB_PATH` at a `libonnxruntime.so`.

LiteLLM uses its bundled model-cost map instead of refreshing it from GitHub at
startup; pricing metadata therefore stays at the packaged version.

## The Hermes plugin

`headroom-hermes-plugin` installs the plugin under
`share/hermes/plugins/headroom_retrieve`. To use it:

```sh
nix build .#headroom-hermes-plugin
cp -r result/share/hermes/plugins/headroom_retrieve ~/.hermes/plugins/
```

Then enable it in `~/.hermes/config.yaml` — see the README installed alongside
it under `share/doc/`.

## Development

- `nix fmt` formats the root project's Nix and Rust files.
- `nix flake check` builds every package, runs their test suites and clippy, and
  checks formatting. This is what CI runs.
- Commit messages follow Conventional Commits (a `convco` git hook enforces it).
