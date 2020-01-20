with import <nixpkgs> {};

let
  zig-compiler = callPackage ./zig-compiler.nix {};
in
  stdenv.mkDerivation rec {
    name = "zig-nes";
    buildInputs = [ zig-compiler ];
    buildPhase = "HOME=$TMPDIR zig build-exe $src/src/main.zig";
    installPhase = "install -m555 -D ./main $out/bin/zig-nes";
    src = builtins.fetchGit ./.;
  }
