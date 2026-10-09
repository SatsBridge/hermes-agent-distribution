# gh-token-manager

Issue a GitHub App user access token with GitHub's device authorization flow. Device flow must be enabled in the GitHub App settings.

```sh
gh-token-manager --client-id YOUR_APP_CLIENT_ID --scope offline_access
# or set GITHUB_APP_CLIENT_ID
```

The program prints JSON containing the access token and, when issued, its refresh token to stdout. It caches both tokens in the path returned by `dirs::state_dir()` (falling back to `dirs::data_local_dir()`), under `gh-token-manager/token.json`, with owner-only permissions. A valid cached access token is reused; an expiring token is refreshed automatically when possible, and an expired/missing refresh token starts device authorization again. `--reauthenticate` forces a new device authorization. Treat stdout and the cache as credentials; avoid shell tracing and logs.

GitHub Apps do not accept configurable permission lists or OAuth scopes in this flow. `offline_access` is the only supported scope, used to request expiring access and refresh tokens. Fine-grained permissions are configured on the GitHub App, and the resulting user token is limited by both the app's permissions and the user's access. GitHub's device flow supports an optional repository restriction, but octocrab's device-flow API does not expose it.

Build/package using the repository flake (the only flake input is nixpkgs):

```sh
nix build .#gh-token-manager
```
