"""Install, inspect and maintain a Pond from the bundled Hook CLI."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit

import pond_enroll
import pond_host
import pond_release
import pond_ssh
import relay_client


def origin(value):
    try:
        return pond_enroll.origin(value)
    except relay_client.ConfigMissing:
        raise ValueError("Specify a reachable HTTPS Pond origin") from None


def verify_principal(config, descriptor):
    if not config.get("credentialRef"):
        raise ValueError("Join this Mac to verify the admitted client's access")
    client = relay_client.Client(config)
    info = client.pond_info()
    if (not info or str(info[0]) != descriptor["version"]
            or not set(descriptor["features"]).issubset(client.pond_features() or ())):
        raise ValueError("The admitted client could not verify the installed Pond version")


def candidate(target_platform):
    item = pond_release.select_release(pond_release.REQUIRED_RANGE, pond_release.published_releases(),
                                       target_platform, pond_release.REQUIRED_FEATURES)
    host_os = platform.system().lower()
    arch = {"aarch64": "arm64", "x86_64": "amd64"}.get(platform.machine(), platform.machine())
    verifier = pond_release.cached_verifier(Path.home() / ".cache" / "hook" / "cosign", f"{host_os}-{arch}")
    evidence = pond_release.verify_release(item, target_platform, pond_release.tagged_index(item.version), verifier)
    return dict(evidence, version=item.version, features=list(pond_release.REQUIRED_FEATURES))


def join_qr(link):
    from qrcodegen import QrCode
    code = QrCode.encode_text(link, QrCode.Ecc.MEDIUM)
    size = code.get_size()
    rows = []
    for y in range(-4, size + 4, 2):
        line = []
        for x in range(-4, size + 4):
            upper, lower = code.get_module(x, y), code.get_module(x, y + 1)
            line.append((" ", "▀", "▄", "█")[int(upper) + 2 * int(lower)])
        rows.append("\x1b[30;47m" + "".join(line) + "\x1b[0m")
    return "\n".join(rows)


def telegram_config(owner, url):
    if not owner:
        return None
    if not re.fullmatch("[1-9][0-9]*", owner):
        raise ValueError("Use a positive numeric Telegram owner ID")
    try:
        result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "Hook Pond Telegram",
                                 "-a", url, "-w"], capture_output=True, text=True, timeout=60, check=True)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("Could not read the Hook Pond Telegram item from Keychain") from None
    token = result.stdout.strip()
    if not re.fullmatch("[0-9]+:[A-Za-z0-9_-]{20,}", token):
        raise ValueError("The Keychain item does not contain a valid bot token")
    return {"owner": owner, "token": token}


def receipt(path, host, folder):
    name = hashlib.sha256(json.dumps([host, folder]).encode()).hexdigest()
    return path.parent / "pond-installations" / name


def configuration(path):
    relay_client.check_trusted_dir(path.parent)
    relay_client.check_trusted_file(path)
    settings = json.loads(path.read_bytes()) if path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError("Hook configuration must be a JSON object")
    return settings


def bind_config(path, host, folder, url, identity):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    settings = configuration(path)
    location = receipt(path, host, folder)
    location.parent.mkdir(mode=0o700, exist_ok=True)
    relay_client.check_trusted_dir(location.parent)
    pond_host.save(location, {"installation": identity, "url": url})
    if settings.get("mailboxURL") != url:
        for key in ("tokenFile", "credentialRef", "enrolledAgent"):
            settings.pop(key, None)
    settings.update(pondSSHHost=host, pondFolder=folder, mailboxURL=url, source="mailbox")
    pond_host.save(path, settings)


def terminal_for(out):
    if out.isatty():
        return contextlib.nullcontext(out)
    try:
        return open("/dev/tty", "w", encoding="utf-8")
    except OSError:
        raise ValueError("A controlling terminal is required to deliver the one-time join link") from None


def install(args, path, stdin, out):
    host, folder = pond_ssh.host_name(args.host), args.folder
    if not args.url and stdin.isatty():
        out.write("HTTPS Pond origin: ")
        out.flush()
        args.url = stdin.readline().strip()
    url = origin(args.url)
    def remote(action, **data):
        return pond_ssh.request(host, dict(action=action, folder=folder, url=url, **data))
    existing = remote("preflight")
    known = receipt(path, host, folder)
    if known.exists():
        prior = pond_host.read(known)
        if existing.get("installation") != prior["installation"] or url != prior["url"]:
            raise ValueError("The target differs from the previously verified Pond")
    descriptor = existing.get("current") if existing["installed"] else candidate(existing["platform"])
    if not set(pond_release.REQUIRED_FEATURES).issubset(descriptor["features"]):
        raise ValueError("The installed Pond lacks managed installation support")
    if existing["installed"] and (existing["url"] != url or args.telegram_owner_id):
        raise ValueError("Rerun install with the saved origin and existing Telegram configuration")
    telegram = telegram_config(args.telegram_owner_id, url)
    state = remote("install", target=descriptor, telegram=telegram)
    identity = state["installation"]
    if not re.fullmatch("[0-9a-f]{32}", identity):
        raise ValueError("Invalid managed installation ID")
    status = remote("status", installation=identity)
    report = status["report"]
    pond_host.check_status(report, identity, descriptor, False)
    pond_host.routed_health(url, identity, False)
    if report["admission"] != "native":
        raise ValueError("The installer requires native admission")
    if report["claimed"]:
        config = configuration(path)
        if config.get("mailboxURL") == url and config.get("credentialRef"):
            verify_principal(config, descriptor)
        else:
            out.write("Pond already claimed. Join this Mac to verify its access.\n")
    else:
        with terminal_for(out) as tty:
            link = remote("invite", installation=identity)["link"]
            parts = urlsplit(link)
            if (parts.scheme != "hook" or parts.netloc != "join" or parts.path or
                    parse_qs(parts.query) != {"v": ["2"], "pond": [url]} or
                    not re.fullmatch("[A-Za-z0-9_-]+", parts.fragment)):
                raise ValueError("Invalid device invite returned by the managed Pond")
            tty.write(f"Join this Pond within 15 minutes.\n{link}\n{join_qr(link)}\n")
            tty.flush()
    bind_config(path, host, folder, url, identity)
    return 0


def management(args, path, out):
    try:
        config = configuration(path) if path.exists() else {}
    except (ValueError, relay_client.ConfigMissing) as exc:
        raise MissingConfig("Invalid Hook configuration") from exc
    host, folder = config.get("pondSSHHost"), config.get("pondFolder")
    if not host or not folder or not config.get("mailboxURL"):
        raise MissingConfig("No managed Pond configured. Run hook pond install user@host")
    try:
        host, url = pond_ssh.host_name(host), origin(config["mailboxURL"])
    except ValueError as exc:
        raise MissingConfig(str(exc)) from exc
    binding = receipt(path, host, folder)
    if not binding.exists():
        raise MissingConfig("Verify the managed Pond on this Mac with hook pond install")
    known = pond_host.read(binding)
    if known["url"] != url:
        raise MissingConfig("Saved management origin differs from the selected Pond")
    def remote(action, **data):
        return pond_ssh.request(host, dict(action=action, folder=folder, url=url,
                                           installation=known["installation"], **data))
    if args.action == "status":
        current = remote("status")
        report, descriptor = current["report"], current["current"]
        healthy = True
        principal = "awaiting first claim"
        try:
            pond_host.check_status(report, known["installation"], descriptor, False)
            pond_host.routed_health(url, known["installation"], False)
            if report.get("claimed"):
                principal = "unverified"
                verify_principal(config, descriptor)
                principal = "verified"
        except (OSError, ValueError, relay_client.RelayError):
            healthy = False
        summary = {"host": host, "folder": folder, "version": descriptor["version"], "digest": descriptor["digest"],
                   "platform": descriptor["platform"], "required": pond_release.REQUIRED_RANGE, "healthy": healthy,
                   "admission": report["admission"], "telegram": report["telegram"], "backup": current["backup"],
                   "principal": principal, "operation": current["operation"], "operationID": current.get("operationID")}
        if args.json:
            out.write(json.dumps(summary) + "\n")
        else:
            for key, value in summary.items():
                out.write(f"{key}: {value if value is not None else 'none'}\n")
        return 0 if healthy else 1
    target = None
    pending = remote("pending")
    action = "resume" if pending["resume"] else args.action
    if action == "update":
        target = candidate(remote("preflight")["platform"])
    elif action == "rollback":
        details = remote("rollback-info")
        out.write(f"Previous Pond {details['version']}, snapshot {details['backup']}, "
                  f"saved at {details['time']} UTC. Changed data requires reconciliation.\n")
        out.flush()
    job = pending.get("worker") or remote(action, target=target)
    out.write(f"Pond {args.action} {job['id']} started.\n")
    out.flush()
    while True:
        result = remote("worker")
        if result["id"] != job["id"]:
            raise ValueError("Another operation has replaced this one. Run hook pond status")
        if result["state"] == "interrupted":
            raise ValueError("The worker was interrupted. Run the command again to recover its journal")
        if result["state"] == "failed":
            raise ValueError(result["error"])
        if result["state"] != "running":
            out.write("Pond operation: " + result["state"] + "\n")
            if result["state"] == "restored":
                return 1
            if config.get("credentialRef"):
                current = remote("status")
                verify_principal(config, current["current"])
            return 0
        time.sleep(2)


class MissingConfig(ValueError):
    pass


def run(args, stdin, out, err, env):
    path = relay_client.config_path(env)
    try:
        if args.action == "install":
            return install(args, path, stdin, out)
        return management(args, path, out)
    except (ValueError, OSError, KeyError, relay_client.RelayError) as exc:
        err.write(f"hook pond: {exc}\n")
        return 2 if isinstance(exc, (MissingConfig, relay_client.ConfigMissing)) else 1


def arguments(sub):
    pond = sub.add_parser("pond", help="install or manage a Pond over SSH")
    commands = pond.add_subparsers(dest="action", required=True)
    new = commands.add_parser("install", help="install a verified Pond and join the first device")
    new.add_argument("host")
    new.add_argument("--url", help="reachable HTTPS origin")
    new.add_argument("--folder", default="~/pond", help="installation directory on the SSH host")
    new.add_argument("--telegram-owner-id", help="enable Telegram using the bot token in Keychain")
    status = commands.add_parser("status", help="check the configured Pond")
    status.add_argument("--json", action="store_true")
    commands.add_parser("update", help="update to the newest verified compatible release")
    commands.add_parser("rollback", help="restore the previous verified release if its data is still current")
