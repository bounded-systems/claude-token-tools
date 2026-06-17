{
  description = "Claude Code token-saving toolkit — model-usage auditor + home-manager module";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          # CLI wrapper: bun runs the pre-built bundle (no node_modules at runtime).
          model-usage = pkgs.writeShellScriptBin "claude-model-usage" ''
            exec ${pkgs.bun}/bin/bun run ${./skills/model-usage/audit.bundle.js} "$@"
          '';
          default = self.packages.${system}.model-usage;
        }
      );

      homeManagerModules = {
        default = import ./modules/home-manager.nix;
        claude-token-tools = import ./modules/home-manager.nix;
      };
    };
}
