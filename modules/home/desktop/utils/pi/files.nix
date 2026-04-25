{ config, pkgs }:
let
  colors = config.lib.stylix.colors;
  hex = color: "#${color}";

  # Pi package derivations
  piBashLiveViewSrc = pkgs.fetchgit {
    url = "https://github.com/lucasmeijer/pi-bash-live-view.git";
    rev = "7802f5bdb8a6d7553da03e22fbccb542a634cd72";
    sha256 = "sha256-/bp0HHlgisO+haaa8NZYGE7wTbTEubMbGhbZLd/BYho=";
  };

  piBashLiveView = pkgs.buildNpmPackage {
    pname = "pi-bash-live-view";
    version = "0.1.1";
    src = piBashLiveViewSrc;

    npmDepsHash = "sha256-fL8i5zco61xOZ7lQaI25KNpCCqCdhjPlw8cxhHJ16kw=";

    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.python3
      pkgs.pkg-config
    ];

    dontNpmPrune = true;
    dontNpmBuild = true;
  };

  nobodyPlansForPiSrc = pkgs.fetchgit {
    url = "https://github.com/HashWarlock/nobody-plans-for-pi.git";
    rev = "fc2edc0f6d90dcdeb8c1d9e10a4bca9d7c20c0e4";
    sha256 = "sha256-sQyvyun9PEZLT/Ig8PSIM7QNT/X/3RTeiSZ8Owkg/bU=";
  };

  nobodyPlansAgentModels = {
    planner = "openai-codex/gpt-5.5";
    reviewer = "openai-codex/gpt-5.5";
    scout = "openai-codex/gpt-5.4-mini";
    worker = "openai-codex/gpt-5.5";
  };

  nobodyPlansAgentFiles = pkgs.runCommand "nobody-plans-for-pi-agents-gpt" { } ''
    mkdir -p $out
    cp ${nobodyPlansForPiSrc}/agents/*.md $out/
    chmod +w $out/*.md

    substituteInPlace $out/scout.md \
      --replace-fail "model: claude-haiku-4-5" "model: ${nobodyPlansAgentModels.scout}" \
      --replace-fail "tools: read, grep, find, ls, bash" "tools: read, grep, find, ls, bash, todo"
    substituteInPlace $out/planner.md \
      --replace-fail "model: claude-sonnet-4-5" "model: ${nobodyPlansAgentModels.planner}" \
      --replace-fail "tools: read, grep, find, ls" "tools: read, grep, find, ls, todo"
    substituteInPlace $out/reviewer.md \
      --replace-fail "model: claude-sonnet-4-5" "model: ${nobodyPlansAgentModels.reviewer}" \
      --replace-fail "tools: read, grep, find, ls, bash" "tools: read, grep, find, ls, bash, todo"
    substituteInPlace $out/worker.md \
      --replace-fail "model: claude-sonnet-4-5" "model: ${nobodyPlansAgentModels.worker}"
  '';

  # Diff npm package for multi-edit extension
  diffPackageSrc = pkgs.fetchurl {
    url = "https://registry.npmjs.org/diff/-/diff-7.0.0.tgz";
    sha256 = "sha256-kRLnmAa9a+V4p6bxJNlnEdQGCwus1NS6xOlq59CPKsE=";
  };

  diffPackage = pkgs.runCommand "diff-npm" { } ''
    mkdir -p $out/lib/node_modules/diff
    cd $out/lib/node_modules/diff
    ${pkgs.gnutar}/bin/tar -xzf ${diffPackageSrc} --strip-components=1
  '';

  piSettings = (builtins.fromJSON (builtins.readFile ./settings.json)) // {
    theme = "stylix";
    packages = [
      "${piBashLiveView}/lib/node_modules/pi-bash-live-view"
      "${nobodyPlansForPiSrc}"
    ];
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
        mkdir -p $out/.pi/agent/agents
        mkdir -p $out/.pi/agent/skills/linear
        mkdir -p $out/.pi/agent/skills/commit
        mkdir -p $out/.pi/agent/skills/frontend-design
        mkdir -p $out/.pi/agent/skills/github
        mkdir -p $out/.pi/agent/themes

        cat > $out/.pi/agent/settings.json <<'EOF'
        ${builtins.toJSON piSettings}
        EOF

        cp ${./extensions/filter-output.ts} $out/.pi/agent/extensions/filter-output.ts
        cp ${./extensions/security.ts} $out/.pi/agent/extensions/security.ts
        cp ${./extensions/theme-cycler.ts} $out/.pi/agent/extensions/theme-cycler.ts
        cp ${./extensions/review.ts} $out/.pi/agent/extensions/review.ts
        cp -r ${./extensions/answer} $out/.pi/agent/extensions/answer
        cp ${./extensions/btw.ts} $out/.pi/agent/extensions/btw.ts
        cp ${./extensions/context.ts} $out/.pi/agent/extensions/context.ts
        cp ${./extensions/control.ts} $out/.pi/agent/extensions/control.ts
        cp ${./extensions/files.ts} $out/.pi/agent/extensions/files.ts
        cp ${./extensions/loop.ts} $out/.pi/agent/extensions/loop.ts
        cp ${./extensions/multi-edit.ts} $out/.pi/agent/extensions/multi-edit.ts
        cp ${./extensions/notify.ts} $out/.pi/agent/extensions/notify.ts
        cp ${./extensions/prompt-editor.ts} $out/.pi/agent/extensions/prompt-editor.ts
        cp ${./extensions/session-breakdown.ts} $out/.pi/agent/extensions/session-breakdown.ts
        cp ${./extensions/todos.ts} $out/.pi/agent/extensions/todos.ts
    cp ${./extensions/whimsical.ts} $out/.pi/agent/extensions/whimsical.ts

        cp ${nobodyPlansAgentFiles}/scout.md $out/.pi/agent/agents/scout.md
        cp ${nobodyPlansAgentFiles}/planner.md $out/.pi/agent/agents/planner.md
        cp ${nobodyPlansAgentFiles}/reviewer.md $out/.pi/agent/agents/reviewer.md
        cp ${nobodyPlansAgentFiles}/worker.md $out/.pi/agent/agents/worker.md

        cp ${./skills/linear/SKILL.md} $out/.pi/agent/skills/linear/SKILL.md
        cp ${./skills/commit/SKILL.md} $out/.pi/agent/skills/commit/SKILL.md
        cp ${./skills/frontend-design/SKILL.md} $out/.pi/agent/skills/frontend-design/SKILL.md
        cp ${./skills/github/SKILL.md} $out/.pi/agent/skills/github/SKILL.md

        cat > $out/.pi/agent/themes/stylix.json <<'EOF'
        ${builtins.toJSON stylixPiTheme}
        EOF
  '';
in
{
  inherit
    package
    piSettings
    stylixPiTheme
    diffPackage
    nobodyPlansAgentFiles
    nobodyPlansAgentModels
    nobodyPlansForPiSrc
    ;
}
