#!/usr/bin/env python3
"""Shulker Swarm on real Sedna VMs: one main node and N workers on one virtual Ethernet segment
(QEMU multicast sockets stand in for OC2 network cables and a hub).

    python3 tests/qemu/test_swarm.py --sedna work/sedna --images dist/build/pack/data/shulkeros/block_devices/hdd [--workers 3]

The main node boots the "Shulker OS" drive and runs `swarm init --work`; the workers boot the
"Shulker Swarm Node" drive and join by themselves. One worker is started before the main node.
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
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--logdir", default="work")
    a = ap.parse_args()
    kernel = os.path.join(a.sedna, "Image")
    lan = "230.0.0.%d:%d" % (1 + os.getpid() % 200, 20000 + os.getpid() % 20000)
    main_img = os.path.join(a.images, "shulkeros.bin")
    node_img = os.path.join(a.images, "shulkeros-node.bin")
    workers = []
    print("Shulker Swarm: 1 main + %d workers (QEMU, lan %s)" % (a.workers, lan), flush=True)
    try:
        # a worker that boots before the main node exists: it must keep trying
        early = Sedna(node_img, kernel, lan=lan, mac="52:54:00:00:01:01", log=os.path.join(a.logdir, "vm-swarm-w1.log"))
        early.start()
        workers.append(early)

        m = Sedna(main_img, kernel, lan=lan, mac="52:54:00:00:00:01", log=os.path.join(a.logdir, "vm-swarm-main.log"))
        m.start()
        rc, out = m.run("swarm init --work", timeout=120)
        check(rc == 0 and "main node" in out, "swarm init on the main node", out)
        rc, out = m.run("pidof dnsmasq; cat /etc/shulker/swarm.conf | grep -c token")
        check(rc == 0, "DHCP server and token in place", out)

        for i in range(2, a.workers + 1):
            w = Sedna(node_img, kernel, lan=lan, mac="52:54:00:00:01:%02x" % i, log=os.path.join(a.logdir, "vm-swarm-w%d.log" % i))
            w.start()
            workers.append(w)

        want = a.workers + 1                   # the main node works too (--work)
        seen = 0
        out = ""
        for _ in range(40):
            rc, out = m.run("swarm status")
            seen = len(re.findall(r"\bidle\b|\bbusy\b", ANSI.sub("", out)))
            if seen >= want:
                break
            time.sleep(3)
        check(seen >= want, "all %d nodes joined by themselves (%d online)" % (want, seen), out)
        print(ANSI.sub("", out))

        time.sleep(8)                          # a few heartbeats, so there are traffic rates
        rc, out = m.run("swarm top --once")
        plain = ANSI.sub("", out)
        check(rc == 0 and "MAIN" in plain and "Internet Gateway" in plain and len(re.findall(r"node\d+", plain)) >= want
              and "rx" in plain, "swarm top shows gateway, main, every node and traffic", out)

        rc, out = workers[0].run("hostname; ip -4 -o addr show eth0")
        check(re.search(r"node\d+", out) and "10.42.0." in out, "the early worker got an address and a node name", out)

        rc, out = m.run("swarm run 'echo hi from $(hostname)'", timeout=180)
        check(rc == 0 and len(re.findall(r"hi from", out)) == want, "swarm run on every node", out)

        rc, out = m.run("swarm map 'expr {} \\* {}' 1 2 3 4 5 6 7 8 2>/dev/null", timeout=240)
        nums = [int(x) for x in re.findall(r"^\d+$", ANSI.sub("", out).replace("\r", "\n"), re.M)]
        check(rc == 0 and nums == [1, 4, 9, 16, 25, 36, 49, 64], "swarm map spreads work and keeps the order", out)

        # a worker can use the swarm too (token learned when it joined)
        rc, out = workers[-1].run("swarm submit 'echo from-a-worker' && sleep 8 && swarm jobs | tail -n 1")
        check(rc == 0 and "done" in ANSI.sub("", out), "a worker submits a job with its own token", out)

        rc, out = m.run("swarm bench", timeout=400)
        check(rc == 0 and "Speed-up" in out, "swarm bench", out)
        print("  ..    " + ANSI.sub("", out).strip().splitlines()[-1])

        # a node that goes away: its queued work goes to the others
        workers[-1].stop()
        rc, out = m.run("swarm map 'sleep 2; echo ok-{}' a b c d", timeout=300)
        check(rc == 0 and out.count("ok-") == 4, "work still finishes after a node is switched off", out)

        # the main node reboots: the nodes come back by themselves
        m.sh("sync")
        m.stop()
        m.copy = False
        m.rootfs = main_img + ".525400000001.run"
        m.start()
        seen = 0
        for _ in range(40):
            rc, out = m.run("swarm status")
            seen = len(re.findall(r"\bidle\b|\bbusy\b", ANSI.sub("", out)))
            if seen >= want - 1:
                break
            time.sleep(3)
        check(seen >= want - 1, "after rebooting the main node the swarm is back (%d online)" % seen, out)
    finally:
        for w in workers:
            try:
                w.stop()
            except Exception:
                pass
        try:
            m.stop()
        except Exception:
            pass
    print("\n%d failure(s)" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
