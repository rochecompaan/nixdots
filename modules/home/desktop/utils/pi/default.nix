{ config, ... }:
let
  colors = config.lib.stylix.colors;
  hex = color: "#${color}";

  piSettings = (builtins.fromJSON (builtins.readFile ./settings.json)) // {
    theme = "stylix";
  };

  stylixPiTheme = {
    "$schema" =
      "https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json";
    name = "stylix";
    vars = {
      base00 = hex colors.base00;
      base01 = hex colors.base01;
      base02 = hex colors.base02;
      base03 = hex colors.base03;
      base04 = hex colors.base04;
      base05 = hex colors.base05;
      base06 = hex colors.base06;
      base07 = hex colors.base07;
      base08 = hex colors.base08;
      base09 = hex colors.base09;
      base0A = hex colors.base0A;
      base0B = hex colors.base0B;
      base0C = hex colors.base0C;
      base0D = hex colors.base0D;
      base0E = hex colors.base0E;
      base0F = hex colors.base0F;
    };
    colors = {
      accent = "base0D";
      border = "base01";
      borderAccent = "base0D";
      borderMuted = "base02";
      success = "base0B";
      error = "base08";
      warning = "base0A";
      muted = "base04";
      dim = "base03";
      text = "base05";
      thinkingText = "base0C";
      selectedBg = "base02";
      userMessageBg = "base01";
      userMessageText = "base06";
      customMessageBg = "base00";
      customMessageText = "base05";
      customMessageLabel = "base0D";
      toolPendingBg = "base00";
      toolSuccessBg = "base00";
      toolErrorBg = "base00";
      toolTitle = "base0D";
      toolOutput = "base05";
      mdHeading = "base0A";
      mdLink = "base0D";
      mdLinkUrl = "base0C";
      mdCode = "base0B";
      mdCodeBlock = "base05";
      mdCodeBlockBorder = "base01";
      mdQuote = "base04";
      mdQuoteBorder = "base01";
      mdHr = "base01";
      mdListBullet = "base09";
      toolDiffAdded = "base0B";
      toolDiffRemoved = "base08";
      toolDiffContext = "base03";
      syntaxComment = "base03";
      syntaxKeyword = "base0E";
      syntaxFunction = "base0D";
      syntaxVariable = "base08";
      syntaxString = "base0B";
      syntaxNumber = "base09";
      syntaxType = "base0A";
      syntaxOperator = "base0C";
      syntaxPunctuation = "base04";
      thinkingOff = "base01";
      thinkingMinimal = "base04";
      thinkingLow = "base0D";
      thinkingMedium = "base0C";
      thinkingHigh = "base0A";
      thinkingXhigh = "base08";
      bashMode = "base09";
    };
    export = {
      pageBg = hex colors.base00;
      cardBg = hex colors.base01;
      infoBg = hex colors.base02;
    };
  };
in
{
  home.file = {
    ".pi/agent/settings.json".text = builtins.toJSON piSettings;

    ".pi/agent/extensions/filter-output.ts".source = ./filter-output.ts;
    ".pi/agent/extensions/security.ts".source = ./security.ts;
    ".pi/agent/extensions/theme-cycler.ts".source = ./theme-cycler.ts;

    ".pi/agent/skills/linear/SKILL.md".source = ./skills/linear/SKILL.md;

    ".pi/agent/themes/stylix.json".text = builtins.toJSON stylixPiTheme;
    ".pi/agent/themes/catppuccin-mocha.json".source = ./themes/catppuccin-mocha.json;
    ".pi/agent/themes/cyberpunk.json".source = ./themes/cyberpunk.json;
    ".pi/agent/themes/dracula.json".source = ./themes/dracula.json;
    ".pi/agent/themes/everforest.json".source = ./themes/everforest.json;
    ".pi/agent/themes/gruvbox.json".source = ./themes/gruvbox.json;
    ".pi/agent/themes/midnight-ocean.json".source = ./themes/midnight-ocean.json;
    ".pi/agent/themes/nord.json".source = ./themes/nord.json;
    ".pi/agent/themes/ocean-breeze.json".source = ./themes/ocean-breeze.json;
    ".pi/agent/themes/rose-pine.json".source = ./themes/rose-pine.json;
    ".pi/agent/themes/synthwave.json".source = ./themes/synthwave.json;
    ".pi/agent/themes/tokyo-night.json".source = ./themes/tokyo-night.json;
  };
}
