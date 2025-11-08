{ ... }:
{
  programs.nh = {
    enable = true;
    clean = {
      enable = true;
      extraArgs = "--keep-since 4d --keep 3";
    };
    # Sets NH_OS_FLAKE for system operations
    flake = "/home/roche/nixdots";
  };
}
