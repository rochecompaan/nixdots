{
  security = {
    rtkit.enable = true;
    pam.services = {
      greetd = {
        gnupg.enable = true;
        enableGnomeKeyring = true;
      };
      login = {
        enableGnomeKeyring = true;
        gnupg = {
          enable = true;
          noAutostart = true;
          storeOnly = true;
        };
      };
    };
    polkit.enable = true;

    # Sudo configuration
    sudo.extraRules = [
      {
        users = [ "roche" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

  };
}
