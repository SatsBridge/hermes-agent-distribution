# treefmt-nix configuration shared by `nix fmt`, the treefmt git hook, and the
# devShell. Every formatter listed in the packaging brief is enabled here.
_: {
  projectRootFile = "headroom-nix/nix/treefmt.nix";

  programs = {
    # Nix
    nixfmt = {
      enable = true;
      strict = true;
    };
    deadnix.enable = true;
    statix.enable = true;
    nixf-diagnose.enable = true;

    # Shell
    beautysh.enable = true;

    # YAML / GitHub Actions
    yamlfmt.enable = true;
    yamllint = {
      enable = true;
      # Every rule relaxed here is tripped by the task-mandated workflow file,
      # which must stay byte-for-byte: SHA-pinned `uses:` lines run past 80 cols
      # (line-length) and carry `# vX.Y.Z` tag comments (comments); it opens at
      # `name:` with no `---` (document-start) and uses the YAML 1.1 truthy `on:`
      # key (truthy). Nothing else is relaxed.
      settings.rules = {
        line-length = "disable";
        document-start = "disable";
        truthy = "disable";
        comments = "disable";
      };
    };
    actionlint.enable = true;
    pinact = {
      enable = true;
      # `pinact run` enforces that every action is pinned to a full SHA. Its
      # `--update`/`--verify` modes call the GitHub API to refresh/cross-check
      # tags; disable them so the formatter is hermetic (run `nix fmt` locally
      # to refresh pins). The workflow is already SHA-pinned, so this is a no-op
      # check, not a rewrite.
      update = false;
      verify = false;
    };
    zizmor.enable = true;

    # Markdown
    rumdl-check.enable = true;
    rumdl-format.enable = true;
  };

  settings.global.excludes = [
    # Lockfiles and generated data — never hand-formatted.
    "*.lock"
    "flake.lock"
    ".gitignore"
  ];
}
