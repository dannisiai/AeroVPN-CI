"""AeroVPN - Android libbox.aar real builder (upstream SagerNet/sing-box).

Builds the *real* libbox AAR from the pinned upstream release, mirroring upstream's
own recipe (Makefile: lib_install / lib_android, cmd/internal/build_libbox -target
android). Placeholder stubs (hand-written classes, no native .so) are never produced:
without a Go toolchain this script fails instead of faking an artifact.

Version, build tags and the gomobile fork live in core/upstream.env (single source of
truth) - edit that file, not this script.

GPL-3.0: building from SagerNet/sing-box source preserves the license; do NOT check in
fake binaries to silence Gradle errors.
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
    android_api = env.get("ANDROID_API_LEVEL", "21")

    upstream_dir = os.path.join(ROOT_DIR, "core", "upstream", "sing-box")
    libs_dir = os.path.join(ROOT_DIR, "client", "android", "app", "libs")
    os.makedirs(libs_dir, exist_ok=True)
    aar_path = os.path.join(libs_dir, "libbox.aar")

    if os.path.exists(aar_path):
        print(f"Existing libbox.aar: {os.path.getsize(aar_path)} bytes (will be replaced)")

    if shutil.which("go") is None:
        print("ERROR: Go toolchain not found (need >= 1.26.1). Install Go, then rerun.", file=sys.stderr)
        print("Refusing to generate a fake stub: it compiles but can never start a tunnel.", file=sys.stderr)
        sys.exit(2)

    gomobile_bin, build_env = install_gomobile(env, ROOT_DIR)
    if not os.environ.get("ANDROID_HOME"):
        print("ERROR: ANDROID_HOME is not set; gomobile bind for Android needs the Android SDK.",
              file=sys.stderr)
        sys.exit(2)
    if not (os.environ.get("ANDROID_NDK_HOME") or os.environ.get("NDK")):
        print(f"ERROR: ANDROID_NDK_HOME is not set; libbox needs NDK {env.get('ANDROID_NDK_VERSION')}.",
              file=sys.stderr)
        sys.exit(2)

    prepare_upstream(env, upstream_dir)
    print(f"Building libbox.aar {upstream_tag} via gomobile (tags: {build_tags}) ...")
    print("This takes several minutes.")
    run([
        gomobile_bin, "bind",
        "-target=android",
        "-androidapi", android_api,
        "-javapkg=io.nekohasekai",
        "-libname=box",
        f"-tags={build_tags}",
        "-trimpath", "-buildvcs=false",
        f"-ldflags={env.get('UPSTREAM_LDFLAGS', '-s -w -checklinkname=0')}",
        "-o", aar_path,
        "./experimental/libbox",
    ], cwd=upstream_dir, env=build_env)

    if os.environ.get("AEROVPN_PACKAGE_ONLY") != "1":
        run([sys.executable, os.path.join(SCRIPT_DIR, "verify_upstream_artifact.py"), "--aar", aar_path])

    # Remove the legacy placeholder classes.jar (fake 5KB stub) if it is still around:
    # it duplicates io.nekohasekai.libbox.* and would shadow the real core.
    jar_path = os.path.join(libs_dir, "classes.jar")
    if os.path.exists(jar_path) and os.path.getsize(jar_path) < 100_000:
        print(f"Removing legacy placeholder {jar_path} ({os.path.getsize(jar_path)} bytes).")
        try:
            os.remove(jar_path)
        except OSError:
            pass

    print(f"Successfully built libbox.aar ({os.path.getsize(aar_path)} bytes) at {aar_path}")


if __name__ == "__main__":
    main()
