let
  githubAgentCapabilities = [
    "repository:read"
    "issues:read"
    "issues:write"
    "pull_requests:read"
    "pull_requests:write"
    "actions:read"
    "statuses:read"
    "git:read"
    "git:write"
  ];

  gitOnlyAgentCapabilities = [
    "git:read"
    "git:write"
  ];

  repositorySpecs = [
    {
      id = "clubhouse-infra";
      tokenEnvironment = "REPOWOLF_TOKEN_CLUBHOUSE_INFRA";
      provider = "github-public";
      owner = "alphaexplorationco";
      name = "clubhouse_infra";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "clubhouse-server";
      tokenEnvironment = "REPOWOLF_TOKEN_CLUBHOUSE_SERVER";
      provider = "github-public";
      owner = "alphaexplorationco";
      name = "clubhouse_server";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "clubhouse-analytics";
      tokenEnvironment = "REPOWOLF_TOKEN_CLUBHOUSE_ANALYTICS";
      provider = "github-public";
      owner = "alphaexplorationco";
      name = "clubhouse_analytics";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "croprun";
      tokenEnvironment = "REPOWOLF_TOKEN_CROPRUN";
      provider = "compaan";
      owner = "roche";
      name = "croprun";
      defaultBranch = "main";
      capabilities = gitOnlyAgentCapabilities;
    }
    {
      id = "agibase";
      tokenEnvironment = "REPOWOLF_TOKEN_AGIBASE";
      provider = "github-public";
      owner = "upfrontsoftware";
      name = "agibase";
      defaultBranch = "master";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "repowolf";
      tokenEnvironment = "REPOWOLF_TOKEN_REPOWOLF";
      provider = "github-public";
      owner = "rochecompaan";
      name = "repowolf";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "nixdots";
      tokenEnvironment = "REPOWOLF_TOKEN_NIXDOTS";
      provider = "github-public";
      owner = "rochecompaan";
      name = "nixdots";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "homelab-k8s";
      tokenEnvironment = "REPOWOLF_TOKEN_HOMELAB_K8S";
      provider = "github-public";
      owner = "rochecompaan";
      name = "homelab-k8s";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "patchmill";
      tokenEnvironment = "REPOWOLF_TOKEN_PATCHMILL";
      provider = "github-public";
      owner = "rochecompaan";
      name = "patchmill";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "mycity";
      tokenEnvironment = "REPOWOLF_TOKEN_MYCITY";
      provider = "github-public";
      owner = "upfrontsoftware";
      name = "mycity";
      defaultBranch = "main";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "siyavula-deploy";
      tokenEnvironment = "REPOWOLF_TOKEN_SIYAVULA_DEPLOY";
      provider = "github-public";
      owner = "Siyavula";
      name = "deploy";
      defaultBranch = "master";
      capabilities = githubAgentCapabilities;
    }
    {
      id = "roche-pi";
      tokenEnvironment = "REPOWOLF_TOKEN_ROCHE_PI";
      provider = "compaan";
      owner = "roche";
      name = "pi-config";
      defaultBranch = "main";
      capabilities = gitOnlyAgentCapabilities;
    }
  ];

  mkRepository = spec: {
    name = spec.id;
    value = {
      inherit (spec) provider owner name;
      git = {
        denyRefs = [ "refs/heads/${spec.defaultBranch}" ];
        denyDeletes = true;
        maxRefUpdates = 16;
      };
    };
  };

  mkPrincipal = spec: {
    name = spec.id;
    value = {
      tokenEnvs = [ spec.tokenEnvironment ];
      grants = [
        {
          repository = spec.id;
          inherit (spec) capabilities;
        }
      ];
    };
  };
in
{
  providers = {
    github-public = {
      kind = "github";
      apiHost = "github.com";
      gitHost = "github.com";
      sshUser = "git";
    };
    compaan = {
      kind = "github";
      apiHost = "git.compaan";
      gitHost = "git.compaan";
      sshUser = "git";
    };
  };

  repositories = builtins.listToAttrs (map mkRepository repositorySpecs);
  principals = builtins.listToAttrs (map mkPrincipal repositorySpecs);
  principalIds = map (spec: spec.id) repositorySpecs;
  tokenEnvironments = builtins.listToAttrs (
    map (spec: {
      name = spec.id;
      value = spec.tokenEnvironment;
    }) repositorySpecs
  );
}
