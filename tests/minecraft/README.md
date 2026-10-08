# Testing Shulker OS in the real game

How Shulker OS was tested end to end in OpenComputers II (the `LinuxDino/OC2NeoForge` port, Minecraft
26.1.2, NeoForge 26.1.2.109) without a screen: a dev server driven over RCON, a dev client under Xvfb
with Mesa's software OpenGL (llvmpipe), and XTEST input from `xinput.py`.

1. Build the mod and the launch scripts: `./gradlew build createClientLaunchScript createServerLaunchScript`.
2. Build the data pack (`tools/build-datapack.sh`) and copy `dist/ShulkerOS-datapack-*.zip` to
   `run/server/world/datapacks/` before the first start.
3. `run/server/server.properties`: `online-mode=false`, `level-type=minecraft\:flat`, `gamemode=creative`,
   `enable-rcon=true`, `rcon.port=25575`, `rcon.password=shulker`; `eula.txt`: `eula=true`.
   Start `build/moddev/runServer.sh` (stdin from /dev/null; use RCON for commands).
4. The mock API (`tests/mock.sh start`) runs on this machine, so allow the gateway to reach it: in
   `run/server/config/oc2-server.toml` set `internetDenyLocalSubnets = false` (the defaults deny the
   server's own subnet and loopback), then restart the server.
5. `Xvfb :99 -screen 0 1280x720x24 &`, then start the client with `runClient.sh` plus
   `--quickPlayMultiplayer localhost:25565 --width 1280 --height 720` (a copy of the script with those
   arguments appended), `DISPLAY=:99`. A small `run/client/options.txt` (render distance 2,
   `pauseOnLostFocus:false`, `onboardAccessibility:false`) keeps it light.
6. `python3 scene.py` builds the scene and puts the player in front of computer A.
7. With `xinput.py`: right-click (button 3) opens the terminal, the power button sits at (285, 187) at
   1280x720 / GUI scale 2, then `type()` commands and `screenshot()` the result.

What was checked this way: data pack loading (layer + "Shulker OS" drive), branded boot and login,
`shulkerfetch` (real RAM, disk, bus devices), `netcfg auto` / `netcfg test` through the Internet
Gateway, `claude doctor` and a chat with tool calls (bus devices, tasks, an approved shell command)
against the mock API at 192.0.2.2:8443, the one-line installer (from the mock's file server: GitHub was
not reachable through the gateway in that sandbox), a crond job running every minute, a reboot, and
the preloaded drive with the interactive task list.
