{ config, inputs, ... }:
{
  imports = [ inputs.roche-pi.homeModules.default ];

  programs.roche-pi = {
    enable = true;
    stylix.enable = true;

    intervals = {
      enable = true;
      path = "${config.home.homeDirectory}/projects/pi/extensions/pi-intervals";
    };

    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-5.5";
      defaultThinkingLevel = "high";
    };
  };
}
