"""Verify the exact reviewed libbox source and install its pinned gomobile fork."""
import os
import subprocess
from pathlib import Path


def prepare_upstream(settings, source_dir):
    source = Path(source_dir)
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.check_call([
            "git", "clone", "--depth", "1", "--branch", settings["UPSTREAM_VERSION"],
            settings["UPSTREAM_REPO"], str(source),
        ])
    expected = settings["UPSTREAM_COMMIT"]
    for ref in ("HEAD", settings["UPSTREAM_VERSION"] + "^{commit}"):
        actual = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", ref], text=True).strip()
        if actual != expected:
            raise RuntimeError(f"Refusing unreviewed upstream {ref}: {actual}, expected {expected}")
    changes = subprocess.check_output(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=normal"],
        text=True).strip()
    if changes:
        raise RuntimeError("Refusing modified upstream source; use a clean pinned checkout")
    if not (source / "experimental" / "libbox").is_dir():
        raise RuntimeError("Pinned checkout is missing experimental/libbox")


def install_gomobile(settings, root_dir):
    version = settings["GOMOBILE_VERSION"]
    tools = Path(root_dir) / "core" / "upstream" / "tools" / ("gomobile-" + version)
    tools.mkdir(parents=True, exist_ok=True)
    build_env = os.environ.copy()
    build_env["GOBIN"] = str(tools)
    build_env["PATH"] = str(tools) + os.pathsep + build_env.get("PATH", "")
    for name in ("gomobile", "gobind"):
        subprocess.check_call([
            "go", "install", f"github.com/sagernet/gomobile/cmd/{name}@{version}",
        ], env=build_env)
        binary = tools / (name + (".exe" if os.name == "nt" else ""))
        if os.environ.get("AEROVPN_PACKAGE_ONLY") != "1":
            metadata = subprocess.check_output(["go", "version", "-m", str(binary)], text=True)
            modules = [line.split() for line in metadata.splitlines()]
            if ["mod", "github.com/sagernet/gomobile", version] not in [row[:3] for row in modules]:
                raise RuntimeError(f"Wrong gomobile fork/version in {binary}")
    return str(tools / ("gomobile.exe" if os.name == "nt" else "gomobile")), build_env
