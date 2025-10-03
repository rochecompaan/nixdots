{ pkgs, ... }:

pkgs.stdenv.mkDerivation rec {
  pname = "ziti-cli";
  version = "1.6.8";

  src = pkgs.fetchTarball {
    url = "https://github.com/openziti/ziti/releases/download/v${version}/ziti-linux-amd64-${version}.tar.gz";
    sha256 = "sha256:0s0lbh7cd0c4hmdiaa6cmlddri2ggx020wv3d2b34yazz2jflzfn";
  };

  installPhase = ''
    install -m755 -d $out/bin/
    install -m755 -D ./ziti $out/bin/
  '';
}
