{
  pkgs,
  self,
  ...
}:
pkgs.mkShell {
  name = "status";
  buildInputs = with pkgs; [
    musl.dev
  ];

  packages = with pkgs; [
    nixd
    alejandra
    statix
    deadnix
    zig
    zls
    zlint
  ];
}
