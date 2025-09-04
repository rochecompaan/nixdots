{
  config,
  lib,
  pkgs,
  ...
}:
let
  browser = [ "firefox" ];
  chromium = lib.getExe pkgs.chromium;
  imageViewer = [ "org.gnome.Loupe" ];
  videoPlayer = [ "io.github.celluloid_player.Celluloid" ];
  audioPlayer = [ "io.bassi.Amberol" ];

  xdgAssociations =
    type: program: list:
    builtins.listToAttrs (
      map (e: {
        name = "${type}/${e}";
        value = program;
      }) list
    );

  image = xdgAssociations "image" imageViewer [
    "png"
    "svg"
    "jpeg"
    "gif"
  ];
  video = xdgAssociations "video" videoPlayer [
    "mp4"
    "avi"
    "mkv"
  ];
  audio = xdgAssociations "audio" audioPlayer [
    "mp3"
    "flac"
    "wav"
    "aac"
  ];
  browserTypes =
    (xdgAssociations "application" browser [
      "json"
      "x-extension-htm"
      "x-extension-html"
      "x-extension-shtml"
      "x-extension-xht"
      "x-extension-xhtml"
    ])
    // (xdgAssociations "x-scheme-handler" browser [
      "about"
      "ftp"
      "http"
      "https"
      "unknown"
    ]);

  # XDG MIME types
  associations = builtins.mapAttrs (_: v: (map (e: "${e}.desktop") v)) (
    {
      "application/pdf" = [ "org.pwmt.zathura-pdf-mupdf" ];
      "text/html" = browser;
      "text/plain" = [ "Helix" ];
      "x-scheme-handler/chrome" = [ "chromium-browser" ];
      "inode/directory" = [ "yazi" ];
      "x-scheme-handler/zoommtg" = [ "zoom" ];
      "x-scheme-handler/zoomus" = [ "zoom" ];
      "x-scheme-handler/tel" = [ "zoom" ];
      "x-scheme-handler/callto" = [ "zoom" ];
      "x-scheme-handler/zoomphonecall" = [ "zoom" ];
    }
    // image
    // video
    // audio
    // browserTypes
  );
in
{
  xdg = {
    enable = true;
    cacheHome = config.home.homeDirectory + "/.local/cache";
    portal = {
      enable = true;
      xdgOpenUsePortal = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-wlr
      ];
    };

    mimeApps = {
      enable = true;
      defaultApplications = associations;
    };

    userDirs = {
      enable = true;
      createDirectories = true;
      extraConfig = {
        XDG_SCREENSHOTS_DIR = "${config.xdg.userDirs.pictures}/Screenshots";
      };
    };
    desktopEntries = {
      zoom = {
        name = "Zoom";
        exec = "${chromium} --app=https://app.zoom.us";
        icon = "Zoom";
        type = "Application";
        terminal = false;
        mimeType = [
          "x-scheme-handler/zoommtg"
          "x-scheme-handler/zoomus"
          "x-scheme-handler/tel"
          "x-scheme-handler/callto"
          "x-scheme-handler/zoomphonecall"
        ];
        categories = [
          "Network"
          "InstantMessaging"
          "VideoConference"
        ];
        settings = {
          StartupNotify = "true";
          StartupWMClass = "zoom";
        };
      };
    };

  };

  home.packages = [
    # used by `gio open` and xdp-gtk
    (pkgs.writeShellScriptBin "xdg-terminal-exec" ''
      foot "$@"
    '')
    pkgs.xdg-utils
  ];
}
