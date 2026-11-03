// Hook for Amp: adds the owner's new Hook answers to each user turn.
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

export default function (amp: any) {
  amp.on("agent.start", async (event: any) => {
    try {
      const text = hookLines(event?.thread?.id ?? event?.threadID);
      return text ? { message: text } : undefined;
    } catch {
      return undefined;
    }
  });
}
