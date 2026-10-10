# rtk (Rust Token Killer): a standalone Rust CLI from rtk-ai/rtk that Headroom
# shells out to for command-output compression. Headroom pins v0.42.4 and would
# otherwise download a prebuilt binary from GitHub releases at runtime (see
# headroom/rtk/installer.py) — not allowed: the app must work offline and
# non-Nixpkgs binaries must be built from source.
#
# nixpkgs 26.05 has rtk 0.41.0, below the pin. nixpkgs-unstable ships 0.43.0
# (>= the pinned floor), so it is taken from there per the brief ("use
# nixos-unstable when the 26.05 dependency is too old") rather than a
# hand-maintained source bump. rtk is a standalone binary with no Python-ABI
# entanglement, so pulling it from a second nixpkgs is safe. The result is put
# on the `headroom` CLI's PATH; `get_rtk_path()` finds it via
# `shutil.which("rtk")` and never reaches the network.
{ unstable }: unstable.rtk
