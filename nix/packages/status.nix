{
  zig,
  zigStdenv,
  ...
}:
zigStdenv.mkDerivation {
  pname = "status";
  version = "0.1.0";
  src = ../..;
  nativeBuildInputs = [zig.hook];
}
