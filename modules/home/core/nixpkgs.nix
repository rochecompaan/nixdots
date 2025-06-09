{
  nixpkgs.config = {
    permittedInsecurePackages = [
      "electron-25.9.0"
      "electron-29.4.6"
      "electron-30.5.1"
      "nix-2.24.5"
      "ventoy-1.1.05"
    ];
    allowUnfree = true;
    allowBroken = true;
    allowUnfreePredicate = _: true;
  };
}
