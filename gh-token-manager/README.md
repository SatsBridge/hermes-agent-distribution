# gh-token-manager

Issue a GitHub App user access token with GitHub's device authorization flow. Device flow must be enabled in the GitHub App settings.

```sh
gh-token-manager --client-id YOUR_APP_CLIENT_ID --username YOUR_GITHUB_LOGIN --scope offline_access
# or set GITHUB_APP_CLIENT_ID
```

`--username` is required: the access token is checked against GitHub's `/user` endpoint, then printed with the verified login in the JSON output. The program caches tokens in the path returned by `dirs::state_dir()` (falling back to `dirs::data_local_dir()`), under `gh-token-manager/token.json`, with owner-only permissions. A valid cache is reused by default; expired access tokens are refreshed, and a missing/expired refresh token starts device authorization. `--reauthenticate` invalidates the cached token and starts device authorization. Add `--repository-id ID` with GitHub's numeric repository ID to restrict the token to one repository; it is part of the cache identity. Treat stdout and the cache as credentials; avoid shell tracing and logs.

GitHub Apps do not accept configurable permission lists or OAuth scopes in this flow. `offline_access` is the only supported scope, used to request expiring access and refresh tokens. Fine-grained permissions are configured on the GitHub App, and the resulting user token is limited by both the app's permissions and the user's access. GitHub's device-flow token exchange supports a single `repository_id` restriction; pass it with `--repository-id`.

Build/package using the repository flake (the only flake input is nixpkgs):

```sh
nix build .#gh-token-manager
```

Coverage follows [rustc's instrumentation documentation](https://doc.rust-lang.org/rustc/instrument-coverage.html) and uses matching LLVM tools from `nix develop`:

```sh
nix develop
mkdir -p gh-token-manager/target/coverage
rm -f gh-token-manager/target/coverage/*.profraw gh-token-manager/target/coverage/coverage.profdata
CARGO_TARGET_DIR="$PWD/gh-token-manager/target/coverage-build" \
RUSTFLAGS="-Cinstrument-coverage" \
LLVM_PROFILE_FILE="$PWD/gh-token-manager/target/coverage/%p-%m.profraw" \
cargo test --manifest-path gh-token-manager/Cargo.toml
llvm-profdata merge -sparse gh-token-manager/target/coverage/*.profraw \
  -o gh-token-manager/target/coverage/coverage.profdata
TEST_BIN=$(for path in gh-token-manager/target/coverage-build/debug/deps/gh_token_manager-*; do
  if [ -x "$path" ]; then printf '%s\n' "$path"; break; fi
done)
llvm-cov report "$TEST_BIN" \
  -instr-profile=gh-token-manager/target/coverage/coverage.profdata \
  --ignore-filename-regex='/.cargo/registry/|/rustc/'
```

Use the instrumented test executable path printed by `cargo test`; coverage artifacts stay under the ignored `target/` directory.
