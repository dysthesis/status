{
  self,
  pkgs,
  lib,
  inputs,
  ...
}: rec {
  default = status;
  status = pkgs.callPackage ./status.nix {inherit pkgs inputs lib self;};
}
