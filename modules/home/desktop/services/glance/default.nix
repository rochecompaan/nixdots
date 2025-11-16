{ lib, ... }:
{
  services.glance = {
    enable = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 5555;
      };
      theme = {
        contrast-multiplier = lib.mkForce 1.1;
      };
      pages = [
        {
          name = "Home";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "bookmarks";
                  groups = lib.lists.singleton {
                    links = [
                      {
                        title = "Mail";
                        url = "https://app.tuta.com";
                      }
                      {
                        title = "GitHub";
                        url = "https://github.com";
                      }
                      {
                        title = "NixOS Status";
                        url = "https://status.nixos.org";
                      }
                    ];
                  };
                }
                {
                  type = "clock";
                  hour-format = "24h";
                  timezones = [ { timezone = "Africa/Johannesburg"; } ];
                }
                { type = "calendar"; }
                {
                  type = "weather";
                  location = "Port Elizabeth, South Africa";
                }
              ];
            }
            {
              size = "full";
              widgets = [
                { type = "hacker-news"; }
                { type = "lobsters"; }
                {
                  type = "reddit";
                  subreddit = "neovim";
                }
                {
                  type = "reddit";
                  subreddit = "unixporn";
                }
              ];
            }
          ];
        }
      ];
    };
  };
}
