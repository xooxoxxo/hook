"""Check the provenance and five-day minimum age of the installer's two dependencies."""
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
import subprocess
from pathlib import Path
import sys
from urllib.request import urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "clients"))
from pond_release import VERIFIER_HASHES, VERIFIER_VERSION

QR_VERSION = "1.8.0"
QR_WHEEL_SHA256 = "06bf87021bc351f1c6e722ac67db8a059c4fe27bbfbca39ed7a9a2364abdd7a6"


def fetch(url):
    with urlopen(url, timeout=30) as reply:
        return reply.read()


def require_age(date):
    published = datetime.fromisoformat(date.replace("Z", "+00:00"))
    if datetime.now(timezone.utc) - published < timedelta(days=5):
        raise ValueError("Dependency release must be at least five days old")


def main():
    route = "repos/sigstore/cosign/releases/tags/" + VERIFIER_VERSION
    if os.environ.get("GITHUB_ACTIONS"):
        release = json.loads(subprocess.check_output(["gh", "api", route]))
    else:
        release = json.loads(fetch("https://api.github.com/" + route))
    if release["draft"] or release["prerelease"] or release["tag_name"] != VERIFIER_VERSION:
        raise ValueError("Expected a published stable cosign release")
    require_age(release["published_at"])
    assets = {asset["name"]: asset["digest"] for asset in release["assets"]}
    for platform, digest in VERIFIER_HASHES.items():
        if assets["cosign-" + platform] != "sha256:" + digest:
            raise ValueError("Pinned verifier differs from its release asset")
    qr = json.loads(fetch("https://pypi.org/pypi/qrcodegen/" + QR_VERSION + "/json"))
    wheel, = [asset for asset in qr["urls"] if asset["packagetype"] == "bdist_wheel"]
    require_age(wheel["upload_time_iso_8601"])
    data = fetch(wheel["url"])
    if hashlib.sha256(data).hexdigest() != QR_WHEEL_SHA256:
        raise ValueError("Unexpected QR wheel checksum")
    with ZipFile(io.BytesIO(data)) as archive:
        if archive.read("qrcodegen.py") != (ROOT / "clients/qrcodegen.py").read_bytes():
            raise ValueError("Bundled QR encoder differs from its pinned wheel")


if __name__ == "__main__":
    main()
