"""Fixed host-side operations for a managed Pond. Runs on the Linux SSH target."""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import shutil
import socket
import sys
import subprocess
import urllib.request
from pathlib import Path
import tempfile
import time
import uuid


# The identical template is published in the Pond repository as mailbox/compose.managed.json.
# The SSH entry point receives the packaged copy before dispatch.
COMPOSE_TEMPLATE = Path(__file__).with_name("pond-compose.json").read_text() if __name__ != "__main__" else ""


def atomic(path, contents):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        tmp = Path(stream.name)
        try:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(tmp, path)
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            tmp.unlink(missing_ok=True)


def save(path, record):
    atomic(path, (json.dumps(record, sort_keys=True) + "\n").encode())


def read(path):
    return json.loads(path.read_bytes())


@contextlib.contextmanager
def lock(folder):
    with os.fdopen(os.open(folder / "manage.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("A management operation is already running") from None
        yield


def phase(folder, journal, name):
    journal["phase"] = name
    save(folder / "operation.json", journal)


def open_committed(folder, runtime, journal):
    state = journal["next"]
    save(folder / "state.json", state)
    runtime.serve(state["current"], fenced=False)
    runtime.verify(state, state["current"], fenced=False)
    phase(folder, journal, "completed")
    return journal


def recover(folder, runtime, journal):
    """After a host restart never undo an intent that could have admitted new writes."""
    if journal["phase"] == "opening":
        return open_committed(folder, runtime, journal)
    source = journal["source"]
    current = source["current"]
    if journal["phase"] != "prepared":
        phase(folder, journal, "recovering")
        runtime.stop()
        runtime.serve(current, fenced=True)
        info = runtime.verify(source, current, fenced=True)
        if "snapshot" in journal and info != journal["snapshot"]:
            raise ValueError("Original volume differs from its verified snapshot; recovery remains fenced")
        journal["next"] = source
        phase(folder, journal, "opening")
        open_committed(folder, runtime, journal)
    phase(folder, journal, "restored")
    return journal


def operate(folder, runtime, kind, target):
    with lock(folder):
        return operate_locked(folder, runtime, kind, target)


def operate_locked(folder, runtime, kind, target):
    path = folder / "operation.json"
    if path.exists():
        unfinished = read(path)
        if unfinished["phase"] not in ("completed", "restored"):
            return recover(folder, runtime, unfinished)
    if kind == "resume":
        return {"phase": "current"}
    state = read(folder / "state.json")
    current = state["current"]
    runtime.identify(state)
    op = uuid.uuid4().hex
    if kind == "rollback":
        previous = state.get("previous")
        if not previous:
            raise ValueError("No previous verified backup is available")
        target = previous["source"]
        runtime.check_backup(previous)
    elif kind == "update":
        if current["digest"] == target["digest"]:
            return {"phase": "current", "id": state.get("lastOperation")}
        target = dict(target, volume=f"pond-{state['installation']}-{op}", imageID=runtime.pull(target))
    else:
        raise ValueError("Unknown operation")
    journal = {"id": op, "kind": kind, "source": state, "target": target, "started": int(time.time())}
    phase(folder, journal, "prepared")
    try:
        runtime.preserve(journal)
        phase(folder, journal, "stopping")
        runtime.stop()
        journal["snapshot"] = runtime.snapshot(current, op)
        phase(folder, journal, "snapshotted")
        if kind == "rollback":
            if (journal["snapshot"] != previous["baseline"]
                    or not runtime.same_environment(previous["backup"], op)):
                raise ValueError(f"Changes since {previous['time']} require reconciliation; recovery copy {op}")
        else:
            runtime.clone(current, target, op)
        phase(folder, journal, "testing")
        runtime.serve(target, fenced=True)
        baseline = runtime.verify(state, target, fenced=True)
        if kind == "rollback" and baseline != previous["snapshot"]:
            raise ValueError("Previous volume differs from its verified snapshot")
        for table, count in journal["snapshot"]["counts"].items():
            if baseline["counts"].get(table) != count:
                raise ValueError("Candidate failed the record count check")
        journal["next"] = dict(state, current=target, lastOperation=op,
                               previous={"source": current, "backup": op, "snapshot": journal["snapshot"],
                                         "baseline": baseline, "time": journal["started"]})
        phase(folder, journal, "opening")
    except Exception:
        recover(folder, runtime, journal)
        raise
    return open_committed(folder, runtime, journal)

def image_ref(descriptor):
    version, digest = descriptor["version"], descriptor["digest"]
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Invalid managed image version")
    if not re.fullmatch("sha256:[0-9a-f]{64}", digest):
        raise ValueError("Invalid managed image digest")
    return f"ghcr.io/xooxoxxo/pond:{version}@{digest}"


def compose(state, descriptor, fenced):
    spec = json.loads(COMPOSE_TEMPLATE)
    service = spec["services"]["mailbox"]
    service["image"] = image_ref(descriptor)
    service["environment"].update(MAILBOX_PUBLIC_ORIGIN=state["url"], POND_INSTALL_ID=state["installation"],
                                  POND_MAINTENANCE="1" if fenced else "0")
    spec["volumes"]["data"]["name"] = descriptor["volume"]
    spec["name"] = "pond-" + state["installation"]
    return spec


def check_status(status, installation, descriptor, fenced):
    health, version = status["health"], status["version"]
    if status["installation"] != installation or version.get("service") != "pond":
        raise ValueError("The reported Pond identity differs from this installation")
    if health.get("ok") is not True or bool(health.get("fenced")) != fenced:
        raise ValueError("The Pond is unhealthy or in the wrong maintenance mode")
    if version.get("version") != descriptor["version"] or not set(descriptor["features"]).issubset(version.get("features", ())):
        raise ValueError("The authenticated version or feature set does not match the release")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def routed_health(url, installation, fenced):
    opener = urllib.request.build_opener(NoRedirect())
    with opener.open(url + "/health", timeout=8) as reply:
        result = json.loads(reply.read(16384))
    if result.get("ok") is not True or result.get("installation") != installation or bool(result.get("fenced")) != fenced:
        raise ValueError("The HTTPS route did not reach the expected healthy Pond")


class Docker:
    def __init__(self, folder, state):
        self.folder = folder
        self.state = state
        self.project = "pond-" + state["installation"]
        self.compose_args = ("compose", "--project-name", self.project, "--file", str(folder / "compose.yaml"))

    def docker(self, *args, timeout=120):
        result = subprocess.run(["docker", *args], cwd=self.folder, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise ValueError(f"Docker {args[0]} failed (exit {result.returncode})")
        return result.stdout.strip()

    def pull(self, target):
        ref = image_ref(target)
        self.docker("pull", "--platform", target["platform"], ref, timeout=900)
        return self.docker("image", "inspect", "--format", "{{.Id}}", ref)

    def inspect(self, descriptor):
        cid = self.docker(*self.compose_args, "ps", "-q", "mailbox")
        if not re.fullmatch("[0-9a-f]{12,64}", cid):
            raise ValueError("The managed service is not running")
        actual = self.docker("inspect", "--format", "{{.Image}}", cid)
        mounts = json.loads(self.docker("inspect", "--format", "{{json .Mounts}}", cid))
        data = [m for m in mounts if m["Destination"] == "/data"]
        backups = [m for m in mounts if m["Destination"] == "/backups"]
        if (actual != descriptor["imageID"] or len(data) != 1 or data[0].get("Name") != descriptor["volume"]
                or len(backups) != 1 or backups[0]["Source"] != str(self.folder / "backups")):
            raise ValueError("The service image or mounted volumes differ from this installation")

    def check_volume_users(self, volume):
        managed = self.docker(*self.compose_args, "ps", "-q", "mailbox")
        users = self.docker("ps", "--no-trunc", "-q", "--filter", "volume=" + volume)
        if any(not managed or not cid.startswith(managed) for cid in users.splitlines()):
            raise ValueError("Another running container mounts the managed volume")

    def identify(self, state):
        if read(self.folder / "compose.yaml") != compose(state, state["current"], False):
            raise ValueError("Managed Compose configuration changed")
        self.check_volume_users(state["current"]["volume"])
        self.inspect(state["current"])
        self.verify(state, state["current"], False)

    def preserve(self, journal):
        dest = self.folder / "recovery" / journal["id"]
        dest.mkdir(mode=0o700, parents=True)
        for name in ("compose.yaml", "pond.env", "state.json"):
            atomic(dest / name, (self.folder / name).read_bytes())

    def same_environment(self, previous, current):
        recovery = self.folder / "recovery"
        return (recovery / previous / "pond.env").read_bytes() == (recovery / current / "pond.env").read_bytes()

    def require_idle(self, volume):
        if self.docker("ps", "-q", "--filter", "volume=" + volume):
            raise ValueError("A running container still mounts the managed volume")

    def stop(self):
        self.docker(*self.compose_args, "stop", "--timeout", "30", "mailbox")
        if self.docker(*self.compose_args, "ps", "-q", "mailbox"):
            raise ValueError("Could not stop the previous writer")

    def helper(self, image, volume, mode, op):
        self.docker("volume", "inspect", volume, "--format", "{{.Name}}")
        mount = f"type=volume,source={volume},target=/data"
        if mode != "restore":
            mount += ",readonly"
        backup = f"type=bind,source={self.folder / 'backups'},target=/backups"
        if mode != "snapshot":
            backup += ",readonly"
        return json.loads(self.docker("run", "--rm", "--network", "none", "--pull", "never",
                                      "--mount", mount, "--mount", backup, image,
                                      "python3", "-m", "mailbox.admin", "maintenance", mode, op, timeout=900))

    def snapshot(self, current, op):
        self.require_idle(current["volume"])
        return self.helper(current["imageID"], current["volume"], "snapshot", op)

    def clone(self, current, target, op):
        self.create_volume(target["volume"])
        self.helper(target["imageID"], target["volume"], "restore", op)

    def create_volume(self, volume):
        existing = self.docker("volume", "ls", "--format", "{{.Name}}", "--filter", f"name=^{volume}$")
        if existing:
            raise ValueError("Proposed data volume is already occupied")
        self.docker("volume", "create", "--label", "pond.installation=" + self.state["installation"], volume)

    def check_backup(self, previous):
        source = previous["source"]
        info = self.helper(source["imageID"], source["volume"], "check", previous["backup"])
        if info != previous["snapshot"]:
            raise ValueError("Previous verified snapshot is unavailable")

    def serve(self, descriptor, fenced):
        self.docker("volume", "inspect", descriptor["volume"], "--format", "{{.Name}}")
        self.check_volume_users(descriptor["volume"])
        save(self.folder / "compose.yaml", compose(self.state, descriptor, fenced))
        self.docker(*self.compose_args, "up", "-d", "--no-build", "--pull", "never", "mailbox")

    def admin(self, *args):
        return self.docker(*self.compose_args, "exec", "-T", "mailbox", "python3", "-m", "mailbox.admin", *args)

    def verify(self, state, descriptor, fenced):
        deadline = time.monotonic() + 100
        while True:
            try:
                self.inspect(descriptor)
                report = json.loads(self.admin("status", "--json"))
                check_status(report, state["installation"], descriptor, fenced)
                routed_health(state["url"], state["installation"], fenced)
                break
            except (ValueError, OSError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)
        if fenced:
            return json.loads(self.admin("maintenance", "probe"))
        return report

def folder_path(raw, home):
    if not isinstance(raw, str) or not raw or not re.fullmatch(r"(?:~/|/)?[A-Za-z0-9_./-]+", raw):
        raise ValueError("Use a folder under the SSH user's home, without spaces")
    if any(p in (".", "..") for p in raw.split("/")):
        raise ValueError("Parent and current-directory components are not allowed")
    path = Path(raw[2:]) if raw.startswith("~/") else Path(raw)
    path = home / path
    if home not in path.parents or path.resolve() != path:
        raise ValueError("The Pond folder must be under the SSH home and contain no symbolic links")
    return path


def preflight(folder):
    if folder.exists():
        info = folder.stat()
        if not folder.is_dir() or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("The existing Pond folder must be an owned, private directory")
        if not (folder / "state.json").is_file():
            raise ValueError("The target folder is occupied by an unmanaged installation")
    parent = folder if folder.exists() else folder.parent
    if not parent.is_dir() or shutil.disk_usage(parent).free < 1024 ** 3:
        raise ValueError("The target requires an existing parent and at least 1 GiB of free space")
    engine = Docker(parent, {"installation": "preflight"})
    endpoint = engine.docker("context", "inspect", "--format", "{{.Endpoints.docker.Host}}")
    if not endpoint.startswith("unix://") or os.environ.get("DOCKER_HOST", endpoint) != endpoint:
        raise ValueError("The SSH target needs a local Docker socket")
    compose_version = engine.docker("compose", "version", "--short").lstrip("v")
    if int(compose_version.split(".")[0]) < 2:
        raise ValueError("Docker Compose v2 or later is required")
    machine = engine.docker("version", "--format", "{{.Server.Os}}/{{.Server.Arch}}")
    if machine not in ("linux/arm64", "linux/amd64"):
        raise ValueError("The Docker host must run linux/amd64 or linux/arm64")
    if not folder.exists():
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", 8790))
            except OSError:
                raise ValueError("Loopback port 8790 is occupied") from None
    result = {"platform": machine, "installed": folder.exists()}
    if folder.exists():
        state = read(folder / "state.json")
        result.update(current=state["current"], installation=state["installation"], url=state["url"])
    return result


def prepare_install(folder, request):
    info = preflight(folder)
    if info["installed"]:
        if info["url"] != request["url"]:
            raise ValueError("The existing installation has a different HTTPS origin")
    else:
        descriptor = request["target"]
        if descriptor["platform"] != info["platform"]:
            raise ValueError("Docker platform changed during preflight")
        identifier = uuid.uuid4().hex
        state = {"installation": identifier, "url": request["url"], "installing": True}
        docker = Docker(folder.parent, state)
        state["current"] = dict(descriptor, imageID=docker.pull(descriptor), volume="pond-" + identifier)
        env = "TZ=UTC\nMAILBOX_CONTEXT=personal\n"
        bot = request.get("telegram")
        if bot is not None:
            if (not re.fullmatch("[0-9]+:[A-Za-z0-9_-]{20,}", bot["token"])
                    or not re.fullmatch("[1-9][0-9]*", bot["owner"])):
                raise ValueError("Incomplete Telegram configuration")
            env += "TELEGRAM_BOT_TOKEN=" + bot["token"] + "\nMAILBOX_OWNER_ID=" + bot["owner"] + "\n"
        # Stage all files before the first directory rename. On success
        # each staged directory is nonempty, so a competing rename fails.
        with tempfile.TemporaryDirectory(dir=folder.parent) as staging:
            staged = Path(staging) / "pond"
            staged.mkdir(mode=0o700)
            (staged / "backups").mkdir(mode=0o700)
            atomic(staged / "pond.env", env.encode())
            save(staged / "state.json", state)
            save(staged / "compose.yaml", compose(state, state["current"], False))
            if folder.exists():
                raise ValueError("The target folder was occupied during installation")
            staged.rename(folder)
    with lock(folder):
        state = read(folder / "state.json")
        if state.get("installing"):
            docker = Docker(folder, state)
            descriptor = state["current"]
            volume = descriptor["volume"]
            present = docker.docker("volume", "ls", "--filter", f"name=^{volume}$", "--format", "{{.Name}}")
            if not present:
                if state.get("initialized"):
                    raise ValueError("Previously initialized data volume is missing")
                docker.create_volume(volume)
            owner = docker.docker("volume", "inspect", "--format", '{{index .Labels "pond.installation"}}', volume)
            if owner != state["installation"]:
                raise ValueError("Unexpected owner of the managed data volume")
            data_mount = f"type=volume,source={volume},target=/data"
            backups_mount = f"type=bind,source={folder / 'backups'},target=/backups"
            # A bind directory may belong to a different host UID. Only this
            # newly created installation's backups directory is transferred.
            docker.docker("run", "--rm", "--network", "none", "--user", "0", "--mount", backups_mount,
                          descriptor["imageID"], "chown", "1000:1000", "/backups")
            docker.docker("run", "--rm", "--network", "none", "--mount", data_mount, "--mount", backups_mount,
                          descriptor["imageID"], "python3", "-c",
                          "import tempfile; from pathlib import Path\nfor p in ('/data','/backups'):\n"
                          " with tempfile.TemporaryFile(dir=p) as f: f.write(b'test'); f.flush()")
            if (folder / "pond.env").stat().st_mode & 0o077:
                raise ValueError("Pond configuration must be private")
            if not state.get("initialized"):
                docker.require_idle(volume)
                docker.docker("run", "--rm", "--network", "none", "--mount", data_mount,
                              "-e", "POND_INSTALL_ID=" + state["installation"], descriptor["imageID"],
                              "python3", "-m", "mailbox.admin", "maintenance", "initialize")
                state["initialized"] = True
                save(folder / "state.json", state)
            docker.serve(descriptor, fenced=False)
            docker.verify(state, descriptor, fenced=False)
            state.pop("installing")
            save(folder / "state.json", state)
        return {"installation": state["installation"]}


def public_status(folder, state):
    docker = Docker(folder, state)
    try:
        docker.inspect(state["current"])
        report = json.loads(docker.admin("status", "--json"))
    except (ValueError, OSError, subprocess.SubprocessError):
        report = {"installation": None, "version": {}, "health": {"ok": False},
                  "admission": "unknown", "telegram": None}
    previous = state.get("previous") or {}
    path = folder / "operation.json"
    journal = read(path) if path.exists() else {}
    worker_path = folder / "worker.json"
    worker = worker_status(folder) if worker_path.exists() else {}
    return {"report": report, "current": state["current"], "operation": journal.get("phase"),
            "operationID": journal.get("id"), "worker": worker, "backup": previous.get("backup")}


def worker_status(folder):
    path = folder / "worker.json"
    record = read(path)
    if record.get("state") == "running":
        try:
            # Read-only status. A vanished worker can no longer hold this lock.
            with (folder / "manage.lock").open("rb") as handle:
                fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
                record = read(path)
        except BlockingIOError:
            return record
        except FileNotFoundError:
            pass
        if record.get("state") == "running":
            return dict(record, state="interrupted")
    return record


def detach(folder, runtime, kind, target):
    with lock(folder):
        ident = uuid.uuid4().hex
        path = folder / "worker.json"
        running = {"id": ident, "state": "running"}
        save(path, running)
        pid = os.fork()
        if pid:
            return running
        # Keep the inherited install lock. Detach every SSH stream before work.
        try:
            os.setsid()
            with open(os.devnull, "r+b", buffering=0) as null:
                for fd in (0, 1, 2):
                    os.dup2(null.fileno(), fd)
            try:
                result = operate_locked(folder, runtime, kind, target)
                done = dict(running, state=result["phase"])
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                done = dict(running, state="failed", error=str(exc) if isinstance(exc, ValueError) else "Host operation failed")
            save(path, done)
        finally:
            os._exit(0)


def dispatch(request):
    folder = folder_path(request["folder"], Path.home().resolve())
    action = request["action"]
    if action == "preflight":
        return preflight(folder)
    if action == "install":
        return prepare_install(folder, request)
    if not folder.is_dir() or not (folder / "state.json").is_file():
        raise ValueError("No managed Pond at the configured folder")
    state = read(folder / "state.json")
    if request.get("installation") != state["installation"] or request["url"] != state["url"]:
        raise ValueError("The SSH installation does not match this Mac's saved origin and identity")
    docker = Docker(folder, state)
    if action == "status":
        return public_status(folder, state)
    if action == "pending":
        worker = worker_status(folder) if (folder / "worker.json").exists() else {}
        path = folder / "operation.json"
        pending = path.exists() and read(path)["phase"] not in ("completed", "restored")
        active = worker.get("state") == "running"
        return {"resume": active or pending, "worker": worker if active else None}
    if action == "rollback-info":
        previous = state.get("previous")
        if not previous:
            raise ValueError("No previous verified backup is available")
        return {"backup": previous["backup"], "version": previous["source"]["version"],
                "time": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(previous["time"]))}
    if action == "worker":
        return worker_status(folder)
    if action == "invite":
        with lock(folder):
            docker.identify(state)
            return {"link": docker.admin("admission", "invite", "--first")}
    if action in ("update", "rollback", "resume"):
        return detach(folder, docker, action, request.get("target"))
    raise ValueError("Unknown Pond management action")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        payload = json.load(sys.stdin)
        COMPOSE_TEMPLATE = payload.pop("template")
        result = {"result": dispatch(payload)}
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as exc:
        result = {"error": str(exc) if isinstance(exc, ValueError) else "Pond host operation failed"}
    print(json.dumps(result))
