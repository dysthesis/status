{
  musl,
  pkg-config,
  zig,
  stdenv,
  ...
}:
stdenv.mkDerivation {
  pname = "status";
  version = "0.1.0";
  src = ../..;
  buildInputs = [ musl.dev ];
  nativeBuildInputs = [
    zig.hook
    pkg-config
  ];

  zigBuildFlags = [
    "-Dtarget=x86_64-linux-musl" # statically link
    "--release=small"
  ];
  meta.mainPackage = "status";
}
