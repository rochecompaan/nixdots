{ config, pkgs, ... }:
{
  sops.secrets.roche-password = {
    neededForUsers = true;
  };
  users = {
    groups = {
      ziti = { };
    };
    users.roche = {
      hashedPasswordFile = config.sops.secrets.roche-password.path;
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "networkmanager"
        "audio"
        "video"
        "libvirtd"
        "docker"
        "uinput"
        "adbusers"
        "scanner"
        "lp"
        "ziti"
      ];
      openssh = {
        authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHPFBvBgaJTaA+jlRSY1GzgMptcN9XHwgbCyXR/+OOvt"
          "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAIEAsp8oUbYTgy0viPASVVa/aCwjukzI+FvMd7oDB67RliSWhzc2GwlAXPPEuuxtkfAm1xFf88Qw9Xta8vvhOfJ/ACO+P8cGn9DO8BnBHhZxCKvOa/b57ExwM3gWsWga8hpO7C4L5piXkQ5HoTv2fKaIZk6Zd5OWmdOqgT05I6BgHak="
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDG6FqnA0Zp33iPpqQvpnVBAzF/gWhfC6ZAJElKDSO93WJKG1wNTbKxqdvVJge9McPToN/NE50rhHJUaH7Scy5mupQ98aMHOfMvx0tuZBOYCIUNBaBgXAwmTHThlYu+XHw9o/3u6H7hUfhgu49FKfMsvGzW/Yb7XRpbBEK8wehFIHgjOOHz99nz8nhkLX0k9Rnyrgw+bbny4YdmpOHzLthNN4AzMa+JT6JtLLIniNz8Xh0k8jQQ3U0LxUn3sIOWTsavk0MpwLZLFwpc/0PLEDcLtDqeockr6d91mACgDZZegnjhRZix5pE75Aqlq3wr1N3RckBA2dksYvXl9mg63RUB3kU3YLDIpIl6J9SisZ77/4Mf7IDQGYFTLeQnL1xr4A49UvHM0bBQ+1yut8KqmIeeptDer9sLta0RkZAwAo9PObzjQEPLRKB33I6YYAHzUuCIlqfI9B1dKFc0UTLrEc7K6B57c8NH9hxq89j0M+cOYsGlzAJ9yjrVLzGbk9EsezKkeRVo5PSbBrzn6MSE92RidwtWeoo3pGvYpUwj3YrRWHKjod72h3Ebg04hA9A5VAAw5Bjw+fhdfPEAjLb2II6v1vMb0DgDlKkhnk8b+GoiBaTu95MV5h6eS9xHDgFncItJIau1s2bI0RewtZ9s/HKgENKfurJ0lRoL51R8JvOBfw== openpgp:0x68F9C6F4"
        ];
      };
    };
    defaultUserShell = pkgs.zsh;
  };
  programs.zsh.enable = true;
}
