#!/usr/bin/env python3
"""python3 tests/test_packages.py -- what is chosen in the installer is what gets installed, now or
at the first start: the package part of lib/apply.sh, run with stand-ins for pacman and the net"""
import os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LISTS = pathlib.Path(os.environ.get("AEQUALYN_LISTS", ROOT.parent / "aequalyn-pkgs/lists"))
SRC = (ROOT / "lib/apply.sh").read_text()
PART = SRC[SRC.index("# ---------------------------------------------------------- package source"):SRC.index('ok "packages to install')]
fails = n = 0


def ok(cond, what):
    global fails, n
    n += 1
    if not cond:
        fails += 1
        print("FAIL", what)


def names(f):
    return [l.split("#")[0].strip() for l in f.read_text().splitlines() if l.split("#")[0].strip()]


OFFLINE = [p for f in ("base", "desktop", "offline-extra", "profiles/minimal") for p in names(LISTS / f"{f}.packages")]


def run(profiles, source="auto", net=True, browser="chromium", gpu="mesa vulkan-radeon", repo=True, unknown=(), extra=""):
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        (t / "repo").mkdir(); (t / "bin").mkdir(); (t / "aq/installer").mkdir(parents=True)
        if repo:
            (t / "repo/offline.db").write_text("")
            for p in OFFLINE + ["nano"]:
                (t / f"repo/{p}-1.0-1-x86_64.pkg.tar.zst").write_text("")
        (t / "aq/packages").symlink_to(LISTS)
        (t / "aq/installer/aequalyn-detect").write_text(f"printf 'UCODE=amd-ucode\\nGPU_PKGS=%q\\nBATTERY=no\\n' '{gpu}'\n")
        stub = {"ping": f"exit {0 if net else 1}", "pacman-key": "exit 0",
                "pacman": f'[ {1 if net else 0} = 1 ] || exit 1\ncase "$1" in -Sp) case " {" ".join(unknown)} " in *" $4 "*) exit 1;; esac;; esac\nexit 0'}
        for k, v in stub.items():
            (t / "bin" / k).write_text("#!/bin/bash\n" + v + "\n")
            (t / "bin" / k).chmod(0o755)
        part = PART.replace("/var/cache/offline-repo", str(t / "repo")).replace("/tmp/aequalyn-pacman", str(t / "pacman"))
        script = f'''set -Eeuo pipefail
info() {{ :; }}; ok() {{ :; }}; warn() {{ echo "WARN $*" >&2; }}; abort() {{ echo "ABORT $*"; exit 9; }}
AEQUALYN_ROOT={t}/aq; SOURCE={source}; PROFILES="{profiles}"; BROWSER={browser}; FLATPAK=false; EXTRA="{extra}"; EDITOR=nano
{part}
echo "OFFLINE=$OFFLINE"; echo "PKGS=${{PKGS[*]}}"; echo "LATER=${{LATER[*]:-}}"
'''
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=dict(os.environ, PATH=f"{t}/bin:/usr/bin"))
        out = dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l and not l.startswith("ABORT"))
        return r.returncode, out.get("OFFLINE"), set(out.get("PKGS", "").split()), set(out.get("LATER", "").split()), r.stdout + r.stderr


base = set(names(LISTS / "base.packages"))
for prof in ("casual", "dev", "creative", "gaming", "student", "work", "ai"):
    want = set(names(LISTS / f"profiles/{prof}.packages"))
    rc, off, pk, later, o = run(f"minimal {prof}")
    ok(rc == 0 and off == "0" and want <= pk and not later, f"{prof}, automatic, with internet: all of it is installed {want - pk} {o[-200:]}")
    ok(base <= pk, f"{prof}: on top of the base system")
    rc, off, pk, later, o = run(f"minimal {prof}", net=False)
    ok(rc == 0 and off == "1" and want <= pk | later and want & later, f"{prof}, without internet: what the ISO lacks comes later {want - pk - later} {o[-200:]}")
    ok(not pk & later, f"{prof}: nothing twice")
    rc, off, pk, later, o = run(f"minimal {prof}", source="offline")
    ok(rc == 0 and off == "1" and want <= pk | later, f"{prof}, offline: later too")
    rc, off, pk, later, o = run(f"minimal {prof}", source="online")
    ok(rc == 0 and off == "0" and want <= pk and not later, f"{prof}, online: all of it")
rc, off, pk, later, o = run("minimal casual dev creative gaming student work ai")
ok(all(set(names(LISTS / f"profiles/{p}.packages")) <= pk for p in ("casual", "dev", "creative", "gaming", "student", "work", "ai")), "all of them together")
rc, off, pk, later, o = run("minimal")
ok(off == "1" and not later, f"the base system alone stays offline, and fast {later}")
rc, off, pk, later, o = run("minimal", browser="firefox")
ok("firefox" in pk and "chromium" not in pk, "Firefox instead of Chromium")
for gpu, lib in (("mesa vulkan-radeon", "lib32-vulkan-radeon"), ("mesa vulkan-intel", "lib32-vulkan-intel"), ("nvidia-open nvidia-utils", "lib32-nvidia-utils")):
    rc, off, pk, later, o = run("minimal gaming", gpu=gpu)
    ok(lib in pk and "lib32-mesa" in pk, f"games get this card's 32-bit driver: {lib}")
    ok(len({"lib32-vulkan-radeon", "lib32-vulkan-intel", "lib32-nvidia-utils"} & pk) == 1, "and only this card's")
rc, off, pk, later, o = run("minimal creative", unknown=("krita",))
ok(rc == 0 and "krita" not in pk and "krita" in later and "gimp" in pk, "a name the mirrors do not know does not end the install")
ok(run("minimal nonsense")[0] == 0, "nor does an unknown profile")
ok(run("minimal dev", repo=False, net=False)[0] == 9, "with neither internet nor the ISO's packages it stops, and says so")
ok("PACKAGES_SEED_WEBAPPS" in SRC, "seed_webapps is read as install.toml writes it")
print(f"packages: {n} checks, {fails} failures")
sys.exit(1 if fails else 0)
