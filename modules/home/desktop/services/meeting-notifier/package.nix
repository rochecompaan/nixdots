{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "meeting-notifier";
  version = "0.1.0";

  src = lib.cleanSource ./.;
  vendorHash = "sha256-PGqk2X8qw8zLFpT0L8vslqNyHcJ5h4bwe4MKI6S8KTg=";

  subPackages = [ "cmd/meeting-notifier" ];

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Actionable Google Calendar meeting notifications for Niri";
    homepage = "https://github.com/rochecompaan/nixdots";
    license = lib.licenses.mit;
    mainProgram = "meeting-notifier";
    platforms = lib.platforms.linux;
  };
}
