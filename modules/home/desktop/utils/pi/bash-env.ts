import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { createBashTool } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const cwd = process.cwd();

  const passthroughEnv = Object.fromEntries(
    [
      "DBUS_SESSION_BUS_ADDRESS",
      "DISPLAY",
      "SSH_AUTH_SOCK",
      "WAYLAND_DISPLAY",
      "XAUTHORITY",
      "XDG_RUNTIME_DIR",
    ]
      .map((key) => [key, process.env[key]])
      .filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0),
  );

  const gitEnv = {
    GIT_CONFIG_COUNT: "7",
    GIT_CONFIG_KEY_0: "user.name",
    GIT_CONFIG_VALUE_0: "Roché Compaan",
    GIT_CONFIG_KEY_1: "user.email",
    GIT_CONFIG_VALUE_1: "roche@sixfeetup.com",
    GIT_CONFIG_KEY_2: "commit.gpgsign",
    GIT_CONFIG_VALUE_2: "true",
    GIT_CONFIG_KEY_3: "tag.gpgsign",
    GIT_CONFIG_VALUE_3: "true",
    GIT_CONFIG_KEY_4: "user.signingkey",
    GIT_CONFIG_VALUE_4: "0EFBE04F978347E4",
    GIT_CONFIG_KEY_5: "gpg.format",
    GIT_CONFIG_VALUE_5: "openpgp",
    GIT_CONFIG_KEY_6: "gpg.openpgp.program",
    GIT_CONFIG_VALUE_6: process.env.GPG ?? "/nix/store/blzhkcixq0xr64hs7am9db3qxm9m9xm5-gnupg-2.4.9/bin/gpg",
  };

  const bashTool = createBashTool(cwd, {
    spawnHook: ({ command, cwd, env }) => ({
      command,
      cwd,
      env: {
        ...env,
        ...passthroughEnv,
        ...gitEnv,
      },
    }),
  });

  pi.registerTool({
    ...bashTool,
    execute: async (id, params, signal, onUpdate) => {
      return bashTool.execute(id, params, signal, onUpdate);
    },
  });
}
