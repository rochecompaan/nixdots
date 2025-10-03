{
  lib,
  buildGoModule,
  fetchFromGitHub,
  ...
}:

buildGoModule rec {
  pname = "ziti-cli";
  version = "1.6.8";

  src = fetchFromGitHub {
    owner = "openziti";
    repo = "ziti";
    rev = "v${version}";
    hash = "sha256-J655F9lFRLL1LdNOelRpipiIb2u2HEvVSehvPpRYRUw=";
  };

  # Go modules vendoring hash; will be filled by the first failing build
  vendorHash = "sha256-CD/7WfRf6MEo7V9akA1/gP7b8wUr+2QCjbn6yIJYBYM=";

  # The CLI is provided by the `ziti` subpackage in the repo
  subPackages = [ "ziti" ];

  # Upstream builds with cgo enabled; match that here
  env.CGO_ENABLED = 1;

  ldflags = [
    "-s"
    "-w"
    "-X github.com/openziti/ziti/common/version.Version=${version}"
  ];

  meta = {
    description = "OpenZiti command-line interface";
    homepage = "https://github.com/openziti/ziti";
    license = lib.licenses.asl20;
    mainProgram = "ziti";
    platforms = lib.platforms.unix;
  };
}
