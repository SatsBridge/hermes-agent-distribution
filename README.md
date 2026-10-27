# Hermes Agent distribution

A Nix flake that packages [Hermes Agent](https://hermes-agent.nousresearch.com/)
and its supporting tools. It also runs isolated Hermes agents on NixOS.

## Summary

This repository supplies these items:

- **Hermes Agent 0.22.2.** The package builds the Nous Research release from
  source. It adds 23 local patches, the terminal UI, and the web dashboard.
- **The NixOS module `hermes-specialised-agent`.** The module runs one or more
  Hermes agents as systemd services. Each agent has its own user, state
  directory, network namespace, firewall rules, and read-only Nix store view.
- **Headroom 0.41.0.** Headroom is a proxy that decreases the quantity of LLM
  tokens. The module can start one Headroom proxy for each agent.
- **gh-token-manager.** A Rust tool that gets GitHub App user access tokens
  through the device authorization flow.
- **Tests.** A NixOS VM fixture tests the module. CI builds all flake checks for
  each push and each pull request.

The builds are reproducible and do not use the network. The flake pins all
sources. Tools that upstream downloads at runtime are build inputs here.

Supported systems are `x86_64-linux` and `aarch64-linux`. The VM fixture and
the module configuration check are available on `x86_64-linux` only.

### Flake outputs

| Output | Contents |
| --- | --- |
| `packages.<system>` | `gh-token-manager`, `headroom`, `headroom-proxy`, `headroom-py`, `headroom-hermes-plugin` |
| `packages.x86_64-linux` | The packages above and `hermes-module-vm-config-check` |
| `apps.<system>` | `gh-token-manager`, `headroom`, `headroom-proxy` |
| `devShells.<system>` | One shell for each package in `packages` |
| `overlays.default` | All packages in `pkgs/by-name`, `hermes-agent` included |
| `nixosModules.hermes-specialised-agent` | The NixOS module |
| `nixosConfigurations` | The VM fixture and its two variants |
| `checks.<system>` | Package builds and tests, git hooks, coverage, formatting |
| `githubActions` | The CI build matrix |

The flake has no `default` package. Give the package name in each command. The
flake does not export `hermes-agent` as a top-level package. Get it from the
overlay (refer to [step 2](#2-build-the-hermes-agent-cli)).

## Quickstart

### Requirements

- Nix with the `nix-command` and `flakes` experimental features.
- For the NixOS module: a NixOS host with the firewall enabled.
- For the VM test: an `x86_64-linux` host.

If flakes are not enabled, add this option to each `nix` command:

```sh
--extra-experimental-features 'nix-command flakes'
```

Steps 1, 2, 4, and 5 use the repository root as the working directory:

```sh
git clone https://github.com/SatsBridge/hermes-agent-distribution.git
cd hermes-agent-distribution
```

### 1. Run the tools

```sh
nix run .#headroom -- --help
nix run .#headroom-proxy -- --help
nix run .#gh-token-manager -- --help
```

### 2. Build the Hermes Agent CLI

The VM configuration applies `overlays.default`. Thus you can build
`hermes-agent` from its package set:

```sh
nix build .#nixosConfigurations.hermes-module-vm.pkgs.hermes-agent
./result/bin/hermes --version
```

This command builds for `x86_64-linux`. On other systems, apply
`overlays.default` to your own Nixpkgs instance.

### 3. Run agents on a NixOS host

Add this flake as an input. Then import the module and the overlay. The module
uses `pkgs.hermes-agent` and `pkgs.headroom` from the overlay.

```nix
{
  inputs = {
    hermes.url = "github:SatsBridge/hermes-agent-distribution";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { hermes, nixpkgs, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        modules = [
          ./configuration.nix
          hermes.nixosModules.hermes-specialised-agent
          { nixpkgs.overlays = [ hermes.overlays.default ]; }
          {
            services.hermes-specialised-agent = {
              enable = true;
              mainAgent = "main";
              agents.main = {
                enable = true;
                fullName = "hermes-main";
                headroomPort = 18080;
                settings.toolsets = [ "all" ];
              };
            };
          }
        ];
        system = "x86_64-linux";
      };
    };
}
```

The flake tests the module and the packages with `nixos-unstable`.

Do these steps to start the agent:

1. Apply the configuration from the directory of your host flake:

   ```sh
   sudo nixos-rebuild switch --flake .#myhost
   ```

2. Write the API keys of your model provider into
   `/var/lib/hermes-main/.hermes/.env`. The module creates this file with
   mode `0600`.
3. Restart the agent:

   ```sh
   sudo systemctl restart hermes@main.service
   ```

4. Make sure that the agent runs:

   ```sh
   systemctl status hermes@main.service hermes-network@main.service
   journalctl -u hermes@main.service -f
   ```

5. Open the dashboard of the main agent at <http://127.0.0.1:9119>.

> [!WARNING]
> The module changes the network configuration of the full host. Read
> [`nixos/README.md`](nixos/README.md) before you deploy it.

- The firewall backend changes to nftables. The module enables IPv4 and IPv6
  forwarding and NAT.
- `networking.firewall.extraCommands` and `networking.nat.extraCommands` cause
  the evaluation to fail.
- The host must not use addresses or routes in `198.18.0.0/15` or
  `fd42:198:18::/48`. The module reserves these ranges for the agents.
- An agent can connect only to public addresses and to its DNS proxy. Use
  `networkAllow` to permit a private address or a host address.

### 4. Test the module in a VM

```sh
nix build .#hermes-module-vm-config-check
nix build .#nixosConfigurations.hermes-module-vm.config.system.build.vm
./result/bin/run-nixos-vm
```

The first command does a check of the module configuration without a boot. The
VM starts two agents without network access and without credentials. Wait for
this message on the serial console:

```text
Hermes VM runtime checks passed
```

To stop the VM, push `Ctrl-A c`, then type `quit`. Do not delete
`hermes-module-vm.qcow2` while QEMU runs.

### 5. Develop

```sh
nix develop .#headroom  # Shell with the toolchain and the git hooks
nix fmt                 # Format all files with treefmt
nix flake check         # Build all packages, run the tests and the linters
```

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
The `nix develop .#headroom` shell installs a `convco` git hook that does a
check of each message.

## Repository layout

```text
.
├── flake.nix                     Outputs, VM checks, overlay
├── treefmt.nix                   Formatters for `nix fmt`
├── modules/
│   ├── module-list.nix
│   └── services/agent/hermes.nix NixOS module
├── nixos/
│   ├── README.md                 VM fixture and isolation design
│   └── hermes-module-vm.nix      VM test configuration
├── pkgs/by-name/                 Packages in the Nixpkgs by-name layout
│   ├── gh/gh-token-manager/      GitHub App token tool (Rust)
│   └── he/
│       ├── hermes-agent/         Hermes Agent and its patches
│       ├── headroom/             Headroom CLI and its README
│       ├── headroom-proxy/       Headroom Rust proxy
│       ├── headroom-py/          Headroom compiled Python extension
│       ├── headroom-hermes-plugin/
│       ├── headroom-python-pkgs/ Python dependencies not in Nixpkgs
│       └── headroom-source/      Headroom source pin and patches
├── headroom-nix/AGENTS.md        Notes for coding agents (Headroom)
├── .agents/skills/               Skills for coding agents
├── scripts/                      Maintenance scripts
└── .github/workflows/nix.yml     CI
```

## Components

Some directories have their own README. This section gives a summary of each
component and tells you where to find more data.

### NixOS module

Location: [`modules/services/agent/hermes.nix`](modules/services/agent/hermes.nix)

The module makes three systemd units for each enabled agent `NAME`:

| Unit | Function |
| --- | --- |
| `hermes@NAME.service` | Runs `hermes gateway` and the optional Headroom proxy. The main agent also runs `hermes dashboard`. |
| `hermes-network@NAME.service` | Makes the network namespace, the veth pair, the DNS proxy, and the port proxies. |
| `hermes-pf@NAME.service` | Sets ACLs that let other agents read the shared state. It has no network access. |

Each agent keeps its state in `/var/lib/hermes-NAME/.hermes`. This directory
holds `config.yaml`, `.env`, skills, memories, sessions, logs, and plugins.
All agents share the Kanban state in `/var/lib/hermes-shared`. Each agent can
read the profiles of the other enabled agents.

These are the options under `services.hermes-specialised-agent`:

| Option | Default | Function |
| --- | --- | --- |
| `enable` | `false` | Enable the agent services. |
| `mainAgent` | Required | The agent that runs the dashboard. |
| `installDefaultSkills` | `true` | Install five default skills before an agent starts. |
| `agents.<name>.enable` | `false` | Enable this agent. |
| `agents.<name>.fullName` | Required | Unique profile name. Use lowercase letters, numbers, `-`, and `_`. |
| `agents.<name>.package` | `pkgs.hermes-agent` | The Hermes Agent package. |
| `agents.<name>.settings` | `{ }` | Hermes `config.yaml` as an attribute set. Definitions merge deeply. |
| `agents.<name>.extraArgs` | `[ ]` | More arguments for `hermes gateway`. |
| `agents.<name>.extraPlugins` | `[ ]` | Plugin directories to link into the plugins directory. |
| `agents.<name>.headroomEnable` | `true` | Start a Headroom proxy for this agent. |
| `agents.<name>.headroomPort` | Required | The port of the Headroom proxy. |
| `agents.<name>.portMappings` | `null` | Host loopback ports to forward into the namespace. |
| `agents.<name>.networkAllow` | `[ ]` | Private or host destinations that the agent can connect to. |

The module sets `kanban.agent_profile_name` and `kanban.dispatch_profiles` from
`fullName`. These values replace the same keys in `settings`.

The five default skills are `concept-diagrams`, `creative-ideation`,
`ast-grep`, `code-wiki`, and `subagent-driven-development`.

### VM fixture and isolation design

README: [`nixos/README.md`](nixos/README.md)

This README is the main reference for the module. It explains these topics:

- **The VM fixture.** The VM has two agents, `vm` and `vm-peer`. It has 1024 MiB
  of RAM, a 1024 MiB disk, and a read-only 9p Nix store. Headroom is disabled
  in the VM.
- **Network isolation.** The README gives the address plan, the nftables rules,
  the blocked address ranges, and the `networkAllow` syntax.
- **Port mappings.** The README tells how to forward host loopback ports to an
  agent and how to expose the dashboard on a different port.
- **Nix store view.** Each service sees only its own runtime closure. Add
  runtime tools through the service package or `extraPlugins`.
- **Diagnostics and rollback.** The README lists `systemctl`, `nft`, `ip`, and
  `ss` commands for each part of the network setup.
- **Smoke checks.** The README describes each runtime check in the VM and the
  timing report.

The flake has three VM configurations:

| Configuration | Purpose |
| --- | --- |
| `hermes-module-vm` | Offline policy test. This is the default. |
| `hermes-module-vm-internet` | Real DNS and HTTPS test from each agent. |
| `hermes-module-vm-explicit-dashboard` | Dashboard through `127.0.0.1:18199`. |

The internet variant needs outbound DNS and HTTPS on the host. Start it with
`QEMU_NET_OPTS='restrict=off' ./result/bin/run-nixos-vm`.

### Hermes Agent package

Location: [`pkgs/by-name/he/hermes-agent/`](pkgs/by-name/he/hermes-agent/)

The package builds tag `v0.22.2` of `NousResearch/hermes-agent`. It has no
README. These are its important properties:

- **Patches 0001–0002** correct the Kanban worker home and scope Kanban claims
  to the UID.
- **Patches 0003–0023** add service tiers (`flex`, `priority`, fast mode). They
  apply to Gemini, OpenRouter, the TUI, auxiliary models, the curator, and the
  Codex adapter. Patch 0010 adds an opt-in TTFT tier escalation.
- **Frontends.** The `hermes-frontend` derivation builds the terminal UI and
  the web dashboard from the upstream npm workspaces.
- **Wrapper.** `HERMES_MANAGED=nixos` stops `hermes update` from changes to the
  Nix store. `HERMES_DISABLE_LAZY_INSTALLS=1` stops `pip` installs at runtime.
- **Runtime tools.** The wrapper adds `node`, `cosign`, `tirith`,
  `agent-browser`, `playwright`, `chromium`, and `gh` to `PATH`.
- **Optional extras.** The package includes all extras that Nixpkgs has. It
  does not include `honcho`, `daytona`, `dingtalk`, and `feishu`. Matrix
  encryption and voice input are available on Linux only.

### Headroom packages

README: [`pkgs/by-name/he/headroom/README.md`](pkgs/by-name/he/headroom/README.md)

The README describes the four Headroom packages:

| Package | Contents |
| --- | --- |
| `headroom` | The full CLI with all optional runtime dependencies. |
| `headroom-proxy` | The Rust reverse proxy. |
| `headroom-py` | The compiled extension `headroom._core`. |
| `headroom-hermes-plugin` | The `headroom_retrieve` plugin for Hermes Agent. |

Two more directories support these packages. `headroom-source` pins the
upstream release and applies the patches. `headroom-python-pkgs` builds the
Python dependencies that Nixpkgs does not have.

The README also explains how the packages load ONNX Runtime from the Nix store.
If a build cannot find `libonnxruntime`, set `ORT_DYLIB_PATH`.

### Headroom notes for coding agents

File: [`headroom-nix/AGENTS.md`](headroom-nix/AGENTS.md)

This file gives rules for coding agents that change the Headroom packages. It
explains the toolchain choice, the split between Cargo and maturin builds, and
the rules for patches and test skips.

The file uses the paths of the earlier standalone Headroom flake. Use this
table to find the same files in this repository:

| Path in `AGENTS.md` | Path in this repository |
| --- | --- |
| `nix/headroom-source.nix`, `nix/patches/` | `pkgs/by-name/he/headroom-source/` |
| `nix/proxy.nix` | `pkgs/by-name/he/headroom-proxy/package.nix` |
| `nix/headroom-py.nix` | `pkgs/by-name/he/headroom-py/package.nix` |
| `nix/headroom.nix` | `pkgs/by-name/he/headroom/package.nix` |
| `nix/headroom-hermes-plugin.nix` | `pkgs/by-name/he/headroom-hermes-plugin/package.nix` |
| `nix/default.nix` | `flake.nix` |

### gh-token-manager

README: [`pkgs/by-name/gh/gh-token-manager/README.md`](pkgs/by-name/gh/gh-token-manager/README.md)

The tool gets a GitHub App user access token through the device flow. Enable
the device flow in the settings of the GitHub App first.

```sh
nix run .#gh-token-manager -- --client-id YOUR_APP_CLIENT_ID \
  --username YOUR_GITHUB_LOGIN --scope offline_access
```

The README explains these topics:

- The token cache, its JSON format, and its owner-only permissions.
- Token refresh, `--reauthenticate`, and `--repository-id`.
- The coverage gate. Line coverage and branch coverage must be 95% or more.

The tool prints the token on stdout. Treat stdout and the cache as credentials.

### Packaging skill for coding agents

File: [`.agents/skills/packaging-maturin-ort-in-nix/SKILL.md`](.agents/skills/packaging-maturin-ort-in-nix/SKILL.md)

This skill tells a coding agent how to package a Rust and Python (maturin)
project for Nix without network access. It covers these steps:

1. Patch `ort` to load ONNX Runtime dynamically.
2. Build the Rust binary and the Python extension as different derivations.
3. Change runtime downloads into build inputs.
4. Increase dependency versions in place when Nixpkgs is too old.
5. Skip only the tests that need the network.

### Tooling and CI

- [`treefmt.nix`](treefmt.nix) sets the formatters and the linters for
  `nix fmt`. They include `nixfmt`, `deadnix`, `statix`, `rustfmt`, `rumdl`,
  `yamllint`, `actionlint`, and `zizmor`. Each package also has its own
  `treefmt.nix`.
- [`scripts/sort_nix_declarations.py`](scripts/sort_nix_declarations.py) sorts
  the names of declarations in the Nix files. By default, it only shows the
  changes. Add `--write` to change the files. Do not use `--write` on `inherit`
  lines that have comments.
- [`.github/workflows/nix.yml`](.github/workflows/nix.yml) reads the
  `githubActions` matrix from the flake. Then it builds each check on each
  system.
