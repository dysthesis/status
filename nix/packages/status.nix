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

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    export HOME="$TMPDIR"
  '';

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
