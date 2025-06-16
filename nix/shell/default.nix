{
  pkgs,
  self,
  ...
}:
pkgs.mkShell {
  name = "status";

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
