{ pkgs, ... }:
pkgs.mkShell {
  name = "status";
  buildInputs = with pkgs; [
    alsa-lib
  ];

  packages = with pkgs; [
    nixd
    alejandra
    statix
    deadnix
    zig
    zls
    zlint
    pkg-config
  ];

  shellHook = let
    libPath = pkgs.lib.makeLibraryPath [ pkgs.alsa-lib ];
  in ''
    export LD_LIBRARY_PATH="${libPath}:$LD_LIBRARY_PATH"
  '';
}
