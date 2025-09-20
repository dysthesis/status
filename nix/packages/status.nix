{
  alsa-lib,
  pkg-config,
  zig,
  stdenv,
  lib,
  makeWrapper,
  ...
}:
stdenv.mkDerivation {
  pname = "status";
  version = "0.1.0";
  src = ../..;
  buildInputs = [
    alsa-lib
  ];
  nativeBuildInputs = [
    zig.hook
    pkg-config
    makeWrapper
  ];

  zigBuildFlags = [
    "--release=small"
  ];
  postInstall = let
    libPath = lib.makeLibraryPath [ alsa-lib ];
  in ''
    wrapProgram $out/bin/status \
      --prefix LD_LIBRARY_PATH : ${libPath}
  '';
  meta.mainPackage = "status";
}
