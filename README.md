# Shulker OS

A Linux for the computers of [OpenComputers II](https://github.com/fnuecke/oc2) in Minecraft: easy setup, many
computers working together, drones, alarms and dashboards, and an optional Claude assistant.

OC2 computers emulate a 64-bit RISC-V machine that boots **Sedna Linux**, a tiny Buildroot system (BusyBox, musl,
Lua 5.4, an 8 MB disk). Shulker OS keeps it a real Linux and adds the rest in plain Lua and shell. **Shulker Linux**
goes one step further: Sedna rebuilt with RAID, ext4, tmux and HTTPS that checks certificates.

Sibling of [WardenOS](https://github.com/LinuxDino/WardenOS) for CC: Tweaked.

- **Setup wizard** at first start: terms, name, password, what the computer becomes (personal, main, worker, drone
  base, drone), network, SSH, Claude on or off. `shulker setup` runs it again
- **Shulker Swarm**: one main computer and as many workers as you build. The main hands out addresses and installs
  Shulker OS over the network (`wget -qO- http://10.42.0.1/join | sh`), shares out jobs (`swarm run`, `swarm map`),
  and shows every computer, drone and link with its traffic (`swarm top`)
- **Drones**: OC2 robots join the swarm through a drone base, report battery and position, take commands
  (`swarm drone drone1 go 10 0 5`), and fly home to charge by themselves
- **Monitor and dashboard**: energy storage, redstone, comparators and furnaces as sensors, rules that sound a
  redstone alarm or run a command (`monitor add low-power energy '<' 20 redstone:up`), and a status wall on a
  **projector** (`dashboard start`)
- **Desktop**: `desktop` is a full-screen launcher (mouse or keys) for tasks, swarm, drones, files, network, settings
- **Drives**: `shulker disks setup` turns the other drive bays into `/data` (RAID 0/1/linear on Shulker Linux)
- **Tasks and jobs**: `task` is an interactive to-do list (todo.txt); `task job` runs commands later or repeatedly
  through crond
- **A Linux that feels like one**: branded boot and login, motd, `shulkerfetch`, a purple prompt, aliases, a man page
  for every command, `shulker` updates and apps, `netcfg auto` for the Internet Gateway, `sshctl` for SSH
- **Claude, if you want it**: `claude` chats in the terminal, `claude -p` answers once, can run commands and use OC2
  bus devices behind **Allow / Always / Deny**. Off with `shulker disable claude`
- Install with one command, from the main computer over the network, or with a **data pack** that gives every OC2
  computer Shulker OS plus ready-made hard drives (Shulker OS, Swarm Node, Drone)

## Install

### With internet (one command)

Needs an OC2 computer with the default Sedna Linux, a **network interface card**, a **network connector** on the
computer, and an **Internet Gateway** linked to it with a network cable (see the in-game manual). Then:

```
netcfg auto                    # not there yet? use: ip addr add 10.0.0.2/24 dev eth0; ip link set eth0 up;
                               #   ip route add default via 10.0.0.1; echo nameserver 1.1.1.1 > /etc/resolv.conf
wget -qO- https://raw.githubusercontent.com/LinuxDino/ShulkerOS/main/install.sh | sh
```

(BusyBox wget prints "TLS certificate validation not implemented": that's expected, see Security.)

The installer downloads one bundle, checks every file against `manifest.txt` and the free disk space, and only then
installs to `/opt/shulker` (about 200 KB) with a login profile, a boot script and the branding. Log out and back in.
Run it again, or `shulker update`, to update; your tasks, jobs and key in `~/.shulker` are never touched.
Another branch: `... | sh -s -- --branch NAME`.

### Without internet (data pack)

Build it with `tools/build-datapack.sh` (or download the `ShulkerOS-datapack` artifact of the latest CI run) and put
`ShulkerOS-datapack-<version>.zip` into your world's `datapacks` folder (singleplayer: `saves/<world>/datapacks`,
server: `world/datapacks`) and restart the world or server. It contains:

- a **file system layer**: OC2 mounts it at `/mnt/builtin` on every Linux computer, so `claude`, `task`, `shulker`
  and the rest are simply there, and its boot script sets up the profile, branding and crond. Nothing is installed on
  the computer's disk (Shulker OS uses about 9 KB of it for settings). Updates come with a new data pack
- a preloaded **"Shulker OS" hard drive** (purple, offered as a large hard drive in OC2's creative tab): Sedna with Shulker OS
  installed in `/opt/shulker`, updatable with `shulker update`
- a **"Shulker Swarm Node"** drive (magenta): the same, set up as a swarm worker that joins the main computer at
  10.42.0.1 by itself, and a **"Shulker Drone"** drive (cyan) for robots

`tools/build-datapack.sh --no-hdd` builds only the layer. The drive image contains Sedna's root file system (BusyBox, musl, Lua and more, under
the GPL and other licenses listed in the `licenses/` folder of OC2's sedna-buildroot jar), so redistributing that
pack means following those licenses.

## Many computers: Shulker Swarm

```
             Internet Gateway (10.42.0.254)
                    |
  MAIN 10.42.0.1 ---+--- hub --- hub --- worker computers (node1, node2, ...)
                    |
                drone base (worker with a tunnel card) ~~ drones
```

1. On the main computer: `shulker setup` and choose **Main** (or `swarm init`). It hands out addresses
   (10.42.0.100-250), keeps the list of computers and shares out the work. `swarm init --work` lets it work too.
2. Each worker: put in a **"Shulker Swarm Node"** drive from the data pack and start it, or on a stock Sedna computer
   run `udhcpc -i eth0 && wget -qO- http://10.42.0.1/join | sh`. It joins by itself.
3. `swarm status`, `swarm top` (live topology and traffic), `swarm run --on all uptime`, `swarm map 'echo {}' 1 2 3`,
   `swarm bench`. Hubs pass 32 frames a tick and every computer runs on its own thread, so 10 or 18 workers are fine.

Drones (robots with a **"Shulker Drone"** drive) talk to a **drone base**: a worker with a tunnel card linked to the
drone's tunnel module (`swarm base`). `drone status`, `drone go X Y Z`, `drone scan`; from the main computer
`swarm drones` and `swarm drone NAME CMD`. Below 15 % battery a drone goes home to its charger. See `man swarm`,
`man drone`.

## Monitor, alarms and the projector

`monitor` shows the sensors on the bus: energy (`energy`, `energy.1`, ...), `redstone.SIDE`, `comparator`,
`furnace`, plus `mem`, `disk`, `load`, `drone.charge` and on the main `swarm.offline`. Rules:

```
monitor add low-power energy '<' 20 redstone:up        # signal 15 on top while low: wire a bell or lamps
monitor add intruder redstone.north '>' 0 run:swarm run --on drone1 drone home
monitor add lost-node swarm.offline '>' 0
```

`dashboard start` draws a status wall on a connected **projector** (energy bars, alerts, the swarm with every drone,
tasks), and keeps it up across reboots. See `man monitor`, `man dashboard`.

## Shulker Linux and drives

Sedna's kernel has no RAID or ext4. [Shulker Linux](linux/README.md) is Sedna rebuilt from the same Buildroot with
MD RAID, ext4, overlayfs and loop devices, plus `tmux`, `mdadm` and `curl` with CA certificates, and Shulker OS
inside (a 16 MB drive).

- `shulker linux kernel`: only the kernel, in place (checked, rolled back on a bad write); reboot
- `shulker linux install`: the whole system onto an empty drive with your files and settings copied over; then put
  that drive first
- **4 x 8 MB, no 16 MB drive?** Keep Sedna on the first drive and add RAID to it: `shulker linux kernel`, `reboot`,
  `shulker install mdadm` (kept compressed, about 220 KB), then `shulker disks setup`. Leaves about 200 KB free on
  the system drive and gives one 24 MB `/data`
- `shulker disks setup`: the other drives become `/data`: `--raid0` (all the space, default), `--linear`, `--raid1`
  (mirror) or, on stock Sedna, `--separate` (`/data/1`, `/data/2`, ...)

## Claude

You need an **Anthropic API key** from [console.anthropic.com](https://console.anthropic.com); API use is billed to
it (a Claude.ai subscription does not work here). Run `claude`: the first start shows the security warning below,
asks for the key (hidden input) and saves it to `~/.shulker/claude/key` with mode 600. Or set `ANTHROPIC_API_KEY`.

```
claude                         chat (/help, /model sonnet, /effort high, /auto on, /cost, /clear)
claude -c                      continue the last conversation
claude -p "free space?"        one answer; without a terminal, risky tools need --allow run_command,...
claude doctor                  check key, network, DNS and the TLS connection
claude config effort low       options: model, effort, thinking, auto, max_tokens, idle_timeout, retries
```

Real Claude Code needs Node.js, which Sedna doesn't have, so this is a native client written in Lua against the
[Messages API](https://platform.claude.com/docs/en/api/messages): streaming (server-sent events), adaptive thinking
with short progress notes between tool calls, prompt caching, server-side refusal fallbacks, and tool use with the
answers checked against each tool's schema. A request that fails (429, 5xx, overloaded, a gateway that drops the
connection, nothing received for 3 minutes) is retried with backoff; a turn that still fails is undone so the
conversation stays valid. Ctrl-C cancels a reply.

**How it connects.** Sedna's Lua has no TLS library. BusyBox `wget` does HTTPS, but it hides the body of every error
reply and would need the API key on its command line (visible in `ps`). So Shulker OS opens the TCP connection itself
with luaposix and hands the socket to BusyBox's `ssl_client`, which `wget` uses internally: the request goes in on its
stdin (from a mode-600 file in `/tmp`, which is RAM), the decrypted reply streams out and is parsed in Lua.

## Security

> **HTTPS on Sedna does not verify certificates.** There is no CA bundle and BusyBox's TLS cannot check one. Traffic
> is encrypted, but the client cannot prove it is talking to the real `api.anthropic.com`.

What Shulker OS does about it:

- **Address pinning.** `api.anthropic.com` has a fixed, published address range,
  [160.79.104.0/23](https://platform.claude.com/docs/en/api/ip-addresses). Shulker OS only ever connects there: a DNS
  answer outside the range is ignored (with a warning) and `160.79.104.10` is used instead. That defeats fake DNS
  answers, the cheapest attack (the gateway's DNS is plain UDP), and Claude works without any name server at all.
  `claude config pin off` turns it off.
- The key never appears on a command line; requests are written only to RAM, mode 600.
- `claude doctor` shows what DNS said and where it connects.

What it can't do: certificate pinning is not possible with BusyBox's TLS (the certificate is never exposed, and in
TLS 1.3 it is encrypted), and doing TLS in pure Lua on the emulated CPU isn't practical. So anyone who can intercept
traffic **on the way** between the Minecraft server and Anthropic could read the key. Also, the key is stored on the
computer's disk, which is part of the world save: **the server owner can read it** regardless of TLS.
Use a key with a **low spend limit**, and revoke it if in doubt.

Downloads (`install.sh`, `shulker update`) use the same unverified HTTPS. The SHA-256 sums catch broken downloads, but
they come over the same connection, so they don't stop a deliberate man-in-the-middle.

## Tasks and scheduled jobs

```
task                           interactive list: arrows, space = done, p = priority, a/e/d = add/edit/delete
task add -p high Build the reactor +base @overworld      (or start the text with !! or !)
task list [open|done|all|+base]    task done 3    task pri 2 low    task archive
task job add "every 2h" shell "df -h / >> /root/disk.log"
task job add "daily 08:00" claude "summarize /tmp/crond.log and add tasks for problems" --allow run_command
task job                       list jobs     task job log j1     task job rm j1     task job run j1
```

Tasks are a plain [todo.txt](https://github.com/todotxt/todo.txt) file (`~/.shulker/tasks.txt`), so `cat` and `nano`
work too. Claude can read and change them (`task_list`, `task_add`, ...) and schedule jobs (it asks first).
Schedules: `in 10m`, `at 14:30`, `every 5m`/`2h`/`3d`, `hourly`, `daily 09:00`, `weekly`, or any cron spec. Sedna's
`/var/spool` is a RAM disk, so Shulker OS runs crond on `/etc/shulker/crontabs`, which survives reboots. A Claude job
runs `claude -p` with nobody at the terminal, so only the tools you list with `--allow` can do risky things. Each job's
output goes to `~/.shulker/jobs/<id>.log` (last 16 KB).

## Commands

Every command has a man page: `man <command>`, `man -l` lists them, start with `man intro`.

| command | what it does |
| --- | --- |
| `desktop` | full-screen launcher |
| `swarm` | `init`, `join`, `status`, `top`, `run`, `map`, `jobs`, `drones`, `drone`, `base`, `bench` |
| `drone` | `status`, `go`, `move`, `turn`, `home`, `dig`, `place`, `scan`, `inspect` (on a drone) |
| `monitor` | sensors, `add`/`rm` alert rules, `log`, `watch` |
| `dashboard` | status wall on a projector, `start`/`stop` |
| `task` | to-do list (todo.txt) and scheduled jobs (`task job`) |
| `shulker` | `update`, `list`, `install`, `remove`, `doctor`, `setup`, `linux`, `disks`, `enable/disable claude` |
| `shulkerfetch` | system info with the logo (also `neofetch`) |
| `netcfg` | `auto`, `static IP/BITS [GW [DNS]]`, `dhcp`, `wizard` (OC2's setup-network.lua), `off`, `test` |
| `sshctl` | `on`, `off`, `status`, `key 'ssh-ed25519 ...'` |
| `claude` | the optional assistant: chat, `-p` for one answer, `key`, `config`, `doctor` |
| `man` | Shulker OS manual pages; `man oc2` covers OC2's own tools in `/mnt/builtin/bin` |

Apps (`shulker install NAME`): `cowsay` (with `-f shulker`), `fortune`, `matrix`, `snake`, `lsbus`.

Aliases: `ll`, `la`, `..`, `tasks`, `todo`, `update`, `ask` (= `claude -p`), `neofetch`. Your own additions go in
`/etc/shulker/profile.local`. `SHULKER_THEME=ender` (cyan) or `plain`; `touch /etc/shulker/no-branding` keeps
Sedna's own login screen.

## Look and feel

OC2's terminal font has ASCII, Latin-1 and the DEC line-drawing set, but no Unicode blocks, so the shulker box logo
is drawn with DEC graphics: a purple box with a lavender lid and two eyes, at boot, at login, in `shulkerfetch` and in
`claude`. Colours use the 16-colour palette: purple and lavender, like a shulker.

## Files

```
/opt/shulker               Shulker OS (or /mnt/builtin/shulker from the data pack; the disk copy wins)
~/.shulker/claude/         key (mode 600), config.json, session.json (the last chat, if small)
~/.shulker/tasks.txt       your tasks; tasks.done.txt for archived ones
~/.shulker/jobs/           jobs.json and one log per job
/etc/shulker/              crontabs/, repo.conf (repo and branch), profile.local, ssh.enabled
/usr/local/shulker/        installed apps
```

## Development

```
src/                    the OS as it lands in /opt/shulker (bin/, lib/shulker/*.lua, man/, etc/, share/)
install.sh              the one-line installer
manifest.txt, bundle.tar   what the installer and `shulker update` download (tools/gen-manifest.sh)
packages/               the app repository (descriptions.txt; PKG files are generated)
tools/                  gen-manifest.sh, build-datapack.sh, fetch-sedna.sh, gen-branding.lua
tests/unit.lua          host unit tests (plain Lua 5.4: JSON, HTTP and SSE parsing, pinning, tasks, jobs, tools)
tests/mock_api.py       a scripted Messages API (HTTPS, chunked SSE, thinking, tool_use) that checks every request
tests/qemu/             boots the real Sedna kernel and rootfs from OC2's sedna-buildroot jar in QEMU
tests/minecraft/        how it was tested in the real game (RCON scene, XTEST input)
```

Run `tests/run.sh` for syntax, manifest and unit checks; `tests/run.sh --qemu` also boots Sedna in QEMU (needs
`qemu-system-riscv64`, `debugfs`, `zip` and python3 with pexpect) and tests the one-line installer on a stock system,
the data pack layer and the preloaded drive: every command, Claude against the mock API, crond jobs, and a reboot.
CI runs both. After changing anything under `src/` or `packages/`, run `tools/gen-manifest.sh` and commit the
result; when you release, bump `src/VERSION` and `U.VERSION` in `src/lib/shulker/util.lua`.

Commands are Lua scripts that find their libraries through `SHULKER_HOME` (worked out from their own path), so the
same files run from `/opt/shulker` and from the data pack. Keep it small: the root disk has about a megabyte free.
