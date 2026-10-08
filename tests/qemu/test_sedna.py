#!/usr/bin/env python3
"""End-to-end test of Shulker OS on the real Sedna Linux, booted in QEMU.

    python3 tests/qemu/test_sedna.py --sedna work/sedna --builtin work/builtin-stock [--mode install|datapack]

--sedna    a directory with rootfs.ext2 and Image (tools/fetch-sedna.sh makes one)
--builtin  what to mount at /mnt/builtin: OC2's scripts (src/main/scripts of the mod), and for
           --mode datapack also the Shulker OS layer (tools/build-datapack.sh --layer-dir)

The mock API (tests/mock_api.py) must run on the host at port 8443 with --files pointing at a
directory where "dev" links to this repository; the guest reaches the host as 10.0.2.2.
install mode:  the one-line installer on a stock Sedna, then everything, then a reboot
datapack mode: Shulker OS from /mnt/builtin (nothing installed on the disk)
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from vm import Sedna  # noqa: E402

FAILS = []
ANSI = re.compile(r"\x1b(\[[0-9;?]*[A-Za-z]|\([0B])")


def check(cond, what, out=""):
    print(("  ok    " if cond else "  FAIL  ") + what, flush=True)
    if not cond:
        FAILS.append(what)
        if out:
            print("        " + out.strip().replace("\n", "\n        ")[:2000])


def plain(s):
    return ANSI.sub("", s)


def network(vm):
    # the real gateway has no DHCP: configure it like a player would, with netcfg
    rc, out = vm.run("netcfg static 10.0.2.15/24 10.0.2.2 10.0.2.3")
    check(rc == 0 and "eth0 is up" in plain(out), "netcfg static brings eth0 up", out)


def common(vm, mode):
    rc, out = vm.run("shulker version")
    check(rc == 0 and "Shulker OS" in out, "shulker version", out)
    check(("data pack" in out) == (mode == "datapack"), "runs from the expected place (%s)" % mode, out)

    rc, out = vm.run("shulkerfetch")
    check(rc == 0 and "Kernel" in plain(out) and "riscv64" in plain(out), "shulkerfetch", out)
    check("lqqqqqqqqqk" in out, "shulkerfetch draws the logo with DEC graphics", out)

    rc, out = vm.run("man -l")
    for page in ("intro", "claude", "task", "shulker", "shulkerfetch", "man", "netcfg", "sshctl", "oc2"):
        check(page in out, "man page " + page, out if page == "intro" else "")
    rc, out = vm.run("man claude | head -n 5")
    check("SYNOPSIS" in plain(out), "man claude renders", out)

    rc, out = vm.run("sh -lc 'echo \"$PS1\"'")
    check("\\033[35m" in out or "\x1b[35m" in out, "purple shulker prompt in PS1", out)

    # tasks
    vm.sh("task add -p high Build the reactor +base")
    vm.sh("task add Craft 64 cables @nether")
    rc, out = vm.run("task list")
    check("Build the reactor" in out and "Craft 64 cables" in out, "task add / list", out)
    vm.sh("task done 2")
    rc, out = vm.run("cat ~/.shulker/tasks.txt")
    check(re.search(r"^\(A\) \d{4}-\d\d-\d\d Build the reactor \+base$", out, re.M) is not None, "todo.txt priority line", out)
    check(re.search(r"^x \d{4}-\d\d-\d\d \d{4}-\d\d-\d\d Craft 64 cables @nether$", out, re.M) is not None, "todo.txt done line", out)

    # netcfg status + test (gateway ping works with QEMU's user network)
    rc, out = vm.run("netcfg")
    check("10.0.2.15" in out and "10.0.2.2" in out, "netcfg status", out)

    # claude against the mock API
    env = "SHULKER_API_URL=https://10.0.2.2:8443/v1/messages ANTHROPIC_API_KEY=sk-ant-test-0000"
    rc, out = vm.run(env + " claude -p 'hello shulker'", timeout=180)
    check(rc == 0 and "Hello from mock: hello shulker" in out, "claude -p (mock API over TLS)", out)
    rc, out = vm.run(env + " claude -p 'TOOL task_list {}'", timeout=180)
    check("Build the reactor" in out, "Claude reads the task list", out)
    rc, out = vm.run(env + " claude -p 'TOOL system_info {}'", timeout=180)
    check("Shulker OS" in out and "crond: running" in out, "Claude system_info sees crond running", out)
    rc, out = vm.run(env + " claude -p 'TOOL network_info {}'", timeout=180)
    check("10.0.2.15" in out, "Claude network_info", out)
    rc, out = vm.run(env + " claude -p 'TOOL run_command {\"command\":\"echo from-claude > /tmp/claude-made\"}' </dev/null 2>&1 | cat", timeout=180)
    rc2, out2 = vm.run("cat /tmp/claude-made 2>&1")
    check("from-claude" not in out2, "risky tool refused without a terminal", out + out2)
    rc, out = vm.run(env + " claude -p 'TOOL run_command {\"command\":\"echo from-claude > /tmp/claude-made\"}' --allow run_command </dev/null 2>&1 | cat", timeout=180)
    rc2, out2 = vm.run("cat /tmp/claude-made")
    check("from-claude" in out2, "--allow run_command lets it run", out + out2)

    # interactive approval: deny, then always
    vm.start_cmd(env + " claude -p 'TOOL write_file {\"path\":\"/root/note.txt\",\"content\":\"hi\"}'")
    vm.expect(r"Allow\?.*: ", timeout=180)
    vm.send("n")
    rc, out = vm.wait_rc(timeout=180)
    check("denied" in out and not vm.run("ls /root/note.txt")[0] == 0, "approval prompt: deny", out)

    # interactive REPL with /commands
    vm.start_cmd(env + " claude")
    out = vm.expect(r"Type yes to continue: ", timeout=60)
    check("does not verify certificates" in out, "first run shows the TLS warning", out)
    vm.send("yes")
    out = vm.expect(r"you.*> ", timeout=60)
    check("Claude" in plain(out), "REPL banner", out)
    vm.send("/effort low")
    vm.expect(r"you.*> ")
    vm.send("TOOL run_command {\"command\":\"echo repl-ran\"}")
    vm.expect(r"Allow\?.*: ", timeout=180)
    vm.send("a")
    out = vm.expect(r"you.*> ", timeout=180)
    check("repl-ran" in out, "REPL tool use with [a]lways", out)
    vm.send("/cost")
    out = vm.expect(r"you.*> ")
    check("requests" in out and "$" in out, "/cost", out)
    vm.send("/exit")
    rc, out = vm.wait_rc()
    check(rc == 0, "REPL /exit")
    rc, out = vm.run("claude config effort")
    check(out.strip().endswith("low"), "config persisted from /effort", out)

    # scheduled jobs through crond
    rc, out = vm.run("task job add 'every 1m' shell 'echo tick-$(date +%s)' --name ticker")
    check(rc == 0 and "scheduled j1" in plain(out), "task job add", out)
    rc, out = vm.run("cat /etc/shulker/crontabs/root")
    check("shulker-job run j1" in out, "crontab written", out)
    rc, out = vm.run(env + " claude -p 'TOOL job_list {}'", timeout=180)
    check("ticker" in out, "Claude lists jobs", out)
    print("  ..    waiting up to 130 s for crond", flush=True)
    seen = False
    for _ in range(26):
        time.sleep(5)
        rc, out = vm.run("cat ~/.shulker/jobs/j1.log 2>/dev/null")
        if "tick-" in out:
            seen = True
            break
    check(seen, "crond ran the job and logged its output", vm.run("cat /tmp/crond.log; ps")[1])
    rc, out = vm.run("task job log j1")
    check("exit 0" in out, "task job log", out)
    return env


def install_mode(args):
    with Sedna(args.rootfs, args.kernel, builtin=args.builtin, log=args.log) as vm:
        vm.sh("ip addr add 10.0.2.15/24 dev eth0; ip link set eth0 up; ip route add default via 10.0.2.2")
        rc, df_before = vm.run("df -k / | tail -n 1")
        rc, out = vm.run("wget -qO- https://10.0.2.2:8443/files/dev/install.sh | "
                         "SHULKER_REPO=https://10.0.2.2:8443/files SHULKER_BRANCH=dev sh", timeout=600)
        check(rc == 0 and "is installed" in plain(out), "one-line installer", out)
        rc, df_after = vm.run("df -k / | tail -n 1")
        used = int(df_after.split()[2]) - int(df_before.split()[2])
        print("  ..    installer used %d KB of the root disk" % used)
        check(used < 400, "install is small (%d KB)" % used)
        vm.send("exec sh -l")     # a login shell picks up /etc/profile.d/shulker.sh
        vm.raw_shell()
        network(vm)
        env = common(vm, "install")

        rc, out = vm.run("SHULKER_REPO=https://10.0.2.2:8443/files SHULKER_BRANCH=dev shulker list", timeout=120)
        check("snake" in out and "cowsay" in out, "shulker list", out)
        rc, out = vm.run("SHULKER_REPO=https://10.0.2.2:8443/files SHULKER_BRANCH=dev shulker install cowsay fortune", timeout=300)
        check(rc == 0 and "installed" in out, "shulker install", out)
        rc, out = vm.run("fortune | cowsay -f shulker")
        check(rc == 0 and "#########" in out, "installed apps run from PATH", out)
        rc, out = vm.run("man cowsay")
        check("talking cow" in out, "package man page", out)
        rc, out = vm.run("SHULKER_REPO=https://10.0.2.2:8443/files SHULKER_BRANCH=dev shulker update --check", timeout=300)
        check("up to date" in out, "shulker update --check", out)
        vm.sh("echo corrupted > /opt/shulker/share/motd")
        rc, out = vm.run("SHULKER_REPO=https://10.0.2.2:8443/files SHULKER_BRANCH=dev shulker update", timeout=300)
        check(rc == 0 and "Updated" in out, "shulker update repairs a changed file", out)
        check("corrupted" not in vm.run("cat /opt/shulker/share/motd")[1], "file restored by update")
        rc, out = vm.run("SHULKER_REPO=https://10.0.2.2:8443/files SHULKER_BRANCH=dev shulker remove fortune", timeout=60)
        check(rc == 0 and vm.run("ls /usr/local/bin/fortune")[0] != 0, "shulker remove", out)
        rc, out = vm.run("ls -l ~/.shulker/claude/ 2>&1; " + env + " claude key --forget >/dev/null; echo done")

        vm.sh("sync")
        vm.stop()
        # second boot on the same disk: everything must still be there
        vm.copy = False
        vm.rootfs = args.rootfs + ".run"
        vm.start(login=False)
        out = vm.expect(r"(?m)^\r*[\w-]+ login: ", timeout=180)
        check("Shulker OS" in plain(out), "boot banner and /etc/issue are branded", out[-1500:])
        vm.send("root")
        out = vm.expect([r"# ", r"\$ "], timeout=60)
        check("Welcome to Shulker OS" in out, "motd after login", out)
        vm.raw_shell()
        rc, out = vm.run("pidof crond && cat /etc/shulker/crontabs/root | grep -c shulker-job")
        check(rc == 0, "crond started at boot with the saved jobs", out)
        rc, out = vm.run("ip -4 addr show eth0")
        check("10.0.2.15" in out, "netcfg setup survived the reboot", out)
        rc, out = vm.run("task list all")
        check("Build the reactor" in out, "tasks survived the reboot", out)
        rc, out = vm.run("cowsay -f shulker moo")
        check(rc == 0, "packages survived the reboot", out)


def datapack_mode(args):
    with Sedna(args.rootfs, args.kernel, builtin=args.builtin, log=args.log) as vm:
        rc, df_before = vm.run("df -k / | tail -n 1")
        vm.send("exec sh -l")
        vm.raw_shell()
        rc, out = vm.run("command -v claude task shulker")
        check(rc == 0 and "/mnt/builtin/bin/claude" in out, "commands on the PATH from the data pack layer", out)
        network(vm)
        common(vm, "datapack")
        rc, out = vm.run("shulker update")
        check(rc != 0 and "data pack" in out, "update refuses on the read-only data pack", out)
        rc, df_after = vm.run("df -k / | tail -n 1")
        used = int(df_after.split()[2]) - int(df_before.split()[2])
        print("  ..    data pack mode used %d KB of the root disk" % used)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sedna", default="work/sedna")
    ap.add_argument("--builtin", required=True)
    ap.add_argument("--mode", choices=["install", "datapack"], default="install")
    ap.add_argument("--log")
    args = ap.parse_args()
    args.rootfs = os.path.join(args.sedna, "rootfs.ext2")
    args.kernel = os.path.join(args.sedna, "Image")
    print("Shulker OS on Sedna (QEMU), %s mode" % args.mode, flush=True)
    (install_mode if args.mode == "install" else datapack_mode)(args)
    print("\n%d failure(s)" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
