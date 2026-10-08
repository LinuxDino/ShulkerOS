"""Boot the real Sedna Linux (kernel + rootfs from the sedna-buildroot jar) in QEMU and drive its console.

    from vm import Sedna
    with Sedna(rootfs="work/rootfs.ext2", kernel="work/Image", builtin="work/builtin") as vm:
        print(vm.run("uname -a"))

QEMU's user network stands in for the OC2 Internet Gateway: guest 10.0.2.15/24, gateway 10.0.2.2
(which is the host's loopback), name server 10.0.2.3. There is no DHCP on a real gateway, so tests
configure eth0 statically the way a player would.
"""
import os
import re
import shutil
import pexpect

PROMPT = "__SHULKER_TEST__# "


class Sedna:
    def __init__(self, rootfs, kernel, builtin=None, memory=64, copy=True, log=None, hostfwd=None, lan=None, mac=None):
        """lan: a multicast group like "230.0.0.1:1234": VMs on the same group share one Ethernet segment
        (like OC2 computers cabled to one hub); mac: this VM's MAC address on it."""
        self.lan, self.mac = lan, mac
        self.rootfs, self.kernel, self.builtin = rootfs, kernel, builtin
        self.memory, self.copy, self.log, self.hostfwd = memory, copy, log, hostfwd
        self.child = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()

    def start(self, login=True):
        disk = self.rootfs
        if self.copy:
            disk = self.rootfs + "." + (self.mac or "x").replace(":", "") + ".run"
            shutil.copyfile(self.rootfs, disk)
        net = "user,id=n0"
        if self.hostfwd:
            net += "," + self.hostfwd
        if self.lan:
            net = "socket,id=n0,mcast=" + self.lan
        args = ["-M", "virt", "-m", str(self.memory), "-nographic", "-monitor", "none",
                "-kernel", self.kernel, "-append", "root=/dev/vda rw console=ttyS0",
                "-drive", f"file={disk},format=raw,if=none,id=hd0", "-device", "virtio-blk-device,drive=hd0",
                "-netdev", net, "-device", "virtio-net-device,netdev=n0" + (",mac=" + self.mac if self.mac else "")]
        if self.builtin:
            args += ["-fsdev", f"local,id=fs0,path={os.path.abspath(self.builtin)},security_model=none,readonly=on",
                     "-device", "virtio-9p-device,fsdev=fs0,mount_tag=builtin"]
        logf = open(self.log, "w") if self.log else None
        self.child = pexpect.spawn("qemu-system-riscv64", args, encoding="utf-8", timeout=120,
                                   codec_errors="replace", dimensions=(24, 200))
        if logf:
            self.child.logfile_read = logf
        if login:
            self.login()
        return self

    def login(self):
        self.child.expect(r"(?m)^\r*[\w-]+ login: ", timeout=180)
        self.child.sendline("root")
        self.child.expect([r"# ", r"\$ "], timeout=60)
        self.raw_shell()

    def raw_shell(self):
        # a fixed, unmistakable prompt; no echo so output is exactly what the command printed
        self.child.sendline(f"stty -echo; export PS1='{PROMPT}'")
        self.child.expect_exact(PROMPT, timeout=60)

    def run(self, cmd, timeout=120, check=False):
        """Run one shell command, return (exit code, output)."""
        self.child.sendline(cmd + "; echo __RC=$?")
        self.child.expect(r"__RC=(\d+)\r*\n", timeout=timeout)
        out = self.child.before
        rc = int(self.child.match.group(1))
        self.child.expect_exact(PROMPT, timeout=30)
        out = out.replace("\r", "")
        if check and rc != 0:
            raise RuntimeError(f"{cmd!r} failed ({rc}):\n{out}")
        return rc, out

    def start_cmd(self, cmd):
        """Start a command whose prompts the test answers with expect()/send(); finish with wait_rc()."""
        self.child.sendline(cmd + "; echo __RC=$?")

    def expect(self, pattern, timeout=120):
        self.child.expect(pattern, timeout=timeout)
        return self.child.before.replace("\r", "")

    def send(self, line):
        self.child.sendline(line)

    def wait_rc(self, timeout=120):
        self.child.expect(r"__RC=(\d+)\r*\n", timeout=timeout)
        out = self.child.before.replace("\r", "")
        rc = int(self.child.match.group(1))
        self.child.expect_exact(PROMPT, timeout=30)
        return rc, out

    def sh(self, cmd, timeout=120):
        return self.run(cmd, timeout=timeout, check=True)[1]

    def put(self, path, data, mode=None):
        """Write a (small) file in the guest through the console, base64 encoded."""
        import base64
        b = base64.b64encode(data if isinstance(data, bytes) else data.encode()).decode()
        self.sh(f": > {path}.b64")
        for i in range(0, len(b), 512):
            self.sh(f"printf %s '{b[i:i+512]}' >> {path}.b64")
        self.sh(f"base64 -d {path}.b64 > {path} && rm {path}.b64")
        if mode:
            self.sh(f"chmod {mode} {path}")

    def stop(self):
        if self.child and self.child.isalive():
            try:
                self.child.sendline("sync; poweroff -f")
                self.child.expect(pexpect.EOF, timeout=20)
            except Exception:
                self.child.terminate(force=True)
        self.child = None
