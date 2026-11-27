"""Release-route tests with synthetic tags and OCI index bytes."""
import hashlib
import io
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import pond_release as release


FEATURES = ("longAnswers", "admission")
REPO = "ghcr.io/xooxoxxo/pond"
ISSUER = "https://token.actions.githubusercontent.com"


def image_index(arches=("amd64", "arm64")):
    return json.dumps({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [{"digest": "sha256:" + "e" * 64, "platform": {
            "os": "linux", "architecture": arch}} for arch in arches],
    }).encode()


def digest(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def candidate(version="1.16.0", raw=None, repo=REPO, features=FEATURES):
    return release.Release(version, digest(image_index() if raw is None else raw),
                           repo, tuple(features), ("linux/arm64", "linux/amd64"))


class ReleaseTests(unittest.TestCase):
    def test_selects_newest_eligible_stable_version_numerically(self):
        releases = [candidate(v) for v in ("1.9.9", "1.16.10", "2.0.0",
                                           "1.17.0-rc.1", "1.16.9")]
        releases.append(candidate("1.18.0", features=("longAnswers",)))
        result = release.select_release("^1.1.0", releases, "linux/arm64", FEATURES)
        self.assertEqual(result.ref, REPO + ":1.16.10@" + digest(image_index()))

    def test_refuses_ineligible_candidates(self):
        for item in (candidate("1.0.0"), candidate("2.0.0"), candidate("1.17.0-rc.1"),
                     candidate(repo="ghcr.io/example/pond"), candidate(features=()),
                     candidate()._replace(platforms=("linux/amd64",))):
            with self.subTest(item=item), self.assertRaises(ValueError):
                release.select_release("^1.1.0", [item], "linux/arm64", FEATURES)

    def test_refuses_conflicting_digests_for_one_version(self):
        with self.assertRaises(ValueError):
            release.select_release("^1.1.0", [candidate(), candidate(raw=b"changed")],
                                   "linux/arm64", FEATURES)

    def test_signed_release_matches_the_index_and_tag(self):
        signature = [{"critical": {"image": {"docker-manifest-digest": digest(image_index())}}}]
        with patch("pond_release.subprocess.run") as run:
            run.return_value.stdout = json.dumps(signature)
            result = release.verify_release(candidate(), "linux/arm64", image_index(), Path("/verifier"))
        identity = "https://github.com/xooxoxxo/pond/.github/workflows/release.yml@refs/tags/v1.16.0"
        args = run.call_args.args[0]
        self.assertEqual(args[args.index("--certificate-identity") + 1], identity)
        self.assertEqual(args[args.index("--certificate-oidc-issuer") + 1], ISSUER)
        self.assertIn(REPO + "@" + digest(image_index()), args)
        self.assertEqual(result["signer"], identity)

    def test_invalid_index_or_signature_never_reaches_start(self):
        valid = {"critical": {"image": {"docker-manifest-digest": digest(image_index())}}}
        cases = [(candidate(), image_index(("arm64",)), [valid]),
                 (candidate(raw=image_index(("amd64",))), image_index(("amd64",)), [valid]),
                 (candidate(), image_index(), []),
                 (candidate(), image_index(), [dict(valid, optional={"Subject": "another-workflow"})]),
                 (candidate(), image_index(), [dict(valid, optional={"Issuer": "another-issuer"})]),
                 (candidate(), image_index(), [{"critical": {"image": {"docker-manifest-digest": "bad"}}}])]
        for item, raw, signatures in cases:
            started_containers = []
            with self.subTest(item=item, signatures=signatures), patch("pond_release.subprocess.run") as run:
                run.return_value.stdout = json.dumps(signatures)
                with self.assertRaises(ValueError):
                    release.verify_release(item, "linux/arm64", raw, Path("/verifier"))
                    started_containers.append(item.ref)
                self.assertEqual(started_containers, [])

    def test_verifier_cache_checks_download_and_each_reuse(self):
        good = b"synthetic binary"
        with TemporaryDirectory() as tmp:
            cache = Path(tmp) / "cache"
            with patch.object(release, "VERIFIER_HASHES", {"darwin-arm64": hashlib.sha256(good).hexdigest()}):
                with self.assertRaises(ValueError):
                    release.cached_verifier(cache, "darwin-arm64", lambda url: io.BytesIO(b"bad"))
                path = release.cached_verifier(cache, "darwin-arm64", lambda url: io.BytesIO(good))
                self.assertEqual(path.read_bytes(), good)
                self.assertEqual(path.stat().st_mode & 0o777, 0o700)
                self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
                path.write_bytes(b"tampered")
                with self.assertRaises(ValueError):
                    release.cached_verifier(cache, "darwin-arm64", lambda url: io.BytesIO(b"bad"))


class PublishedReleaseTests(unittest.TestCase):
    def test_consumes_workflow_notes_only_for_published_stable_tags(self):
        tag = {"tag_name": "v1.16.0", "draft": False, "prerelease": False,
               "body": f"Image: `{REPO}:1.16.0`\nDigest: `{digest(image_index())}` (one index: linux/amd64, linux/arm64)\nFeatures: admission longAnswers"}
        pages = [[tag, dict(tag, draft=True), dict(tag, prerelease=True)], []]
        def fetch(url):
            self.assertTrue(url.startswith("https://api.github.com/repos/xooxoxxo/pond/releases?"))
            return json.dumps(pages.pop(0)).encode()
        self.assertEqual(list(release.published_releases(fetch)),
                         [candidate(features=("admission", "longAnswers"))._replace(platforms=("linux/amd64", "linux/arm64"))])

    def test_old_release_without_features_is_ineligible(self):
        self.assertEqual(list(release.published_releases(lambda url: b'[{"tag_name":"v1.9.0","body":"old release","draft":false,"prerelease":false}]')), [])

    def test_tagged_index_uses_anonymous_pull_scope_and_tag(self):
        requests = []
        def fetch(request):
            requests.append(request)
            return b'{"token":"synthetic"}' if len(requests) == 1 else image_index()
        self.assertEqual(release.tagged_index("1.16.0", fetch), image_index())
        self.assertIn("scope=repository:xooxoxxo/pond:pull", requests[0].full_url)
        self.assertEqual(requests[1].full_url, "https://ghcr.io/v2/xooxoxxo/pond/manifests/1.16.0")


class CompatibilityTests(unittest.TestCase):
    def test_support_build_refuses_range_drift_or_absent_legacy_marker(self):
        swift = 'public enum PondCompat {\n    public static let required = "^1.1.0"\n}'
        notes = "<!-- hook:pond=^1.1.0 -->\n<!-- hook:mailbox-protocol=5 -->"
        release.check_build_compatibility(swift, notes)
        for source, body in ((swift.replace("^1.1.0", "^2.0.0"), notes),
                             (swift, notes.replace("^1.1.0", "^2.0.0")),
                             (swift, notes.splitlines()[0])):
            with self.assertRaises(ValueError):
                release.check_build_compatibility(source, body)
