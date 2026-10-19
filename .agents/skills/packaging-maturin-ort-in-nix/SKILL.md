---
name: packaging-maturin-ort-in-nix
description: Use when packaging a Rust+Python (maturin/pyo3) project for Nix that (a) pulls ONNX Runtime via `ort`/`fastembed`/`magika`, (b) downloads helper binaries or models from GitHub at runtime, or (c) needs dependency versions newer than nixpkgs ships. Covers the ort load-dynamic patch, buildRustPackage vs maturin split, turning runtime downloads into build inputs for offline use, in-place version bumps of nixpkgs recipes, and sandbox-only test handling.
version: 1.1.0
author: Headroom Nix Packager
metadata:
  hermes:
    tags: [nix, rust, python, maturin, onnxruntime, offline, packaging]
    related_skills: []
---

# Packaging a maturin + Rust-core project for Nix, offline

## Overview

Hybrid Rust+Python projects (maturin/pyo3) commonly assume network at build or
run time: the `ort` crate downloads ONNX Runtime during `cargo build`; Python
code fetches CLI helpers or model files from GitHub releases on first use; and
pinned dependency floors sit above what nixpkgs ships. Nix builds run in a
network-less sandbox and packaged apps should work offline, so each assumption
must be converted into an explicit, content-addressed input. This skill is the
reliable recipe.

## When to Use

- A `nix build` fails with an `ort-sys` / ONNX Runtime download error or any
  "failed to fetch" during `cargo build`.
- The app downloads binaries or models from `github.com` / a CDN at runtime, and
  you need it fully functional offline.
- A dependency's version floor is above the nixpkgs version.
- You are writing a flake for a project with both a Cargo workspace and a
  `pyproject.toml` whose `build-backend = "maturin"`.
- Don't use for: pure-Rust projects with no ONNX (just `buildRustPackage`), or
  Python projects with no compiled extension (use uv2nix/pyproject.nix alone).

## Step 1 — Confirm the ONNX download is the blocker

Find who enables `ort/download-binaries`:

```sh
grep -rn "ort\|fastembed\|magika" **/Cargo.toml
grep -A4 '^name = "ort-sys"' Cargo.lock   # note the exact ort version
```

`fastembed`'s default (and its `ort-download-binaries-*` features) enable
`ort/download-binaries`. Cargo unifies features across the workspace, so
switching the one crate that requests it flips the whole workspace.
**Done when** you can name the single dependency line that triggers the download.

## Step 2 — Patch to `ort-load-dynamic` (surgical, one problem)

Change only the offending feature (e.g. `ort-download-binaries-rustls-tls` →
`ort-load-dynamic`). `load-dynamic` makes `ort` `dlopen` libonnxruntime at
runtime instead of linking a downloaded one. Apply with
`pkgs.applyPatches { src = raw; patches = [ ./patches/00xx-*.patch ]; }` and
build from the patched tree. Write a header explaining why.
**Done when** the patch applies cleanly and only one feature line changed.

## Step 3 — Provide ONNX Runtime from nixpkgs

`load-dynamic` needs the shared library at build/test/run time via
`ORT_DYLIB_PATH`:

```nix
ortDylib = "${pkgs.onnxruntime}/lib/libonnxruntime${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
# set env.ORT_DYLIB_PATH = ortDylib in each derivation, AND wrap installed exes:
postInstall = ''wrapProgram $out/bin/<name> --set-default ORT_DYLIB_PATH "${ortDylib}"'';
```

**Done when** `ORT_DYLIB_PATH` is set in the build env and baked into wrappers.

## Step 4 — Build the Rust binary with `buildRustPackage`

A pyo3 `extension-module` cdylib in the same workspace is NOT plain-cargo
buildable (it needs maturin). Scope `buildRustPackage` to the real binary crate
and vendor from the committed lock — no crane needed for a workspace that
vendors cleanly:

```nix
rustPlatform.buildRustPackage {
  pname = "<binary-crate>";
  src = patchedSrc;
  cargoLock.lockFile = "${patchedSrc}/Cargo.lock";
  buildAndTestSubdir = "crates/<binary-crate>";   # excludes the cdylib crate
  nativeBuildInputs = [ pkgs.pkg-config pkgs.cmake pkgs.perl ]; # aws-lc-rs/rusqlite
  buildInputs = [ pkgs.onnxruntime ];
  dontUseCmakeConfigure = true;   # cmake is codegen tooling; there is no CMakeLists
  env.ORT_DYLIB_PATH = ortDylib;
  checkFlags = [ "--skip=<live_test>" ]; # skip only net E2E; keep wiremock
}
```

Run clippy as a separate check derivation (`cargo clippy ... -- --deny warnings`).
**Done when** `nix build .#<binary>` produces `result/bin/<binary>`.

## Step 5 — Build the maturin wheel, then compose the app

Split the compiled wheel from the dependency-heavy app so the slow Rust compile
is a separate cacheable derivation:

- **compiled package** — `buildPythonPackage { pyproject = true; }` with
  `rustPlatform.maturinBuildHook` + `cargoSetupHook`, `cargoDeps =
  rustPlatform.importCargoLock { lockFile = ...; }`, `buildInputs =
  [ onnxruntime ]`, `env.ORT_DYLIB_PATH = ortDylib`, minimal `dependencies`,
  `pythonImportsCheck = [ "<pkg>._core" ]`. Drop binary-only PyPI wheels via
  `pythonRemoveDeps`.
- **app** — a `stdenv.mkDerivation` (or another `buildPythonPackage`) that puts
  `python.withPackages (_: [ compiledPkg ] ++ extraDeps)` behind a `makeWrapper`
  and runs the real pytest suite against the source with the full dep set.

Group dependency lists with `builtins.attrValues { inherit (py) a b c; }` rather
than `with py; [ ... ]`.
**Done when** both `nix build`s succeed and the wheel imports its `_core`.

## Step 6 — Turn runtime downloads into build inputs (offline)

Grep the source for `urlopen`, `urllib.request`, `requests.get`,
`github.com/.../releases`, `download`. Each hit is a runtime network dependency
to eliminate:

- **Helper binaries** (e.g. `difft`, `scc`, `rtk`): the code usually calls
  `shutil.which(tool)` before fetching. Put the nixpkgs binary on the app's PATH
  (`makeWrapper --prefix PATH`) and the test PATH, so `which` resolves it and no
  fetch runs. Set the project's offline env var (e.g.
  `HEADROOM_BINARIES_OFFLINE=1`) so any missed path fails closed instead of
  hitting the network.
- **Model / vocab files** (e.g. tiktoken BPE vocabs): fetch each as a
  fixed-output derivation (`fetchurl` with a pinned `hash` — the one place the
  sandbox permits network), assemble the on-disk cache layout the library
  expects, and point its cache env var (e.g. `TIKTOKEN_CACHE_DIR`) at it. Now
  the tests run offline instead of being skipped.

**Done when** grepping for network calls leaves only paths that are gated by an
on-PATH binary or a pre-seeded cache, and the offline env var is set.

## Step 7 — Close dependency version gaps in place

When a dependency floor is above nixpkgs, bump the nixpkgs recipe rather than
relaxing the pin:

- **Pure-Python dep** — `pkg.overridePythonAttrs (old: rec { version = "X";
  src = fetchFromGitHub { ... tag = "vX"; hash = ...; }; })`. Re-target any
  version-specific `postPatch` substitution the recipe carries.
- **Rust CLI dep** — `pkgs.<tool>.overrideAttrs (old: rec { version = "X"; src =
  fetchFromGitHub { ... }; cargoDeps = rustPlatform.fetchCargoVendor { inherit
  src; name = "<tool>-X-vendor"; hash = ...; }; })`.

Prefer nixpkgs-unstable over a source build when it has a close-enough version.
If no acceptable version exists anywhere and a source build is infeasible (e.g.
PyTorch), document the gap explicitly instead of silently dropping the feature —
note whether the import is lazy (feature degrades) or hard (app breaks).
**Done when** each gap is either packaged at the required version or documented
with its runtime impact.

## Step 8 — Handle sandbox-only tests

Never disable a whole suite. Deselect only individual cases that need the
network, a spawnable server, `/bin/bash`, or a distinct file mtime the build
tmpfs cannot provide. Prefer pytest `--deselect=<nodeid>` / `--ignore=<path>`
and, for Rust, `checkFlags = [ "--skip=<test>" ]` over broad
`cargoTestExtraArgs`. Record a one-line reason per entry.
**Done when** the build runs the hermetic tests and they pass, and every skip
has a documented sandbox reason.

## Common Pitfalls

1. **Trying to make `download-binaries` work offline.** It won't in the sandbox.
   Use `load-dynamic` + nixpkgs `onnxruntime`; don't fight the fetch.
2. **Building the cdylib crate with cargo.** A pyo3 `extension-module` cdylib
   only links through maturin. Scope the Rust build to the binary crate with
   `buildAndTestSubdir`.
3. **Forgetting the runtime wrapper.** Setting `ORT_DYLIB_PATH` only at build
   time leaves the installed binary unable to find ONNX at runtime — wrap it.
4. **Only fixing the tests, not the app.** Putting a helper binary on the test
   PATH but not the installed wrapper's PATH makes the tests pass while the
   shipped CLI still tries to download at runtime. Do both.
5. **Flake can't see a new file.** `nix` only reads git-tracked files: `git add`
   every new `.nix` before `nix build`, or you get "path … is not tracked".
6. **Doubled vendor name on a Rust override.** Overriding `cargoDeps` on a recipe
   that set `cargoHash` yields a `<name>-vendor-vendor` derivation; set an
   explicit `name` and read the "got:" hash from the first build.
7. **Relaxing a pin the upstream set on purpose.** A `<1.0` cap often guards
   against a breaking major (different return types). Relaxing it makes a feature
   silently no-op. Package the pinned line or document the gap.

## Verification Checklist

- [ ] `nix build` for the binary and the composed app both succeed
- [ ] Every installed executable has `ORT_DYLIB_PATH` set via a wrapper
- [ ] Grepping the source for network calls leaves only on-PATH-binary or
      pre-seeded-cache paths; the offline env var is set in the check phase
- [ ] Each helper binary is on BOTH the test PATH and the installed wrapper PATH
- [ ] Each dependency version gap is packaged or documented with runtime impact
- [ ] Patches are one file / one problem / minimal diff, with a rationale header
- [ ] No whole test suite disabled; each skip has a one-line sandbox reason
