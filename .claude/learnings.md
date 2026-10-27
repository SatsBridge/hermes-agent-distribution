# Learnings

## 2026-10-27

- Use case: building software. The repository is a Nix flake for Hermes Agent,
  Headroom, gh-token-manager, and the `hermes-specialised-agent` NixOS module.
- `nix fmt` runs `rumdl` on all tracked Markdown files, `.claude/` included.
  Run `nix fmt -- FILE` after each Markdown change.
- The flake has no `default` package and no top-level `hermes-agent` output.
  Build the CLI with `.#nixosConfigurations.hermes-module-vm.pkgs.hermes-agent`.
- `headroom-nix/AGENTS.md` uses the paths of the old standalone flake
  (`nix/*.nix`). `README.md` has a table that maps them to `pkgs/by-name`.
- `pkgs/by-name/he/headroom/README.md` says that `default` is
  `gh-token-manager`. This is not true. Open question: correct it or add the
  output?
- Decision: `README.md` uses ASD-STE100. Its component sections give a summary
  of each embedded README and do not copy it.
