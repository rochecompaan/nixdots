{ config, pkgs }:
let
  # Pi package derivations
  notionCli = import ./notion-cli.nix { inherit pkgs; };

  piListenSrc = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@codexstar/pi-listen/-/pi-listen-7.2.2.tgz";
    hash = "sha256-MbYQiwQMvXkN0dRYdMTTX+4whLjey/yGcke5zq6BRO0=";
  };

  sherpaOnnxNode = pkgs.fetchzip {
    url = "https://registry.npmjs.org/sherpa-onnx-node/-/sherpa-onnx-node-1.13.0.tgz";
    hash = "sha256-YV+px436CmhSDmshUmOLWTaeoqp+miY69TqHJpMwPkA=";
  };

  sherpaOnnxLinuxX64 = pkgs.fetchzip {
    url = "https://registry.npmjs.org/sherpa-onnx-linux-x64/-/sherpa-onnx-linux-x64-1.13.0.tgz";
    hash = "sha256-w1SfJmebP8inl1z/sd0qaC1wL/KYDmnzD/NiDCde3gY=";
  };

  piListen = pkgs.runCommand "pi-listen-7.2.2" { } ''
    mkdir -p $out/node_modules
    cp -r ${piListenSrc}/. $out/
    cp -r ${sherpaOnnxNode} $out/node_modules/sherpa-onnx-node
    cp -r ${sherpaOnnxLinuxX64} $out/node_modules/sherpa-onnx-linux-x64
  '';

  piSubagentsSrc = pkgs.fetchgit {
    url = "https://github.com/nicobailon/pi-subagents.git";
    rev = "0b3f5b4d16557228cf7ce3e2de7b708f94ccf9ac";
    sha256 = "sha256-OOepzpERAz1E7yIl85IxcXs+QFUzi6uhpC6RjQXr1Yc=";
  };

  piSubagents = pkgs.buildNpmPackage {
    pname = "pi-subagents";
    version = "0.23.0";
    src = piSubagentsSrc;

    npmDepsHash = "sha256-hJwe6crzgVnosyJcfV5BIu0cfm69kEQ1vaZNteQxoY4=";

    dontNpmBuild = true;
  };

  piAgentDashboardFetchedSrc = pkgs.fetchgit {
    url = "https://github.com/BlackBeltTechnology/pi-agent-dashboard.git";
    rev = "v0.5.0";
    sha256 = "sha256-8CbmbuEw13jctWgmSPedz1pn7nBXqijePPATs6YPKOM=";
  };

  piAgentDashboardSrc = pkgs.runCommand "pi-agent-dashboard-src-0.5.0" { } ''
    cp -R --no-preserve=mode ${piAgentDashboardFetchedSrc}/. $out
    ${pkgs.nodejs}/bin/node <<'NODE'
    const fs = require("node:fs");
    const lockPath = process.env.out + "/package-lock.json";
    const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));

    const packageNameFromLockPath = (lockPath) => {
      const parts = lockPath.split("/node_modules/");
      const tail = parts[parts.length - 1];
      const segments = tail.split("/");
      return segments[0].startsWith("@")
        ? segments.slice(0, 2).join("/")
        : segments[0];
    };

    const packageMetadata = new Map();
    for (const [path, pkg] of Object.entries(lock.packages ?? {})) {
      if (!path.includes("node_modules/") || !pkg.version || !pkg.resolved || !pkg.integrity || pkg.link) continue;
      packageMetadata.set(packageNameFromLockPath(path) + "@" + pkg.version, {
        resolved: pkg.resolved,
        integrity: pkg.integrity,
      });
    }

    for (const [specifier, metadata] of Object.entries({
      "@emnapi/core@1.8.1": {
        resolved: "https://registry.npmjs.org/@emnapi/core/-/core-1.8.1.tgz",
        integrity: "sha512-AvT9QFpxK0Zd8J0jopedNm+w/2fIzvtPKPjqyw9jwvBaReTTqPBk9Hixaz7KbjimP+QNz605/XnjFcDAL2pqBg==",
      },
      "@emnapi/runtime@1.8.1": {
        resolved: "https://registry.npmjs.org/@emnapi/runtime/-/runtime-1.8.1.tgz",
        integrity: "sha512-mehfKSMWjjNol8659Z8KxEMrdSJDDot5SXMq00dM8BN4o+CLNXQ0xH2V7EchNHV4RmbZLmmPdEaXZc5H2FXmDg==",
      },
      "@emnapi/wasi-threads@1.1.0": {
        resolved: "https://registry.npmjs.org/@emnapi/wasi-threads/-/wasi-threads-1.1.0.tgz",
        integrity: "sha512-WI0DdZ8xFSbgMjR1sFsKABJ/C5OnRrjT06JXbZKexJGrDuPTzZdDYfFlsgcCXCyf+suG5QU2e/y1Wo2V/OapLQ==",
      },
      "@napi-rs/wasm-runtime@1.1.1": {
        resolved: "https://registry.npmjs.org/@napi-rs/wasm-runtime/-/wasm-runtime-1.1.1.tgz",
        integrity: "sha512-p64ah1M1ld8xjWv3qbvFwHiFVWrq1yFvV4f7w+mzaqiR4IlSgkqhcRdHwsGgomwzBH51sRY4NEowLxnaBjcW/A==",
      },
      "@tybys/wasm-util@0.10.1": {
        resolved: "https://registry.npmjs.org/@tybys/wasm-util/-/wasm-util-0.10.1.tgz",
        integrity: "sha512-9tTaPJLSiejZKx+Bmog4uSubteqTvFrVrURwkmHixBo0G4seD0zUxp98E1DzUBJxLQ3NPwXrGKDiVjwx/DpPsg==",
      },
      "tslib@2.8.1": {
        resolved: "https://registry.npmjs.org/tslib/-/tslib-2.8.1.tgz",
        integrity: "sha512-oJFu94HQb+KVduSUQL7wnpmqnfmLsOA/nAh6b6EH0wCEoK0/mPeXU6c3wKDV83MkOuHPRHtSXKKU99IBazS/2w==",
      },
      "agent-base@7.1.4": {
        resolved: "https://registry.npmjs.org/agent-base/-/agent-base-7.1.4.tgz",
        integrity: "sha512-MnA+YT8fwfJPgBx3m60MNqakm30XOkyIoH1y6huTQvC0PwZG7ki8NacLBcrPbNoo8vEZy7Jpuk7+jMO+CUovTQ==",
      },
      "data-urls@5.0.0": {
        resolved: "https://registry.npmjs.org/data-urls/-/data-urls-5.0.0.tgz",
        integrity: "sha512-ZYP5VBHshaDAiVZxjbRVcFJpc+4xGgT0bK3vzy1HLN8jTO975HEbuYzZJcHoQEY5K1a0z8YayJkyVETa08eNTg==",
      },
      "entities@6.0.1": {
        resolved: "https://registry.npmjs.org/entities/-/entities-6.0.1.tgz",
        integrity: "sha512-aN97NXWF6AWBTahfVOIrB/NShkzi5H7F9r1s9mD3cDj4Ko5f2qhhVoYMibXF7GlLveb/D2ioWay8lxI97Ven3g==",
      },
      "html-encoding-sniffer@4.0.0": {
        resolved: "https://registry.npmjs.org/html-encoding-sniffer/-/html-encoding-sniffer-4.0.0.tgz",
        integrity: "sha512-Y22oTqIU4uuPgEemfz7NDJz6OeKf12Lsu+QC+s3BVpda64lTiMYCyGwg5ki4vFxkMwQdeZDl2adZoqUgdFuTgQ==",
      },
      "http-proxy-agent@7.0.2": {
        resolved: "https://registry.npmjs.org/http-proxy-agent/-/http-proxy-agent-7.0.2.tgz",
        integrity: "sha512-T1gkAiYYDWYx3V5Bmyu7HcfcvL7mUrTWiM6yOfa3PIphViJ/gFPbvidQ+veqSOHci/PxBcDabeUNCzpOODJZig==",
      },
      "https-proxy-agent@7.0.6": {
        resolved: "https://registry.npmjs.org/https-proxy-agent/-/https-proxy-agent-7.0.6.tgz",
        integrity: "sha512-vK9P5/iUfdl95AI+JVyUuIcVtd4ofvtrOr3HNtM2yxC9bnMbEdp3x01OhQNnjb8IJYi38VlTE3mBXwcfvywuSw==",
      },
      "jsdom@25.0.1": {
        resolved: "https://registry.npmjs.org/jsdom/-/jsdom-25.0.1.tgz",
        integrity: "sha512-8i7LzZj7BF8uplX+ZyOlIz86V6TAsSs+np6m1kpW9u0JWi4z/1t+FzcK1aek+ybTnAC4KhBL4uXCNT0wcUIeCw==",
      },
      "parse5@7.3.0": {
        resolved: "https://registry.npmjs.org/parse5/-/parse5-7.3.0.tgz",
        integrity: "sha512-IInvU7fabl34qmi9gY8XOVxhYyMyuH2xUNpb2q8/Y+7552KlejkRvqvD19nMoUW/uQGGbqNpA6Tufu5FL5BZgw==",
      },
      "tldts@6.1.86": {
        resolved: "https://registry.npmjs.org/tldts/-/tldts-6.1.86.tgz",
        integrity: "sha512-WMi/OQ2axVTf/ykqCQgXiIct+mSQDFdH2fkwhPwgEwvJ1kSzZRiinb0zF2Xb8u4+OqPChmyI6MEu4EezNJz+FQ==",
      },
      "tldts-core@6.1.86": {
        resolved: "https://registry.npmjs.org/tldts-core/-/tldts-core-6.1.86.tgz",
        integrity: "sha512-Je6p7pkk+KMzMv2XXKmAE3McmolOQFdxkKw0R8EYNr7sELW46JqnNeTX8ybPiQgvg1ymCoF8LXs5fzFaZvJPTA==",
      },
      "tough-cookie@5.1.2": {
        resolved: "https://registry.npmjs.org/tough-cookie/-/tough-cookie-5.1.2.tgz",
        integrity: "sha512-FVDYdxtnj0G6Qm/DhNPSb8Ju59ULcup3tuJxkFb5K8Bv2pUXILbf0xZWU8PX8Ov19OXljbUyveOFwRMwkXzO+A==",
      },
      "tr46@5.1.1": {
        resolved: "https://registry.npmjs.org/tr46/-/tr46-5.1.1.tgz",
        integrity: "sha512-hdF5ZgjTqgAntKkklYw0R03MG2x/bSzTtkxmIRw/sTNV8YXsCJ1tfLAX23lhxhHJlEf3CRCOCGGWw3vI3GaSPw==",
      },
      "webidl-conversions@7.0.0": {
        resolved: "https://registry.npmjs.org/webidl-conversions/-/webidl-conversions-7.0.0.tgz",
        integrity: "sha512-VwddBukDzu71offAQR975unBIGqfKZpM+8ZX6ySk8nYhVoo5CYaZyzt3YBvYtRtO+aoGlqxPg/B87NGVZ/fu6g==",
      },
      "whatwg-mimetype@4.0.0": {
        resolved: "https://registry.npmjs.org/whatwg-mimetype/-/whatwg-mimetype-4.0.0.tgz",
        integrity: "sha512-QaKxh0eNIi2mE9p2vEdzfagOKHCcj1pJ56EEHGQOVxp8r9/iszLUUV7v89x9O1p/T+NlTM5W7jW6+cz4Fq1YVg==",
      },
      "whatwg-url@14.2.0": {
        resolved: "https://registry.npmjs.org/whatwg-url/-/whatwg-url-14.2.0.tgz",
        integrity: "sha512-De72GdQZzNTUBBChsXueQUnPKDkg/5A5zp7pFDuQAj5UFoENpiACU0wlCvzpAGnTkj++ihpKwKyYewn/XNUbKw==",
      },
      "ajv@8.20.0": {
        resolved: "https://registry.npmjs.org/ajv/-/ajv-8.20.0.tgz",
        integrity: "sha512-Thbli+OlOj+iMPYFBVBfJ3OmCAnaSyNn4M1vz9T6Gka5Jt9ba/HIR56joy65tY6kx/FCF5VXNB819Y7/GUrBGA==",
      },
      "json-schema-traverse@1.0.0": {
        resolved: "https://registry.npmjs.org/json-schema-traverse/-/json-schema-traverse-1.0.0.tgz",
        integrity: "sha512-NM8/P9n3XjXhIZn1lLhkFaACTOURQXjWhV4BA/RnOv8xvgqtqpAX9IO4mRQxSx1Rlo4tqzeqb0sOlruaOy3dug==",
      },
    })) {
      packageMetadata.set(specifier, metadata);
    }

    for (const [path, pkg] of Object.entries(lock.packages ?? {})) {
      if (!path.includes("node_modules/") || !pkg.version || pkg.link) continue;
      if (pkg.resolved && pkg.integrity) continue;
      const metadata = packageMetadata.get(packageNameFromLockPath(path) + "@" + pkg.version);
      if (!metadata) {
        throw new Error("Missing registry metadata for " + path + "@" + pkg.version);
      }
      pkg.resolved = metadata.resolved;
      pkg.integrity = metadata.integrity;
    }

    fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + "\n");

    const rootPackagePath = process.env.out + "/package.json";
    const rootPackage = JSON.parse(fs.readFileSync(rootPackagePath, "utf8"));
    rootPackage.files = Array.from(new Set([...(rootPackage.files ?? []), "packages/**"]));
    fs.writeFileSync(rootPackagePath, JSON.stringify(rootPackage, null, 2) + "\n");

    const clientPackagePath = process.env.out + "/packages/client/package.json";
    const clientPackage = JSON.parse(fs.readFileSync(clientPackagePath, "utf8"));
    delete clientPackage.scripts.prepare;
    fs.writeFileSync(clientPackagePath, JSON.stringify(clientPackage, null, 2) + "\n");
    NODE
  '';

  piAgentDashboard = pkgs.buildNpmPackage {
    pname = "pi-agent-dashboard";
    version = "0.5.0";
    src = piAgentDashboardSrc;

    npmDepsHash = "sha256-KYkTGuQ8MGGbWh5YLIEjuOmSHoAQkDi7LYUbOUncpOw=";

    makeCacheWritable = true;
    # Rebuild only node-pty so the Linux native module exists at runtime;
    # rebuilding every install script tries to fetch phantomjs from the network.
    npmRebuildFlags = [ "node-pty" ];
  };

  superpowersSrc = pkgs.fetchgit {
    url = "https://github.com/obra/superpowers.git";
    rev = "e7a2d16476bf042e9add4699c9d018a90f86e4a6";
    sha256 = "sha256-8/M/S0BUYurZkFqe6LemVtBQnPSxBNfy1C7Q6f92hjE=";
  };

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
      "${piListen}"
      "${piSubagents}/lib/node_modules/pi-subagents"
      # "${piAgentDashboard}/lib/node_modules/@blackbelt-technology/pi-agent-dashboard"
      "${superpowersSrc}"
    ];
  };

  stylixPiTheme = import ./theme.nix { inherit config; };

  package = pkgs.runCommand "pi-agent-files" { } ''
    mkdir -p \
      $out/.pi/agent/agent-teams \
      $out/.pi/agent/agents \
      $out/.pi/agent/extensions \
      $out/.pi/agent/node_modules \
      $out/.pi/agent/skills \
      $out/.pi/agent/themes

    cp -r ${./agent-teams}/. $out/.pi/agent/agent-teams/
    cp -r ${./agents}/. $out/.pi/agent/agents/
    cp -r ${./extensions}/. $out/.pi/agent/extensions/
    cp -r ${./skills}/. $out/.pi/agent/skills/

    ln -s ${config.home.homeDirectory}/projects/pi/extensions/pi-intervals $out/.pi/agent/extensions/pi-intervals
    ln -s ${config.home.homeDirectory}/projects/pi/extensions/pi-intervals/skills/intervals-time-entries $out/.pi/agent/skills/intervals-time-entries
    ln -s ${diffPackage}/lib/node_modules/diff $out/.pi/agent/node_modules/diff

    cat > $out/.pi/agent/AGENTS.md <<'EOF'
    ## Plans, specs and designs

    - **Save plans to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`
    - Write the validated design (spec) to `docs/specs/YYYY-MM-DD-<topic>-design.md`
    EOF

    printf '%s' ${pkgs.lib.escapeShellArg (builtins.toJSON piSettings)} > $out/.pi/agent/settings.json
    printf '%s' ${pkgs.lib.escapeShellArg (builtins.toJSON stylixPiTheme)} > $out/.pi/agent/themes/stylix.json
  '';
in
{
  inherit
    package
    piSettings
    stylixPiTheme
    diffPackage
    notionCli
    piAgentDashboard
    ;
}
