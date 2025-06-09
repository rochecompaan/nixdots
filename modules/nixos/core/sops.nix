{ config, inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  config = {
    sops = {
      defaultSopsFile = "${inputs.nix-secrets}/secrets.yaml";
      defaultSopsFormat = "yaml";

      age = {
        generateKey = true;
        keyFile = "/var/lib/sops-nix/keys.txt";
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      };

      secrets = {
        "ssh-keys/users/roche" = {
          path = "/home/roche/.ssh/id_ed25519";
          mode = "0600";
          owner = "roche";
          group = "users";
        };

        "cluster-token" = { };

        "duckdns-token" = { };
      };
    };

    # Create .ssh directory with correct permissions
    systemd.user.tmpfiles.rules = [
      "d /home/roche/.ssh 0700 roche users - -"
    ];
  };
}
