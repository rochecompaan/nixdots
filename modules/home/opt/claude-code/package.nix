{
  lib,
  buildNpmPackage,
  pkgs,
}:

buildNpmPackage rec {
  pname = "claude-code";
  version = "0.2.59";

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-0.2.59.tgz";
    hash = "sha256-IRVieF6uMIfnV3VKFJTTfYaD/LsK8genCD/GhYWJSvk=";
  };

  npmDepsHash = "sha256-F/ZLRKHF1MFB3AXWr+HWw/GFn1lpI6uMBkV/4VUPL8E=";

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
