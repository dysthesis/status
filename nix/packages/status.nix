{
  musl,
  pkg-config,
  zig,
  zigStdenv,
  ...
}:
zigStdenv.mkDerivation {
  pname = "status";
  version = "0.1.0";
  src = ../..;
  buildInputs = [
    musl.dev
  ];
  nativeBuildInputs = [zig.hook pkg-config];
}
