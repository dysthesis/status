{
  description = "dwl status bar";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Personal library
    nixpressions = {
      url = "github:dysthesis/nixpressions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs @ {
    self,
    nixpressions,
    nixpkgs,
    treefmt-nix,
    ...
  }: let
    inherit (builtins) mapAttrs;
    inherit (nixpressions) mkLib;
    lib = mkLib nixpkgs;

    # Systems to support
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];

    forAllSystems = lib.nixpressions.forAllSystems {inherit systems;};

    treefmt = forAllSystems (pkgs: treefmt-nix.lib.evalModule pkgs ./nix/formatters);
  in
    # Budget flake-parts
    mapAttrs (_: forAllSystems) {
      devShells = pkgs: {default = import ./nix/shell {inherit pkgs self;};};
      # for `nix fmt`
      formatter = pkgs: treefmt.${pkgs.system}.config.build.wrapper;
      # for `nix flake check`
      checks = pkgs: let
        # helper to define simple command-based checks
        runCheck = {
          name,
          tools ? [],
          script,
        }:
          pkgs.stdenv.mkDerivation {
            pname = name;
            version = "0";
            src = self;
            nativeBuildInputs = tools;
            buildPhase = script;
            installPhase = ''
              mkdir -p "$out"
              printf "%s\n" ok >"$out/result"
            '';
          };
      in {
        formatting = treefmt.${pkgs.system}.config.build.check self;

        statix = runCheck {
          name = "statix-check";
          tools = [pkgs.statix];
          script = ''
            statix check .
          '';
        };
        deadnix = runCheck {
          name = "deadnix-check";
          tools = [pkgs.deadnix];
          script = ''
            deadnix --fail .
          '';
        };

        zig-build = runCheck {
          name = "zig-build-check";
          tools = [
            pkgs.zig
            pkgs.pkg-config
          ];
          script = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            export HOME="$TMPDIR"
            zig build
          '';
        };
        zig-tests = runCheck {
          name = "zig-tests-check";
          tools = [
            pkgs.zig
            pkgs.pkg-config
          ];
          script = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            export HOME="$TMPDIR"
            zig build test
          '';
        };
      };
      packages = pkgs:
        import ./nix/packages {
          inherit
            self
            pkgs
            inputs
            lib
            ;
        };
    };
}
