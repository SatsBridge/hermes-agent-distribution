# Headroom on Nix

This directory packages [Headroom](https://github.com/headroomlabs-ai/headroom)
for Nix as part of the Hermes Agent distribution flake. Headroom sits in front
of LLM APIs and trims token usage; its reproducible Nix packages are exposed by
the parent flake.

None of Headroom's source lives here. The flake fetches a pinned release with
`fetchFromGitHub`, applies a couple of small patches, and builds it. Moving to a
new Headroom version is a two-line change in
`headroom-nix/nix/headroom-source.nix` (the commit and its hash).

## The packages

- **`headroom`** — the full command-line tool. It bundles the compiled core, the
  Python code, and every optional non-dev runtime dependency, so the CLI works
  offline out of the box.
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

`headroom-nix/AGENTS.md` has the details an automated agent — or a hurried
human — needs to work on the packaging itself.
