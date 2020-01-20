let
  unstable = import (fetchTarball https://nixos.org/channels/nixos-unstable/nixexprs.tar.xz) { };
in
{ stdenv, fetchFromGitHub, cmake, llvmPackages, libxml2, zlib }:

unstable.stdenv.mkDerivation rec {
  version = "7a1cde7206263c8bb3265c225ed4213d1b7bdb58";
  pname = "zig";

  src = unstable.fetchFromGitHub {
    owner = "ziglang";
    repo = pname;
    rev = version;
    sha256 = "1wg41wcy4sni9zm1m637a8s5fl2as9mr18vwyym3krzx9xwiz3y0";
  };

  patches = [
    ./allow-async-fn-ptr-hack.patch
  ];

  nativeBuildInputs = [ unstable.cmake ];
  buildInputs = [ unstable.llvmPackages_9.clang-unwrapped unstable.llvmPackages_9.llvm unstable.libxml2 unstable.zlib ];

  preBuild = ''
    export HOME=$TMPDIR;
  '';

  meta = with stdenv.lib; {
    description = "Programming languaged designed for robustness, optimality, and clarity";
    homepage = https://ziglang.org/;
    license = licenses.mit;
    platforms = platforms.unix;
    maintainers = [ maintainers.andrewrk ];
  };
}
