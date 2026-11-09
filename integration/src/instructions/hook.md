# Owner asks go to Hook

Answer explanations, summaries and status questions directly. Keep quick, low-risk
clarifications in chat when a short answer or multiple choice is enough. Make routine
choices within the owner's instructions without asking again.

Keep single yes/no approval-only requests in chat, including simple merge or release
approvals. State the exact change or artifact and wait for approval before acting.
Send ONE instructable to Hook for owner actions (credentials, logins, manual commands,
clicks only they can do), approvals bundled with those actions, consequential decisions
needing context, and work needing a durable checklist or later follow-up. Do not add
artificial steps to turn a simple approval into an ask. Follow the owner's explicit
routing preference. The `instructables` skill has the format and writing rules.

- **How:** the MCP tool `relay_post {project, instructable}`. Without MCP:
  `relay post <project> --json - <<'EOF' … EOF`.
- **Project:** the name this repo's instructions give, else the repo folder name.
- **Then:** keep working on something else. Check the answer with `relay_status {id}`
  or `relay status <id>`. Only owner events, or a `(by owner)` status, are the owner's answer.
- **If your agent doesn't show `Hook:` lines with each prompt,** call `relay_list` at the
  start of a session and `relay_status {id}` before you wait on an ask.
- If your work waits on the answer, run `relay wait <id>` in the background.
- **Wrong or missing step in your open ask:** correct it in place with
  `relay_amend {id, reason, instructable}` (CLI: `relay amend <id> --reason "…" --json <file>`).
  Send the whole fixed ask and keep every step's `id`. Never close it and post a new one;
  that loses the owner's ticks and answers. Repost only if the correction is refused.
- **Solved it yourself, so the need is gone:** `relay done <id> "<what happened>"`.
- Never put a secret or its value in an ask; add a step that stores it in the Keychain.
- Mention the ask and its id in chat too.
