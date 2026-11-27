"""Choose a managed Pond image and verify the release workflow's signature before use."""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
import urllib.request
from pathlib import Path
from typing import NamedTuple

from relay_semver import parse_range, parse_version


IMAGE = "ghcr.io/xooxoxxo/pond"
ISSUER = "https://token.actions.githubusercontent.com"
PLATFORMS = ("linux/amd64", "linux/arm64")
INDEX_TYPES = ("application/vnd.oci.image.index.v1+json",
               "application/vnd.docker.distribution.manifest.list.v2+json")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
REQUIRED_RANGE = "^1.1.0"
REQUIRED_FEATURES = ("admission", "longAnswers", "managedInstall")

# From cosign_checksums.txt at the pinned upstream release.
VERIFIER_VERSION = "v3.1.4"
VERIFIER_HASHES = {
    "darwin-amd64": "9d1e4abe2b6be279ed0d2ff706fde1ccd738747c834e3e6d44039c238867334f",
    "darwin-arm64": "9f9b8cd557cf2e5b3df3373a00baa005a86b02391e3e06dd0ce37b3a1533d3a4",
    "linux-amd64": "424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa",
    "linux-arm64": "ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2",
}


class Release(NamedTuple):
    version: str
    digest: str
    repository: str
    features: tuple
    platforms: tuple

    @property
    def ref(self):
        return f"{self.repository}:{self.version}@{self.digest}"


def select_release(required_range, releases, platform, required_features):
    supported = parse_range(required_range)
    candidates = {}
    for release in releases:
        version = parse_version(release.version)
        if not version or version.prerelease or str(version) != release.version or not supported.contains(version):
            continue
        if release.repository != IMAGE or not DIGEST.fullmatch(release.digest):
            raise ValueError("Unexpected Pond image repository or index digest")
        if version in candidates and candidates[version] != release:
            raise ValueError("Two records describe different images for the same Pond version")
        candidates[version] = release
    eligible = [v for v, item in candidates.items() if platform in PLATFORMS
                and platform in item.platforms and set(required_features).issubset(item.features)]
    if not eligible:
        raise ValueError(f"No signed-release candidate for {platform} in {required_range} with the required features")
    return candidates[max(eligible)]


def _file_hash(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def _download(url):
    return urllib.request.urlopen(url, timeout=60)


def cached_verifier(cache, platform, download=_download):
    checksum = VERIFIER_HASHES.get(platform)
    if checksum is None:
        raise ValueError("No pinned cosign verifier for this platform")
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = cache.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("The Hook verifier cache must be a private directory")
    name = f"cosign-{platform}"
    path = cache / f"{name}-{VERIFIER_VERSION}"
    if path.exists() or path.is_symlink():
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode) and stat.S_IMODE(mode) == 0o700 and _file_hash(path) == checksum:
            return path
        raise ValueError("Cached cosign verifier failed its integrity check")
    url = f"https://github.com/sigstore/cosign/releases/download/{VERIFIER_VERSION}/{name}"
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as target:
        tmp = Path(target.name)
    try:
        with download(url) as source, tmp.open("wb") as target:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                target.write(block)
        if _file_hash(tmp) != checksum:
            raise ValueError("Downloaded cosign verifier has the wrong SHA-256")
        tmp.chmod(0o700)
        os.replace(tmp, path)
        return path
    finally:
        tmp.unlink(missing_ok=True)


def verify_release(release, platform, tagged_index, verifier):
    """Hash the index returned for the tag, then verify its exact digest and signer."""
    select_release("=" + release.version, [release], platform, ())
    if "sha256:" + hashlib.sha256(tagged_index).hexdigest() != release.digest:
        raise ValueError("The Pond tag no longer matches the published index digest")
    index = json.loads(tagged_index)
    if index.get("schemaVersion") != 2 or index.get("mediaType") not in INDEX_TYPES:
        raise ValueError("Expected a multi-platform Pond image index")
    for required in PLATFORMS:
        os_name, arch = required.split("/")
        matches = [m for m in index.get("manifests", []) if
                   m.get("platform", {}).get("os") == os_name and
                   m["platform"].get("architecture") == arch and
                   m["platform"].get("variant", "") in (("", "v8") if arch == "arm64" else ("",))]
        if len(matches) != 1 or not DIGEST.fullmatch(matches[0].get("digest", "")):
            raise ValueError(f"Expected exactly one {required} image in the signed index")
    signer = f"https://github.com/xooxoxxo/pond/.github/workflows/release.yml@refs/tags/v{release.version}"
    command = [str(verifier), "verify", "--certificate-identity", signer,
               "--certificate-oidc-issuer", ISSUER, "--output", "json", f"{IMAGE}@{release.digest}"]
    try:
        process = subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError("Cosign could not verify the Pond release signature") from exc
    signatures = json.loads(process.stdout)
    if not isinstance(signatures, list) or not signatures:
        raise ValueError("Cosign returned no verified signatures")
    for signature in signatures:
        claims = signature.get("optional") or {}
        signed_digest = signature.get("critical", {}).get("image", {}).get("docker-manifest-digest")
        if signed_digest != release.digest or claims.get("Subject", signer) != signer or claims.get("Issuer", ISSUER) != ISSUER:
            raise ValueError("Cosign returned an unexpected signature identity or digest")
    return {"digest": release.digest, "signer": signer, "issuer": ISSUER,
            "platform": platform, "verifier": VERIFIER_VERSION}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def read_metadata(request):
    with urllib.request.build_opener(_NoRedirect()).open(request, timeout=30) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError("Release metadata exceeds the size limit")
        return data


def published_releases(fetch=read_metadata):
    """Read the public release workflow's Image, Digest and Features lines."""
    page = 1
    while True:
        rows = json.loads(fetch(f"https://api.github.com/repos/xooxoxxo/pond/releases?per_page=100&page={page}"))
        if not isinstance(rows, list):
            raise ValueError("Could not read Pond release metadata")
        for row in rows:
            if row["draft"] or row["prerelease"]:
                continue
            version = row["tag_name"].removeprefix("v")
            v = parse_version(version)
            if not v or v.prerelease or row["tag_name"] != f"v{v}":
                continue
            body = (row["body"] or "").replace("\r\n", "\n")
            features = re.findall(r"^Features: ([a-zA-Z0-9 ]+)$", body, re.MULTILINE)
            if not features:
                continue  # Older releases have no management metadata.
            images = re.findall(r"^Image: `([^`\n]+)`$", body, re.MULTILINE)
            digests = re.findall(r"^Digest: `(sha256:[0-9a-f]{64})` \(one index: linux/amd64, linux/arm64\)$",
                                 body, re.MULTILINE)
            if images != [f"{IMAGE}:{version}"] or len(digests) != 1 or len(features) != 1:
                raise ValueError("Published Pond release metadata does not match its tag")
            yield Release(version, digests[0], IMAGE, tuple(features[0].split()), PLATFORMS)
        if len(rows) < 100:
            return
        page += 1


def tagged_index(version, fetch=read_metadata):
    v = parse_version(version)
    if not v or v.prerelease or str(v) != version:
        raise ValueError("Expected a stable Pond version")
    url = "https://ghcr.io/token?service=ghcr.io&scope=repository:xooxoxxo/pond:pull"
    token = json.loads(fetch(urllib.request.Request(url)))["token"]
    req = urllib.request.Request(f"https://ghcr.io/v2/xooxoxxo/pond/manifests/{version}",
                                 headers={"Authorization": "Bearer " + token,
                                          "Accept": ", ".join(INDEX_TYPES)})
    return fetch(req)


def check_build_compatibility(swift, notes):
    app = re.search(r'enum PondCompat\s*\{[^}]*?static let required\s*=\s*"([^"]+)"', swift, re.S)
    ranges = re.findall(r'<!--\s*hook:pond\s*=\s*(.*?)\s*-->', notes)
    if not app or ranges != [REQUIRED_RANGE] or app.group(1) != REQUIRED_RANGE:
        raise ValueError("Hook release notes, installer and PondCompat must specify the same Pond range")
    if not re.search(r'<!--\s*hook:mailbox-protocol=[0-9]+\s*-->', notes):
        raise ValueError("Hook release notes must include the legacy protocol marker")


if __name__ == "__main__":
    import sys
    try:
        check_build_compatibility(Path(sys.argv[1]).read_text(), sys.stdin.read())
    except ValueError as exc:
        sys.exit(str(exc))
