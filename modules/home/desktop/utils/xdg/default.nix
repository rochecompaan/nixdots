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
      # Explicit portal selection to avoid xdg-desktop-portal >=1.17 warning
      config = lib.mkMerge [
        (lib.mkIf (config.default.de == "hyprland") {
          hyprland.default = [
            "hyprland"
            "gtk"
          ];
          common.default = [
            "hyprland"
            "gtk"
          ];
        })
        (lib.mkIf (config.default.de == "niri") {
          common.default = [
            "gnome"
            "gtk"
          ];
        })
      ];

      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
      ]
      ++ lib.optionals (config.default.de == "hyprland") [
        pkgs.xdg-desktop-portal-hyprland
      ]
      ++ lib.optionals (config.default.de == "niri") [
        pkgs.xdg-desktop-portal-gnome
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
      msteams = {
        name = "Microsoft Teams";
        exec = "${chromium} --app=https://teams.microsoft.com";
        icon = "teams";
        type = "Application";
        terminal = false;
        mimeType = [
          "x-scheme-handler/msteams"
        ];
        categories = [
          "Network"
          "InstantMessaging"
          "VideoConference"
        ];
        settings = {
          StartupNotify = "true";
          StartupWMClass = "teams";
        };
      };
      outlook = {
        name = "Microsoft Outlook";
        exec = "${chromium} --app=https://outlook.office.com";
        icon = "outlook";
        type = "Application";
        terminal = false;
        mimeType = [
          "x-scheme-handler/msoutlook"
        ];
        settings = {
          StartupNotify = "true";
          StartupWMClass = "outlook";
        };
      };

      ganttic = {
        name = "Ganttic";
        exec = "${chromium} --app=https://sixfeetup.ganttic.com/view/332055";
        icon = "calendar";
        type = "Application";
        terminal = false;
        categories = [
          "Network"
          "Office"
        ];
        settings = {
          StartupNotify = "true";
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
