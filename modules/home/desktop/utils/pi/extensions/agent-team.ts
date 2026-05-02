import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";
import { homedir } from "node:os";
import { Type } from "@sinclair/typebox";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;
type ThinkingLevel = (typeof THINKING_LEVELS)[number];
type AgentRole = "scout" | "planner" | "reviewer" | "worker" | "mechanical-worker" | string;

interface AgentTeamEntry {
  model: string;
  thinking?: ThinkingLevel;
}

interface AgentTeamPreset {
  name: string;
  agents: Record<AgentRole, AgentTeamEntry>;
}

const GLOBAL_AGENT_TEAMS_DIR = join(homedir(), ".pi", "agent", "agent-teams");
const SAFE_PRESET_NAME = /^[A-Za-z0-9._-]+$/;
type PresetScope = "project" | "global";

function projectAgentTeamsDir(cwd: string): string {
  return join(cwd, ".pi", "agent-teams");
}

function readJsonFile<T>(path: string): T | undefined {
  if (!existsSync(path)) return undefined;
  return JSON.parse(readFileSync(path, "utf-8")) as T;
}

function presetLocations(name: string, cwd?: string): Array<{ scope: PresetScope; path: string }> {
  const locations: Array<{ scope: PresetScope; path: string }> = [];
  if (cwd) locations.push({ scope: "project", path: join(projectAgentTeamsDir(cwd), `${name}.json`) });
  locations.push({ scope: "global", path: join(GLOBAL_AGENT_TEAMS_DIR, `${name}.json`) });
  return locations;
}

function loadPreset(name: string, cwd?: string): { preset: AgentTeamPreset; scope: PresetScope; path: string } | undefined {
  for (const location of presetLocations(name, cwd)) {
    if (!existsSync(location.path)) continue;
    const preset = readJsonFile<AgentTeamPreset>(location.path);
    if (preset) return { preset, scope: location.scope, path: location.path };
  }
  return undefined;
}

function safeLoadPreset(
  name: string,
  cwd?: string,
): { preset?: AgentTeamPreset; scope?: PresetScope; path?: string; error?: string } {
  try {
    return loadPreset(name, cwd) ?? {};
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { error: `Failed to read preset '${name}': ${message}` };
  }
}

function listPresetNames(cwd?: string): string[] {
  const names = new Set<string>();
  const dirs = cwd ? [projectAgentTeamsDir(cwd), GLOBAL_AGENT_TEAMS_DIR] : [GLOBAL_AGENT_TEAMS_DIR];
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    try {
      for (const file of readdirSync(dir)) {
        if (file.endsWith(".json")) names.add(file.slice(0, -".json".length));
      }
    } catch {
      continue;
    }
  }
  return [...names].sort();
}

function validatePreset(preset: AgentTeamPreset): string[] {
  const errors: string[] = [];
  if (!preset || typeof preset !== "object") return ["preset must be an object"];
  if (!preset.name || typeof preset.name !== "string") errors.push("missing string field: name");
  if (!preset.agents || typeof preset.agents !== "object" || Array.isArray(preset.agents)) {
    errors.push("missing object field: agents");
  }
  for (const [role, entry] of Object.entries(preset.agents ?? {})) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      errors.push(`${role}: invalid agent entry`);
      continue;
    }
    if (!entry.model || typeof entry.model !== "string") errors.push(`${role}: missing string field model`);
    if (Object.prototype.hasOwnProperty.call(entry, "thinking")) {
      if (typeof entry.thinking !== "string" || !THINKING_LEVELS.includes(entry.thinking)) {
        errors.push(`${role}: invalid thinking '${entry.thinking}'`);
      }
    }
  }
  return errors;
}

function splitProviderModel(model: string): { provider: string; model: string } | undefined {
  const slash = model.indexOf("/");
  if (slash === -1) return undefined;
  return { provider: model.slice(0, slash), model: model.slice(slash + 1) };
}

function formatPreset(name: string, preset: AgentTeamPreset): string {
  const rows = Object.entries(preset.agents)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([role, entry]) => `${role.padEnd(18)} ${entry.model.padEnd(32)} ${entry.thinking ?? "(default)"}`);
  return [`Agent team: ${name}`, "", "role               model                            thinking", ...rows].join("\n");
}

function isSafePresetName(name: string): boolean {
  return Boolean(name) && basename(name) === name && !name.includes("/") && !name.includes("\\") && SAFE_PRESET_NAME.test(name);
}

function resolveActiveTeam(activeTeamName: string | undefined): { source: "session" | "none"; name?: string } {
  if (activeTeamName) return { source: "session", name: activeTeamName };
  return { source: "none" };
}

export default function agentTeamExtension(pi: ExtensionAPI) {
  let activeTeamName: string | undefined;

  function updateStatus(ctx: ExtensionContext) {
    const resolved = resolveActiveTeam(activeTeamName);
    const label = resolved.name ? `team:${resolved.name}` : "team:none";
    ctx.ui.setStatus("agent-team", ctx.ui.theme.fg(resolved.name ? "accent" : "dim", label));
  }

  pi.registerCommand("agent-team", {
    description: "Manage session subagent team",
    handler: async (args, ctx) => {
      const tokens = args.trim().split(/\s+/).filter(Boolean);
      const subcommand = tokens[0] ?? "status";

      if (subcommand === "status") {
        if (!activeTeamName) {
          ctx.ui.notify("No session team selected", "info");
          updateStatus(ctx);
          return;
        }

        const { preset, error } = safeLoadPreset(activeTeamName, ctx.cwd);
        if (error) {
          ctx.ui.notify(error, "error");
        } else if (!preset) {
          ctx.ui.notify(`Session team '${activeTeamName}' no longer exists`, "error");
        } else {
          const validationErrors = validatePreset(preset);
          if (validationErrors.length > 0) {
            ctx.ui.notify(
              `Session team '${activeTeamName}' is invalid:\n${validationErrors.map((entry) => `- ${entry}`).join("\n")}`,
              "error",
            );
          } else {
            ctx.ui.notify(formatPreset(activeTeamName, preset), "info");
          }
        }
        updateStatus(ctx);
        return;
      }

      if (subcommand === "list") {
        const names = listPresetNames(ctx.cwd);
        if (names.length === 0) {
          ctx.ui.notify("No agent team presets found", "info");
        } else {
          ctx.ui.notify(
            names
              .map((name) => (name === activeTeamName ? `${name} (session-active)` : name))
              .join("\n"),
            "info",
          );
        }
        updateStatus(ctx);
        return;
      }

      if (subcommand === "use") {
        const name = tokens[1];
        if (tokens.length !== 2 || !name) {
          ctx.ui.notify("Usage: /agent-team use <team>", "error");
          return;
        }
        if (!isSafePresetName(name)) {
          ctx.ui.notify(`Invalid team name '${name}'`, "error");
          return;
        }

        const { preset, error } = safeLoadPreset(name, ctx.cwd);
        if (error) {
          ctx.ui.notify(error, "error");
          return;
        }
        if (!preset) {
          ctx.ui.notify(`Agent team preset '${name}' does not exist`, "error");
          return;
        }

        const validationErrors = validatePreset(preset);
        if (validationErrors.length > 0) {
          ctx.ui.notify(
            `Agent team preset '${name}' is invalid:\n${validationErrors.map((entry) => `- ${entry}`).join("\n")}`,
            "error",
          );
          return;
        }

        activeTeamName = name;
        pi.appendEntry("agent-team-state", { activeTeamName });
        ctx.ui.notify(`Selected session team '${name}'`, "info");
        updateStatus(ctx);
        return;
      }

      if (subcommand === "validate") {
        if (tokens.length > 2) {
          ctx.ui.notify("Usage: /agent-team validate [team]", "error");
          return;
        }

        const name = tokens[1] ?? activeTeamName;
        if (!name) {
          ctx.ui.notify("No session team selected", "error");
          return;
        }
        if (tokens[1] && !isSafePresetName(tokens[1])) {
          ctx.ui.notify(`Invalid team name '${tokens[1]}'`, "error");
          return;
        }

        const { preset, error } = safeLoadPreset(name, ctx.cwd);
        if (error) {
          ctx.ui.notify(error, "error");
          return;
        }
        if (!preset) {
          ctx.ui.notify(`Agent team preset '${name}' does not exist`, "error");
          return;
        }

        const validationErrors = validatePreset(preset);
        if (validationErrors.length > 0) {
          ctx.ui.notify(
            `Agent team preset '${name}' is invalid:\n${validationErrors.map((entry) => `- ${entry}`).join("\n")}`,
            "error",
          );
          return;
        }

        const modelErrors: string[] = [];
        const warnings: string[] = [];
        for (const [role, entry] of Object.entries(preset.agents)) {
          const parsedModel = splitProviderModel(entry.model);
          if (!parsedModel) {
            warnings.push(`${role}: unprefixed model '${entry.model}' (provider cannot be inferred)`);
            continue;
          }
          if (!ctx.modelRegistry.find(parsedModel.provider, parsedModel.model)) {
            modelErrors.push(`${role}: model not found: ${entry.model}`);
          }
        }

        const lines = [`Agent team preset '${name}' is ${modelErrors.length === 0 ? "valid" : "invalid"}.`];
        if (warnings.length > 0) {
          lines.push("", "Warnings:", ...warnings.map((warning) => `- ${warning}`));
        }
        if (modelErrors.length > 0) {
          lines.push("", "Errors:", ...modelErrors.map((entry) => `- ${entry}`));
        }
        ctx.ui.notify(lines.join("\n"), modelErrors.length === 0 ? "info" : "error");
        return;
      }

      if (subcommand === "clear") {
        activeTeamName = undefined;
        pi.appendEntry("agent-team-state", { activeTeamName: undefined });
        ctx.ui.notify("Cleared session team selection", "info");
        updateStatus(ctx);
        return;
      }

      ctx.ui.notify(`Unknown subcommand '${subcommand}'`, "error");
    },
  });

  pi.registerTool({
    name: "resolve_agent_team",
    label: "Resolve Agent Team",
    description: "Resolve the session-selected subagent team model and thinking mappings",
    parameters: Type.Object({
      role: Type.Optional(Type.String({ description: "Optional role to resolve, such as worker or reviewer" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const resolved = resolveActiveTeam(activeTeamName);
      if (!resolved.name) {
        return {
          content: [
            {
              type: "text",
              text: "No session team selected; ask the human for a session team or use Pi agent defaults if they decline.",
            },
          ],
          details: { source: "none" },
        };
      }

      const { preset, error } = safeLoadPreset(resolved.name, ctx.cwd);
      if (error) {
        return {
          content: [{ type: "text", text: error }],
          details: { source: resolved.source, team: resolved.name, error: "invalid_preset" },
          isError: true,
        };
      }
      if (!preset) {
        return {
          content: [{ type: "text", text: `Selected team '${resolved.name}' has no preset file.` }],
          details: { source: resolved.source, team: resolved.name, error: "missing_preset" },
          isError: true,
        };
      }

      const validationErrors = validatePreset(preset);
      if (validationErrors.length > 0) {
        return {
          content: [
            {
              type: "text",
              text: `Selected team preset '${resolved.name}' is invalid:\n${validationErrors.map((entry) => `- ${entry}`).join("\n")}`,
            },
          ],
          details: { source: resolved.source, team: resolved.name, error: "invalid_preset", errors: validationErrors },
          isError: true,
        };
      }

      const role = typeof params.role === "string" ? params.role : "all";
      const result =
        role === "all"
          ? preset.agents
          : Object.prototype.hasOwnProperty.call(preset.agents, role)
            ? preset.agents[role]
            : null;
      const text =
        result === null
          ? `No agent-team mapping exists for role '${role}' in team '${resolved.name}'; use the agent default for that role.\n${JSON.stringify({ team: resolved.name, source: resolved.source, role, result }, null, 2)}`
          : JSON.stringify({ team: resolved.name, source: resolved.source, role, result }, null, 2);
      return {
        content: [{ type: "text", text }],
        details: { team: resolved.name, source: resolved.source, role, result },
      };
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    activeTeamName = undefined;
    const entries = await ctx.sessionManager.getEntries();
    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index];
      if (entry.type === "custom" && entry.customType === "agent-team-state") {
        const restoredName = entry.data?.activeTeamName;
        activeTeamName = typeof restoredName === "string" && isSafePresetName(restoredName) ? restoredName : undefined;
        break;
      }
    }
    updateStatus(ctx);
  });
}
