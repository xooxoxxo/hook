# Run your own Pond

A Pond keeps your queue available to Hook on your Mac, your phone and your agents. You need a Hook build with `hook pond install`, a published signed Pond image with the `admission`, `longAnswers` and `managedInstall` features, and Hook clients that support **Join a Pond**. The first device to claim the invite becomes the administrator. Telegram is optional.

## Prepare the server

Use a Linux AMD64 or ARM64 host with Python 3.9 or later, Docker Engine, Docker Compose v2 or later, and storage for the queue, a working copy and backups. The SSH account needs access to the local Docker socket. Keep its SSH access available for recovery.

From your Mac, connect once with `ssh operator@pond.example`. Compare the host-key fingerprint with the server console before accepting it. Confirm that the account can run `docker version` and `docker compose version` without an interactive password prompt. The installer uses the same SSH configuration and requires a known host key. Choose an unused folder under the account’s home. The default is `~/pond`.

## Give the Pond an HTTPS address

Choose one HTTPS origin that the server, your Mac and your phone can reach. Use the same origin for pairing and future connections. The installer publishes the service on the server’s `127.0.0.1:8790`. You provide the HTTPS proxy.

**Public domain with Caddy.** Point your domain’s DNS records at the proxy. Allow incoming TCP ports 80 and 443 to Caddy. On the Pond host, add this site to the Caddyfile, substituting your domain, then validate and reload Caddy. Keep port 8790 private. [Caddy reverse proxy guide](https://caddyserver.com/docs/quick-starts/reverse-proxy)

```caddyfile
pond.example {
    reverse_proxy 127.0.0.1:8790
}
```

A proxy on another machine has its own loopback interface. Give it a private tunnel to the Pond host. For example, an SSH forward on the proxy can bind its local port 18790 to the Pond host’s loopback port 8790. Point the proxy upstream at `127.0.0.1:18790` and supervise that tunnel.

**Private HTTPS with Tailscale.** Connect the Pond host and both devices to your tailnet. Enable HTTPS certificates for the tailnet and allow these devices to reach the host. On the Pond host, run the following commands and use the HTTPS origin Serve prints. [Tailscale Serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve)

```sh
tailscale serve --bg http://127.0.0.1:8790
tailscale serve status
```

For a LAN-only proxy, use a DNS name and a certificate trusted on every device. A phone on cellular needs a route into that network, such as Tailscale.

## Install and join

On your Mac, substitute your SSH account and HTTPS origin. Add `--folder ~/your-folder` with the tilde **quoted** if you choose another remote folder, for example `--folder '~/services/pond'`. Its parent directory must already exist.

```sh
hook pond install operator@pond.example --url https://pond.example
```

Hook verifies the release’s platform, digest and signature, starts the Pond, and checks its authenticated version and HTTPS health. It then displays a one-use link and QR code on your terminal. Open **Join a Pond** on your first device and scan the code or paste the link within 15 minutes. Treat both as credentials. If the link expires before anyone joins, run the same install command to replace it.

Open `https://pond.example/health` on the phone on the network you intend to use. Check that HTTPS validates and the response says `"ok": true`. If the Mac connects but the phone cannot, check the phone’s DNS, VPN, access rules and certificate trust. Replacing an invite cannot repair an unreachable origin.

For a second device, create a device invite on an admitted device. Join on the new device, compare the six-digit code on both screens and approve on the existing device. Use **Devices** to revoke a lost device or retired agent.

## Enroll an agent and test a round trip

Create an agent invite on an admitted device. On the agent host, run the following as the account that runs the agent. Use a separate profile if that account also has an owner profile.

```sh
export RELAY_CONFIG="$HOME/.config/relay/agents/builder.json"
hook host enroll --agent Builder
```

Paste the invite at the hidden prompt. Compare the host’s six digits with the request on your device and approve. On Linux, the agent account needs `secret-tool` and an unlocked Secret Service collection. Have the agent post a test ask. Answer it on your phone, then check the answer from the same agent profile. This works with native admission and no Telegram bot.

## Optional Telegram

Before the first install, add a generic password in the Mac login Keychain. Use **Hook Pond Telegram** for the item name, the exact HTTPS origin for its account, and the bot token for its password. Append `--telegram-owner-id YOUR_NUMERIC_ID` to the install command. Hook reads the token from Keychain and transfers it over SSH to the protected server configuration.

## Update and rollback

```sh
hook pond status
hook pond update
hook pond rollback
```

Status reports the installed version, index digest, platform, health, admission mode, Telegram setting, last snapshot and operation. After the first claim, status also checks the enrolled credential on this Mac. A missing or revoked credential reports degraded status. Use `--json` for machine-readable output. In Hook’s Queue settings, a managed installation uses the bundled updater. An existing advanced update command takes precedence until you clear it.

Update verifies and pulls the candidate before stopping the serving process. It snapshots the queue and credentials and probes a working copy with external writes held. A failed check before commit restores the previous verified service. If SSH disconnects, reconnect and run status. A detached operation can finish on the host. If the host itself restarted, rerun the interrupted command to recover.

Look up the snapshot ID with status. On the host, `backups/<id>/` contains the SQLite backup, protected data files and verification manifest. `recovery/<id>/` holds the matching Compose file, protected configuration and image and volume identities. Keep both directories private and copy them together to protected backup storage. Retain the recorded previous image and volume for rollback.

Rollback checks the previous snapshot and takes a fresh recovery copy before switching. If the queue or admission records changed since the update, the command keeps the current data and reports the recovery copy and time window. Reconcile new asks, answers, revocations and consumed invites on an isolated copy before authorizing any restore. Keep a service that cannot enforce the current revocations isolated.

## Recover access after losing your last device

SSH into the server and change to the managed installation folder. Generate a recovery invite from a private terminal.

```sh
docker compose exec -T mailbox python3 -m mailbox.admin admission invite --recovery
```

Open the returned link on your replacement device. If the device slots are full, list them with `docker compose exec -T mailbox python3 -m mailbox.admin admission devices`. Add `--replace DEVICE_ID` to the recovery command to select the lost device. After joining, review the admitted devices and revoke any remaining lost credentials.
