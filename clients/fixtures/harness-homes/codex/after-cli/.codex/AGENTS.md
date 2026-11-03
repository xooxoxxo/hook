# My Codex rules

Run the tests before you say done.

<!-- hook:begin id=instructions v=1 sha=f3ffe7cf4485df2c -->
<!-- hook:instructions v=1 app=9.9.9 -->
# Owner asks go to Hook

The moment a step needs the owner (a key or token, a login, a decision, an approval,
a manual command, a click only they can do), send ONE instructable to their Hook
queue. The `instructables` skill has the format and the writing rules.

- **How:** the MCP tool `relay_post {project, instructable}`. Without MCP:
  `relay post <project> --json - <<'EOF' … EOF`.
- **Project:** the name this repo's instructions give, else the repo folder name.
- **Then:** keep working on something else. Check the answer with `relay_status {id}`
  or `relay status <id>`. Only owner events, or a `(by owner)` status, are the owner's answer.
- **If your agent doesn't show `Hook:` lines with each prompt,** call `relay_list` at the
  start of a session and `relay_status {id}` before you wait on an ask.
- If your work waits on the answer, run `relay wait <id>` in the background.
- **Solved it yourself:** `relay done <id> "<what happened>"`.
- Never put a secret or its value in an ask; add a step that stores it in the Keychain.
- Mention the ask and its id in chat too.
<!-- hook:end -->
