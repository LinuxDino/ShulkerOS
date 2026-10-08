#!/usr/bin/env python3
"""A drone base on real Sedna VMs: main -- base == drone, where the base's network card to the main is NOT
its first interface (an OC2 computer with the tunnel card in an earlier slot). The drone must still get an
address from the base and join the main through the base's relay.

    python3 tests/qemu/test_dronebase.py [--sedna work/sedna] [--images dist/build/pack/data/shulkeros/block_devices/hdd]
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
            print("        " + ANSI.sub("", out).strip().replace("\n", "\n        ")[:2500])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sedna", default="work/sedna")
    ap.add_argument("--images", default="dist/build/pack/data/shulkeros/block_devices/hdd")
    ap.add_argument("--logdir", default="work")
    a = ap.parse_args()
    kernel = os.path.join(a.sedna, "Image")
    pid = os.getpid()
    swarm_lan = "230.0.1.%d:%d" % (1 + pid % 200, 21000 + pid % 9000)
    tunnel = "230.0.2.%d:%d" % (1 + pid % 200, 31000 + pid % 9000)
    vms = []
    print("Drone base: main -- base (uplink on its 2nd interface) == drone", flush=True)
    try:
        m = Sedna(os.path.join(a.images, "shulkeros.bin"), kernel, lan=swarm_lan, mac="52:54:00:00:10:01",
                  log=os.path.join(a.logdir, "vm-base-main.log"))
        m.start()
        vms.append(m)
        rc, out = m.run("swarm init", timeout=120)
        check(rc == 0, "main node", out)

        # the base: eth0 is the tunnel link, eth1 the swarm network (the card order the old code got wrong)
        b = Sedna(os.path.join(a.images, "shulkeros-node.bin"), kernel, lan=tunnel, mac="52:54:00:00:10:02",
                  log=os.path.join(a.logdir, "vm-base-base.log"))
        b.lan2 = swarm_lan
        b.start()
        vms.append(b)
        rc, out = b.run("swarm base", timeout=180)
        up = re.search(r"Uplink to the main: (eth\d) \((10\.42\.0\.\d+)\)", ANSI.sub("", out))
        check(rc == 0 and up is not None and up.group(1) != "eth0", "the base finds its uplink on the 2nd interface", out)
        check("eth0  10.43.1" in ANSI.sub("", out), "the base serves drones on eth0", out)

        d = Sedna(os.path.join(a.images, "shulkeros-drone.bin"), kernel, lan=tunnel, mac="52:54:00:00:10:03",
                  log=os.path.join(a.logdir, "vm-base-drone.log"))
        d.start()
        vms.append(d)
        got = None
        for _ in range(30):
            rc, out = d.run("ip -4 -o addr show eth0")
            got = re.search(r"inet (10\.43\.1\.\d+)", out)
            if got:
                break
            time.sleep(3)
        check(got is not None, "the drone gets an address from the base", out)
        joined = False
        for _ in range(30):
            rc, out = m.run("swarm status")
            if len(re.findall(r"\bidle\b|\bbusy\b", ANSI.sub("", out))) >= 2:
                joined = True
                break
            time.sleep(3)
        check(joined, "base and drone both joined the main", out)
        # and the base keeps working after a reboot (uplink remembered, services back)
        b.sh("sync")
        b.stop()
        b.copy = False
        b.rootfs = b.disk
        b.start()
        rc, out = d.run("udhcpc -n -q -t 5 -i eth0 2>&1 | tail -2; ip -4 -o addr show eth0")
        check("10.43.1." in out, "after the base reboots it hands out addresses again", out)
    finally:
        for v in vms:
            try:
                v.stop()
            except Exception:
                pass
    print("\n%d failure(s)" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
