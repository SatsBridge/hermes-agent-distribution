{
  description = "Small Rust utilities packaged with nixpkgs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          gh-token-manager = pkgs.rustPlatform.buildRustPackage {
            pname = "gh-token-manager";
            version = "0.1.0";
            src = ./gh-token-manager;
            nativeBuildInputs = [ pkgs.cacert ];
            cargoLock.lockFile = ./gh-token-manager/Cargo.lock;
          };
          default = self.packages.${system}.gh-token-manager;
        });
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.mkShell {
            packages = builtins.attrValues {
              inherit (pkgs) cargo rustc clippy rustfmt cacert;
              llvm = pkgs.llvmPackages.llvm;
            };
          };
        });
    };
}
