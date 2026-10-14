"""AeroVPN - Apple Libbox.xcframework real builder (upstream SagerNet/sing-box).

Builds the *real* Apple framework from the pinned upstream release, mirroring upstream's
own recipe (Makefile: lib_install / lib_apple, cmd/internal/build_libbox -target apple).
Placeholder Mach-O stubs (a few hundred bytes, no Go runtime) are never produced: without
Go + Xcode this script fails instead of faking an artifact.

Version, build tags and the gomobile fork live in core/upstream.env (single source of
truth) - edit that file, not this script.

GPL-3.0: building from SagerNet/sing-box source preserves the license.
"""
import os
import shutil
import subprocess
import sys
from upstream_build import prepare_upstream, install_gomobile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))


def load_upstream_env(path=None):
    """Parse core/upstream.env into a dict of shell-style KEY="value" pairs."""
    env_path = path or os.path.join(ROOT_DIR, "core", "upstream.env")
    values = {}
    with open(env_path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def run(cmd, cwd=None, env=None):
    print(f"$ {' '.join(cmd)}")
    subprocess.check_call(cmd, cwd=cwd, env=env)


def main():
    env = load_upstream_env()
    upstream_tag = env["UPSTREAM_VERSION"]
    build_tags = env["UPSTREAM_BUILD_TAGS"]

    upstream_dir = os.path.join(ROOT_DIR, "core", "upstream", "sing-box")
    out_dir = os.path.join(ROOT_DIR, "client", "ios", "Frameworks", "Libbox.xcframework")

    for probe in [
        os.path.join(out_dir, "ios-arm64", "Libbox.framework", "Libbox"),
        os.path.join(out_dir, "ios-arm64_x86_64-simulator", "Libbox.framework", "Libbox"),
    ]:
        if os.path.exists(probe):
            print(f"Existing {probe}: {os.path.getsize(probe)} bytes (will be replaced)")

    if shutil.which("go") is None:
        print("ERROR: Go toolchain not found (need >= 1.26.1). Install Go + Xcode, then rerun.",
              file=sys.stderr)
        print("Refusing to generate a fake Mach-O stub: it can never start a tunnel.",
              file=sys.stderr)
        sys.exit(2)

    gomobile_bin, build_env = install_gomobile(env, ROOT_DIR)
    prepare_upstream(env, upstream_dir)
    print(f"Building Libbox.xcframework {upstream_tag} via gomobile (tags: {build_tags}) ...")
    print("This takes several minutes.")
    # gomobile merges into an existing xcframework directory, so a stale slice from an
    # earlier build (e.g. the simulator slice we deliberately no longer ship) would
    # survive and get committed. Start from a clean directory.
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    # Device slice only. The simulator slice is ~142 MB, over GitHub's 100 MB per-file
    # limit (device slice is ~73 MB), and the macOS slice is unused (the desktop build
    # runs the standalone sing-box binary). Rebuild with -target=ios,iossimulator
    # locally when a simulator framework is needed.
    run([
        gomobile_bin, "bind",
        "-target=ios",
        "-libname=box",
        "-iosversion=15.0",
        f"-tags={build_tags}",
        "-trimpath", "-buildvcs=false",
        f"-ldflags={env.get('UPSTREAM_LDFLAGS', '-s -w -checklinkname=0')}",
        "-o", out_dir,
        "./experimental/libbox",
    ], cwd=upstream_dir, env=build_env)

    if os.environ.get("AEROVPN_PACKAGE_ONLY") != "1":
        run([sys.executable, os.path.join(SCRIPT_DIR, "verify_upstream_artifact.py"),
             "--xcframework", out_dir])

    print(f"Successfully built Libbox.xcframework at {out_dir}")


if __name__ == "__main__":
    main()
