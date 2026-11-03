// Hook for pi: adds the owner's new Hook answers before each agent run.
// Installed and kept current by `relay integrations`; edits here are reported as drift.
import { execFileSync } from "node:child_process";

const RELAY = "{{relay}}";

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

export default function (pi: any) {
  pi.on("before_agent_start", async (_event: any, ctx: any) => {
    try {
      const text = hookLines(ctx?.sessionManager?.getSessionId?.());
      return text ? { message: { customType: "hook", content: text, display: false } } : undefined;
    } catch {
      return undefined;
    }
  });
}
