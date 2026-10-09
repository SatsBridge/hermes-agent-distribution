# gh-token-manager

Issue a GitHub App user access token with GitHub's device authorization flow. Device flow must be enabled in the GitHub App settings.

```sh
gh-token-manager --client-id YOUR_APP_CLIENT_ID --username YOUR_GITHUB_LOGIN --scope offline_access
# or set GITHUB_APP_CLIENT_ID
```

`--username` is required: the access token is checked against GitHub's `/user` endpoint, then printed with the verified login in the JSON output. The program stores tokens in a shared JSON cache under `gh-token-manager/token.json`. Its `clients` map is keyed by client ID; each value is a `ClientTokens` structure with a username-keyed `users` map. Each `UserTokens` value holds `{ token, repository_tokens }`, where `repository_tokens` is keyed by the repository ID string. GitHub documents `repository_id` as a string parameter; pass the repository's ID text, such as `--repository-id 123456789`. An unrestricted request uses `token`; a request with `--repository-id` uses only that repository's entry, so both forms can coexist per user. The cache lives under the path returned by `dirs::state_dir()` (falling back to `dirs::data_local_dir()`) and has owner-only permissions. A matching valid cache is reused by default; expired access tokens are refreshed, and a missing/expired refresh token starts device authorization. `--reauthenticate` invalidates the cached token and starts device authorization. Add `--repository-id ID` with the repository's ID string to request a one-repository restriction; GitHub may ignore it if the app or user cannot access that repository. It is part of the cache identity. Treat stdout and the cache as credentials; avoid shell tracing and logs.

GitHub Apps do not accept configurable permission lists or OAuth scopes in this flow. `offline_access` is the only supported scope, used to request expiring access and refresh tokens. Fine-grained permissions are configured on the GitHub App, and the resulting user token is limited by both the app's permissions and the user's access. GitHub's device-flow token exchange supports a single `repository_id` restriction; GitHub may ignore it if the app or user lacks access to that repository.

Build/package using the repository flake:

```sh
nix build .#gh-token-manager
```

`nix develop` installs the Rust Clippy hook using `prek`. `nix fmt` formats Nix and Rust sources with `treefmt`; `nix flake check` verifies formatting, runs Clippy, and builds/tests the package.

Coverage uses `cargo-llvm-cov` with LLVM's line and branch reporting:

```sh
nix develop
RUSTC_BOOTSTRAP=1 cargo llvm-cov --manifest-path gh-token-manager/Cargo.toml --branch --json \
  --output-path gh-token-manager/target/coverage.json
python3 gh-token-manager/check_coverage.py gh-token-manager/target/coverage.json
```

The checker fails unless production line and branch coverage both reach 95%; test/mock helpers are excluded from instrumentation. `nix flake check` runs the same coverage gate. The dev shell exports `LLVM_COV` and `LLVM_PROFDATA` for this command.
