{
  lib,
  buildNpmPackage,
  pkgs,
}:

buildNpmPackage rec {
  pname = "claude-code";
  version = "0.2.41";

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-0.2.41.tgz";
    hash = "sha256-tNaSfdKPrLv7jacyO91kSauMgyQtGFVsB4eDOenFQ30=";
  };

  npmDepsHash = "sha256-ne+W8X8us9ry/Wb458yipqUPjQ5MGme7G3zjasmq1as=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  AUTHORIZED = "1";

  passthru.updateScript = ./update.sh;

  meta = {
    description = "An agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    license = lib.licenses.unfree;
    maintainers = [ lib.maintainers.malo ];
    mainProgram = "claude";
  };
}
