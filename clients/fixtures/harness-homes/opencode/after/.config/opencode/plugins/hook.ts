// Hook for OpenCode: puts the owner's new Hook answers into the system prompt.
// Installed and kept current by `relay integrations`; edits here are reported as drift.
import { execFileSync } from "node:child_process";

const RELAY = "/HOME/.local/share/hook/current/bin/relay";

function hookLines(sessionId: unknown): string {
  try {
    const out = execFileSync(RELAY, ["hook", "replies", "--format", "plain"], {
      input: JSON.stringify({ session_id: typeof sessionId === "string" ? sessionId : "" }),
      timeout: 3000,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "ignore"],
    });
    return String(out).trim();
  } catch {
    return "";
  }
}

export const HookPlugin = async (ctx: any) => {
  // Plugin API V2: ctx.session.hook("prompt", …).
  if (ctx.session?.hook) {
    try {
      ctx.session.hook("prompt", async (input: any, output: any) => {
        const text = hookLines(input?.sessionID ?? input?.session?.id);
        if (text && Array.isArray(output?.system)) output.system.push(text);
      });
    } catch {
      // A V2 build with another hook shape: Hook's instructions still cover it.
    }
    return {};
  }
  // Plugin API V1.
  return {
    "experimental.chat.system.transform": async (input: any, output: any) => {
      const text = hookLines(input?.sessionID);
      if (text && Array.isArray(output?.system)) output.system.push(text);
    },
  };
};
