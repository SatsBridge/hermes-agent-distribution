# Per-system assembly. flake.nix imports this once per system and reads the
# packages / apps / checks / formatter / devShell attributes off the result.
{
  pkgs,
  unstable,
  codebaseMemory,
  lib,
  system,
  treefmt-nix,
  git-hooks,
}:
let
  headroomSource = import ./headroom-source.nix { inherit pkgs; };
  headroomPythonPackages = import ./headroom-python.nix { inherit pkgs unstable; };

  # treefmt wrapper — the `nix fmt` formatter and the engine behind the treefmt
  # git hook. Built explicitly so the exact same wrapper backs `formatter`, the
  # hook, and the devShell.
  treefmt = (treefmt-nix.lib.evalModule pkgs ./treefmt.nix).config.build.wrapper;

  # callPackage wires each package's `pkgs`/`lib` args automatically and lets a
  # consumer override any single dependency via `.override`. The extra args each
  # file needs (headroomSource and the sibling packages) are passed explicitly.

  # rtk: standalone Rust CLI (rtk-ai/rtk) Headroom shells out to. nixpkgs 26.05
  # has 0.41.0, below Headroom's 0.42.4 pin; nixpkgs-unstable has 0.43.0, so it
  # comes from unstable. Provided on the headroom CLI's PATH so nothing is
  # fetched from GitHub at runtime.
  rtk = pkgs.callPackage ./rtk.nix { inherit unstable; };

  # headroom-proxy: the Rust reverse-proxy binary.
  headroom-proxy = pkgs.callPackage ./headroom-proxy.nix {
    inherit headroomSource;
    inherit (unstable) onnxruntime;
  };

  # headroom-py: the compiled Rust extension `headroom._core` as a standalone
  # Python package (maturin cdylib), stripped to just the `.so`.
  headroom-py = pkgs.callPackage ./headroom-py.nix {
    inherit headroomSource;
    inherit (unstable) onnxruntime;
  };

  # headroom: the full Python distribution (pure-Python `headroom/` + the CLI),
  # depending on headroom-py for the compiled core.
  headroom = pkgs.callPackage ./headroom.nix {
    inherit
      headroomSource
      headroom-py
      headroom-proxy
      rtk
      ;
    codebaseMemoryMcp = codebaseMemory;
    python3Packages = headroomPythonPackages;
    inherit (unstable) onnxruntime;
  };

  # headroom-hermes-plugin: the Hermes-Agent CCR retrieve plugin
  # (plugins/hermes) packaged as an installable plugin tree.
  headroom-hermes-plugin = pkgs.callPackage ./headroom-hermes-plugin.nix { inherit headroomSource; };

  # clippy lint of the proxy crate, exposed as a check.
  headroom-proxy-clippy = headroom-proxy.passthru.clippy;

  # git-hooks bundle: convco + treefmt (fail-on-change). Also the source of the
  # devShell's enabledPackages and shellHook.
  gitHooks = git-hooks.lib.${system}.run {
    src = ../.;
    package = pkgs.prek;
    hooks = {
      convco.enable = true;
      treefmt = {
        enable = true;
        package = treefmt;
        settings.fail-on-change = true;
      };
    };
  };

  packages = {
    inherit
      headroom-proxy
      headroom-py
      headroom
      headroom-hermes-plugin
      ;
    default = headroom;
  };

  apps = {
    headroom-proxy = {
      type = "app";
      program = lib.getExe headroom-proxy;
    };
    headroom = {
      type = "app";
      program = lib.getExe headroom;
    };
    default = {
      type = "app";
      program = lib.getExe headroom;
    };
  };
in
{
  inherit packages apps;

  formatter = treefmt;

  # `nix flake check` runs these: both package builds with their bundled test
  # suites, the clippy lint, and the git-hooks bundle (treefmt fail-on-change).
  checks = {
    inherit (packages)
      headroom-proxy
      headroom-py
      headroom
      headroom-hermes-plugin
      ;
    clippy = headroom-proxy-clippy;
    git-hooks = gitHooks;
  };

  devShell = pkgs.mkShell {
    inputsFrom = [
      headroom-proxy
      headroom
    ];
    packages =
      gitHooks.enabledPackages
      ++ builtins.attrValues {
        inherit (pkgs)
          rustc
          cargo
          maturin
          uv
          ;
      }
      ++ [ treefmt ];
    inherit (gitHooks) shellHook;
  };
}
