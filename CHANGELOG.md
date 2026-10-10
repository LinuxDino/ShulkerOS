# Changelog

## 1.0.0

- Data pack: crafting recipes for the Shulker Drone, Swarm Node, Shulker OS and Shulker Linux drives (large hard
  drive + RISC-V CPU + dye), so drives for many drones come from a crafting table or an autocrafter
- Drones join as drones: a drone drive says so at boot, before the OC2 bus is up; a drone that joined as
  "nodeN" is renamed "droneN"; drones never take computer jobs
- Drones reconnect to the OC2 bus when reading the robot fails (a dead bus connection meant no robot report, so
  no work and "0 drones"); `drone debug` and `swarm drones` say why a drone gets no work
- Network load of the main (KB/s against the 64 KB/s of a network connector, frames/s against the 640 of a hub)
  in `control` and on the dashboard; the main keeps the dashboard running whenever a projector is connected
  (`dashboard stop` turns that off); a computer running from the data pack says how to install an updatable copy
- Control Center (`control`): computers, drones, orders with progress, energy and alarms, command bar
- Orders split over the swarm: `mine` (drones, slices, charging, take-over), `home`, `go`, `run`, `map`, `stop`
- Storage from any mod: `storage`, `storage find`, `swarm find`, `swarm devices`; monitor sensors `fluid.N`,
  `storage.N`
- Automatic updates: the main checks GitHub daily, every member follows the main; services restart themselves
- Disk maker: `shulker mkdisk` writes Lab, Robot or Plain drives (slim system, RAID kernel, mdadm)
- Drone bases find their uplink on any network card; drones use world coordinates (`drone origin`)
- Swarm members get updates, apps and Shulker Linux images from the main (one copy for all)
- Shulker Linux 0.1.0 images: kernel with RAID/ext4, mdadm, tmux, curl with CA certificates
- Claude (optional): short answers, knows the swarm, tools for swarm status, orders, storage and the monitor
- Fixes: OC2 bus shared through the bus daemon, checksum list refreshed after updates, empty drives ignored,
  jobs get the right PATH, swarm update space check

## 0.1.0

First release: Shulker OS for Sedna Linux with Claude, tasks and jobs, swarm, drones, setup wizard, desktop,
monitor, dashboard, data pack and installer.
