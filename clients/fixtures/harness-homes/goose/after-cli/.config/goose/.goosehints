<!-- hook:begin id=instructions v=1 sha=bdbb1976176def16 -->
<!-- hook:instructions v=1 app=9.9.9 -->
# Owner asks go to Hook

Answer explanations, summaries and status questions directly. Make routine choices within
the owner's instructions without asking again.

Keep in chat, not Hook: quick clarifications with a short answer or multiple choice; quick
actions while the owner is in the chat (a tap, a glance, one short step on a device in front
of them); single yes/no approvals, including simple merge or release approvals; and status
notes like "I'm waiting for you to do X", progress and reminders. Use the chat's question
control or buttons if it has them. For an approval, state the exact change and wait before acting.

Send ONE instructable to Hook for actions the owner does later or away from the chat,
credentials, logins and secrets, commands on machines you can't reach, approvals bundled with
those, consequential decisions needing context, and work needing a durable checklist or
follow-up. Don't add steps to turn a simple approval into an ask. Follow the owner's explicit
routing preference. The `instructables` skill has the format and writing rules.

An approval that already reaches the owner through its own prompt is not a Hook ask: a
Telegram bot such as an SSH lease or cert request, a 2FA push, or a system dialog. At most,
mention it in one chat line.

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
- When your next steps depend on the owner's answer, add them with `relay_append`. Never close
  the ask and post a new one. To change a step the owner already saw, use `relay_amend`.
  The loop is post, `relay wait`, `relay_append`, `relay wait`. Mark the question
  `"then": "steps"` when more steps will follow its answer.
- **Solved it yourself, so the need is gone:** `relay done <id> "<what happened>"`.
- Never put a secret or its value in an ask; add a step that stores it in the Keychain.
- Mention the ask and its id in chat too.
<!-- hook:end -->
