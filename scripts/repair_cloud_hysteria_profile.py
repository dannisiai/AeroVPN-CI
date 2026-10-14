"""Apply the deployed Hysteria parameters to the existing cloud API.

Run on the authorized server as: python3 script.py NODE_IP CERTIFICATE_DNS_NAME
This performs file updates and service activation only, with no probes or tests.
"""

import datetime
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import tempfile


def scalar(value):
    value = value.strip()
    if value.startswith('"'):
        return json.loads(value)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value.split(" #", 1)[0].strip()


def atomic_write(path, data, uid=0, gid=0, mode=0o600):
    fd, temp = tempfile.mkstemp(prefix=".aerovpn-update-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temp, uid, gid)
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    host, certificate_name = sys.argv[1:3]
    api = Path("/root/VPN/api/server.js")
    profile = api.with_name("node-config.json")
    sections, section = {}, ""
    for line in Path("/etc/hysteria/config-salamander.yaml").read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^(\s*)([A-Za-z_]+):\s*(.*)$", line)
        if not match:
            continue
        indent, name, value = match.groups()
        if not indent:
            section = name
            sections[name] = scalar(value) if value else {}
        elif isinstance(sections.get(section), dict):
            sections[section][name] = scalar(value)

    node = {
        "server": host,
        "server_port": int(str(sections["listen"]).rsplit(":", 1)[1]),
        "password": sections["auth"]["password"],
        "tls": {"enabled": True, "server_name": certificate_name},
        "obfs": {"type": sections["obfs"]["type"],
                 "password": sections["obfs"]["password"]},
    }
    original = api.read_text()
    replacement = '''      const nodeSpec = JSON.parse(
        require("fs").readFileSync(__dirname + "/node-config.json", "utf8")
      );
      // Retain both API shapes for installed clients during upgrades.
      nodeSpec.tls = { ...nodeSpec.tls, obfs: nodeSpec.obfs };'''
    updated, count = re.subn(r"(?m)^      const nodeSpec = \{[\s\S]*?^      \};",
                            replacement, original, count=1)
    if count != 1:
        raise RuntimeError("The expected legacy nodeSpec block was not found; no files changed")

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = api.with_name("server.js.before-node-repair-" + stamp)
    shutil.copy2(api, backup)
    backup.chmod(0o600)
    if profile.exists():
        old_profile = profile.with_name("node-config.json.before-" + stamp)
        shutil.copy2(profile, old_profile)
        old_profile.chmod(0o600)
    unit = Path("/etc/systemd/system/aerovpn-api.service").read_text()
    user = re.search(r"(?m)^User=(\S+)", unit)
    account = pwd.getpwnam(user.group(1) if user else "root")
    atomic_write(profile, (json.dumps(node, indent=2) + "\n").encode(),
                 account.pw_uid, account.pw_gid)
    info = api.stat()
    atomic_write(api, updated.encode(), info.st_uid, info.st_gid, info.st_mode & 0o777)
    try:
        # start is idempotent and does not interrupt an already-running node.
        subprocess.run(["systemctl", "start", "hysteria-salamander"], check=True)
        subprocess.run(["systemctl", "restart", "aerovpn-api"], check=True)
    except subprocess.CalledProcessError:
        shutil.copy2(backup, api)
        subprocess.run(["systemctl", "restart", "aerovpn-api"], check=False)
        raise
    print("Cloud API node profile updated; existing node service enabled and API restarted.")
    print("API backup:", backup)


if __name__ == "__main__":
    main()
