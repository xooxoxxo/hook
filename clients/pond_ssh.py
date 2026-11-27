"""Run the bundled, fixed management program over OpenSSH. Request data travels on stdin."""
import json
from pathlib import Path
import re
import shlex
import subprocess


def host_name(value):
    if not isinstance(value, str) or not re.fullmatch(
            r"(?:[a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9][a-zA-Z0-9.-]*", value):
        raise ValueError("Use an SSH alias, hostname or user@host without spaces or options")
    return value


def request(host, payload):
    source = Path(__file__).with_name("pond_host.py").read_text()
    command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "ConnectTimeout=12", "--", host_name(host), "python3 -c " + shlex.quote(source)]
    try:
        process = subprocess.run(command, input=json.dumps(dict(payload, template=Path(__file__).with_name("pond-compose.json").read_text())), capture_output=True, text=True, timeout=1100)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("SSH did not complete. Check the host, then run pond status") from None
    if process.returncode:
        raise ValueError("SSH failed. Check the host key, SSH access and remote Python 3")
    try:
        envelope = json.loads(process.stdout)
    except ValueError:
        raise ValueError("The SSH host returned an unreadable reply") from None
    if "error" in envelope:
        raise ValueError(envelope["error"])
    return envelope["result"]
