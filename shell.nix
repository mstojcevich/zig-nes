let
  pkgs = import <nixpkgs> {};
  zig-compiler = pkgs.callPackage ./zig-compiler.nix {};
in
pkgs.mkShell {
  buildInputs = [ zig-compiler ];
}
