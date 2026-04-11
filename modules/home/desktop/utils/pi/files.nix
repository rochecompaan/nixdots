{ config, pkgs }:
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

  package = pkgs.runCommand "pi-agent-files" { } ''
    mkdir -p $out/.pi/agent/extensions
    mkdir -p $out/.pi/agent/skills/linear
    mkdir -p $out/.pi/agent/themes

    cat > $out/.pi/agent/settings.json <<'EOF'
    ${builtins.toJSON piSettings}
    EOF

    cp ${./filter-output.ts} $out/.pi/agent/extensions/filter-output.ts
    cp ${./security.ts} $out/.pi/agent/extensions/security.ts
    cp ${./theme-cycler.ts} $out/.pi/agent/extensions/theme-cycler.ts

    cp ${./skills/linear/SKILL.md} $out/.pi/agent/skills/linear/SKILL.md

    cat > $out/.pi/agent/themes/stylix.json <<'EOF'
    ${builtins.toJSON stylixPiTheme}
    EOF

    cp ${./themes/catppuccin-mocha.json} $out/.pi/agent/themes/catppuccin-mocha.json
    cp ${./themes/cyberpunk.json} $out/.pi/agent/themes/cyberpunk.json
    cp ${./themes/dracula.json} $out/.pi/agent/themes/dracula.json
    cp ${./themes/everforest.json} $out/.pi/agent/themes/everforest.json
    cp ${./themes/gruvbox.json} $out/.pi/agent/themes/gruvbox.json
    cp ${./themes/midnight-ocean.json} $out/.pi/agent/themes/midnight-ocean.json
    cp ${./themes/nord.json} $out/.pi/agent/themes/nord.json
    cp ${./themes/ocean-breeze.json} $out/.pi/agent/themes/ocean-breeze.json
    cp ${./themes/rose-pine.json} $out/.pi/agent/themes/rose-pine.json
    cp ${./themes/synthwave.json} $out/.pi/agent/themes/synthwave.json
    cp ${./themes/tokyo-night.json} $out/.pi/agent/themes/tokyo-night.json
  '';
in
{
  inherit package piSettings stylixPiTheme;
}
