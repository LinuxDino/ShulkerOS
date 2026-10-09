-- Shulker Swarm: many OC2 computers working as one. Shared by swarmd (the service) and swarm (the CLI).
--
-- One computer is the main node (the leader): fixed address, DHCP server for the others, job queue.
-- Workers poll the leader every few seconds ("heartbeat"): they report their status and get jobs back,
-- so the leader never has to connect to them and a rebooting worker simply turns up again.
-- Every message is one line of JSON over a short TCP connection to the leader's port.
--
-- /etc/shulker/swarm.conf (key=value): role=main|worker, leader=10.42.0.1, port=4242, token=...,
-- name=node3 (given by the leader), cpu_jobs=1 (the main node also runs jobs: 0 or 1)
local U = require("shulker.util")
local json = require("shulker.json")

local M = {}

M.PORT = 4242
M.SUBNET = "10.42.0"
M.LEADER_IP = "10.42.0.1"
M.GATEWAY_IP = "10.42.0.254"       -- an Internet Gateway on the swarm network answers here
-- A hub passes 32 frames a tick (640/s) and one request costs ~12 frames: 140 members beating every
-- second would need ~1,700 frames/s and drop packets. At 8-10 s it is ~220 frames/s for 22 computers
-- and 120 drones. Finished jobs are still reported at once (see swarmd).
M.HEARTBEAT = 8                    -- seconds between heartbeats of a node at work (idle: BEAT_IDLE)
M.BEAT_IDLE = 10                   -- an idle node
M.FULL_EVERY = 60                  -- full statistics (disk, bus, version...) this often, else a light beat
M.DEAD_AFTER = 45                  -- a node not heard from for this long is shown as offline
M.MAX_OUTPUT = 8192                -- bytes of job output kept

---------------------------------------------------------------- config
function M.confPath() return os.getenv("SHULKER_SWARM_CONF") or (U.etcdir() .. "/swarm.conf") end

function M.loadConf()
  local c = { port = M.PORT, leader = M.LEADER_IP }
  for _, line in ipairs(U.lines(M.confPath())) do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then c[k] = v end
  end
  c.port = tonumber(c.port) or M.PORT
  return c
end

function M.saveConf(c)
  U.mkdir(U.etcdir())
  local keys = {}
  for k in pairs(c) do keys[#keys + 1] = k end
  table.sort(keys)
  local lines = { "# Shulker Swarm (see `man swarm`)" }
  for _, k in ipairs(keys) do lines[#lines + 1] = k .. "=" .. tostring(c[k]) end
  return U.write(M.confPath(), table.concat(lines, "\n") .. "\n", "600")
end

function M.newToken()
  local f = io.open("/dev/urandom", "rb")
  local bytes = f and f:read(12) or tostring(os.time() .. os.clock())
  if f then f:close() end
  return (bytes:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
end

---------------------------------------------------------------- this node
local function readNum(path, pattern)
  local s = U.read(path) or ""
  return tonumber(s:match(pattern) or "")
end

function M.mac()
  local m = U.trim(U.read("/sys/class/net/eth0/address") or "")
  return m ~= "" and m or nil
end

-- the network interfaces, eth0 first
function M.ifaces()
  local list = {}
  for n in U.capture("ls /sys/class/net 2>/dev/null"):gmatch("%S+") do
    if n:match("^eth%d+$") then list[#list + 1] = n end
  end
  table.sort(list, function(a, b) return tonumber(a:match("%d+")) < tonumber(b:match("%d+")) end)
  return list
end

local function addrOf(iface)
  return U.capture("ip -4 -o addr show " .. iface .. " 2>/dev/null"):match("inet (%d+%.%d+%.%d+%.%d+)")
end
M.addrOf = addrOf

-- the interface towards the main node. OC2 numbers network cards by slot, so on a drone base the
-- network card is not always eth0: the uplink is the interface with a swarm address (10.42.0.x),
-- remembered in swarm.conf (uplink=ethN) once found
function M.uplink(conf)
  conf = conf or M.loadConf()
  local prefix = "^" .. M.SUBNET:gsub("%.", "%%.") .. "%."
  for _, n in ipairs(M.ifaces()) do
    local a = addrOf(n)
    if a and a:match(prefix) then
      if conf.uplink ~= n and conf.role then conf.uplink = n pcall(M.saveConf, conf) end
      return n
    end
  end
  if conf.uplink and U.exists("/sys/class/net/" .. conf.uplink) then return conf.uplink end
  return nil
end

-- ask every interface for a swarm address until one gets it (a base whose card order is unknown)
function M.findUplink(conf)
  local up = M.uplink(conf)
  if up then return up end
  for _, n in ipairs(M.ifaces()) do
    os.execute(("ip link set %s up; udhcpc -n -q -t 2 -T 2 -i %s >/dev/null 2>&1"):format(n, n))
    up = M.uplink(conf)
    if up then return up end
  end
  return nil
end

local ipCache, ipAt = nil, 0
function M.ip(fresh)
  if not fresh and ipCache and os.time() - ipAt < 30 then return ipCache end
  ipCache, ipAt = M.ipNow(), os.time()
  return ipCache
end

function M.ipNow()
  local conf = M.loadConf()
  if conf.base == "1" then
    local up = M.uplink(conf)
    return up and addrOf(up) or nil
  end
  return addrOf("eth0")
end

-- robots report energy, position and modules (nil on normal computers; checked once)
local isRobot
function M.droneInfo(light)
  if isRobot == false then return nil end
  -- swarmd runs all the time: it must reach the robot through OC2's bus daemon only (see devices.lua)
  require("shulker.devices").daemonOnly = true
  if not U.exists("/run/oc2/bus") then return nil end
  local ok, D = pcall(require, "shulker.drone")
  if not ok then isRobot = false return nil end
  local info = D.isDrone() and D.info(light) or nil
  if not info then isRobot = false return nil end
  -- world coordinates once `drone origin` is set, so the main can plan areas for all drones at once
  local o = D.origin()
  if o and info.pos then info.pos = D.toWorld(info.pos) info.world = true end
  return info
end

-- the leader address: "auto" = whoever gave us our address (the main node, or a drone base)
local gwCache, gwAt = nil, 0
function M.leaderOf(conf)
  if conf.leader and conf.leader ~= "auto" then return conf.leader end
  -- a drone's main is reached through its base, its default gateway (asked at most every 30 s)
  if not gwCache or os.time() - gwAt >= 30 then
    gwCache = U.capture("ip route 2>/dev/null"):match("default via (%d+%.%d+%.%d+%.%d+)")
    gwAt = os.time()
  end
  return gwCache or M.LEADER_IP
end

-- a small status report: what the leader and the dashboards show
-- what is on this computer's device bus, by type name, at most every 30 s (through OC2's bus daemon only)
local busCache, busAt = nil, 0
function M.busSummary()
  if os.time() - busAt < 30 then return busCache end
  busAt = os.time()
  local devices = require("shulker.devices")
  devices.daemonOnly = true
  if not U.exists(devices.SOCKET) then busCache = nil return nil end
  local list = devices.list()
  if not list then return busCache end
  local count = {}
  for _, d in ipairs(list) do
    for _, t in ipairs(d.types) do count[t] = (count[t] or 0) + 1 end
  end
  busCache = count
  return count
end

-- full: everything (every FULL_EVERY s); otherwise a light beat the main merges into what it has
function M.stats(full)
  if full == nil then full = true end
  local okM, monitor = pcall(require, "shulker.monitor")
  local mon = okM and monitor.state(30)
  local meminfo = U.read("/proc/meminfo") or ""
  local total = tonumber(meminfo:match("MemTotal:%s*(%d+)")) or 0
  local avail = tonumber(meminfo:match("MemAvailable:%s*(%d+)")) or 0
  local rx0, tx0 = (U.read("/proc/net/dev") or ""):match("eth0:%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)")
  if not full then
    return {
      mac = M.mac(), ip = M.ip(), load = readNum("/proc/loadavg", "^(%S+)") or 0, mem_free = avail,
      rx = tonumber(rx0), tx = tonumber(tx0), drone = M.droneInfo(true),
      energy = mon and mon.sensors and mon.sensors.energy and mon.sensors.energy.value,
      alerts = mon and #(mon.alerts or {}) or nil,
    }
  end
  local df = U.capture("df -k / | tail -n 1")
  local rx, tx = (U.read("/proc/net/dev") or ""):match("eth0:%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)")
  local f = {}
  for w in df:gmatch("%S+") do f[#f + 1] = w end
  return {
    host = U.trim(U.read("/etc/hostname") or "?"),
    mac = M.mac(), ip = M.ip(),
    load = readNum("/proc/loadavg", "^(%S+)") or 0,
    mem_total = total, mem_free = avail,
    disk_total = tonumber(f[2] or ""), disk_free = tonumber(f[4] or ""),
    uptime = math.floor(readNum("/proc/uptime", "^(%S+)") or 0),
    rx = tonumber(rx), tx = tonumber(tx),
    drone = M.droneInfo(),
    devices = M.busSummary(),
    energy = mon and mon.sensors and mon.sensors.energy and mon.sensors.energy.value,
    alerts = mon and #(mon.alerts or {}) or nil,
    version = U.trim(U.read(U.home() .. "/VERSION") or U.VERSION),
  }
end

---------------------------------------------------------------- transport (luasocket)
local okSock, socket = pcall(require, "socket")
M.socket = okSock and socket or nil

-- send one request to the leader, return the decoded reply | nil, error
function M.call(conf, msg, timeout)
  if not M.socket then return nil, "luasocket is missing" end
  msg.token = msg.token or conf.token
  local c = M.socket.tcp()
  c:settimeout(timeout or 10)
  local leader = M.leaderOf(conf)
  local ok, err = c:connect(leader, conf.port or M.PORT)
  if not ok then c:close() return nil, ("cannot reach the main node %s:%s (%s)"):format(leader, conf.port, err) end
  local sent, serr = c:send(json.encode(msg) .. "\n")
  if not sent then c:close() return nil, "send: " .. tostring(serr) end
  local line, rerr = c:receive("*l")
  c:close()
  if not line then return nil, "no reply from the main node (" .. tostring(rerr) .. ")" end
  local reply = json.decode(line)
  if type(reply) ~= "table" then return nil, "bad reply from the main node" end
  if reply.error then return nil, tostring(reply.error) end
  return reply
end

---------------------------------------------------------------- the leader's state
-- nodes:  [mac] = { name, mac, ip, host, stats, seen (os.time), joined, busy = job id }
-- jobs:   list of { id, cmd, target = "any"|"drone"|name, node, state = queued|running|done|failed|lost,
--                   rc, out, created, started, finished, timeout, group, order, label, stop }
--          "any" goes to a computer (never a drone), "drone" to whichever drone is free
-- orders: list of { id, label, kind, group, created } : a piece of work split into jobs (`swarm order`)
function M.newLeader(conf)
  local L = { conf = conf, nodes = {}, jobs = {}, nextJob = 1, enrollUntil = 0, log = {}, mainMac = M.mac(),
              orders = {}, nextOrder = 1 }

  local statePath = (os.getenv("SHULKER_SWARM_STATE") or "/tmp/swarm-state.json")
  local function save()
    local nodes = {}
    for _, n in pairs(L.nodes) do nodes[#nodes + 1] = { name = n.name, mac = n.mac, joined = n.joined } end
    U.write(statePath, json.encode({ nodes = json.array(nodes), enrollUntil = L.enrollUntil }))
    -- the join window survives restarts of the main (swarm enroll always)
    U.write(U.etcdir() .. "/swarm-enroll", tostring(math.floor(L.enrollUntil)) .. "\n", "600")
    -- the node list must survive reboots of the main node: keep it next to the config
    U.write(U.etcdir() .. "/swarm-nodes.json", json.encode(json.array(nodes)), "600")
  end
  L.save = save

  L.enrollUntil = tonumber(U.trim(U.read(U.etcdir() .. "/swarm-enroll") or "")) or 0
  -- known nodes from before a reboot
  local known = json.decode(U.read(U.etcdir() .. "/swarm-nodes.json") or "")
  if type(known) == "table" then
    for _, n in ipairs(known) do
      if n.mac then L.nodes[n.mac] = { name = n.name, mac = n.mac, joined = n.joined, seen = 0 } end
    end
  end

  function L.note(text)
    table.insert(L.log, 1, os.date("%H:%M:%S ") .. text)
    while #L.log > 50 do table.remove(L.log) end
  end

  local function nodeName(prefix)
    local used = {}
    for _, n in pairs(L.nodes) do used[n.name] = true end
    for i = 1, 999 do if not used[prefix .. i] then return prefix .. i end end
  end

  local function online(n) return os.time() - (n.seen or 0) <= M.DEAD_AFTER end
  L.online = online

  function L.addJob(cmd, target, timeout, group, order, label)
    local j = { id = L.nextJob, cmd = cmd, target = target or "any", state = "queued", created = os.time(),
                timeout = math.min(tonumber(timeout) or 600, 14400), group = group, order = order, label = label }
    L.nextJob = L.nextJob + 1
    L.jobs[#L.jobs + 1] = j
    -- keep the last 400 jobs, but never drop unfinished ones
    local i = 1
    while #L.jobs > 400 and i <= #L.jobs do
      if L.jobs[i].state == "queued" or L.jobs[i].state == "running" then i = i + 1 else table.remove(L.jobs, i) end
    end
    return j
  end

  local function isDrone(n) return n.stats and type(n.stats.drone) == "table" end
  L.isDrone = isDrone

  function L.job(id)
    for _, j in ipairs(L.jobs) do if j.id == tonumber(id) then return j end end
  end

  ---------------------------------------------------------------- area campaigns (clear)
  -- A campaign clears a big box: chunk columns (16x16, clipped to the box) in bands of 9 layers from the
  -- top down. Pieces are made only when a drone is free, so a 25x25-chunk area doesn't create thousands
  -- of jobs; a drone keeps its chunk until it reaches the bottom. Progress is saved to disk and survives
  -- restarts of the main (an interrupted band is simply done again).
  L.campaigns = {}
  local campaignPath = U.etcdir() .. "/swarm-campaigns.json"
  local function saveCampaigns()
    local list = {}
    for _, c in pairs(L.campaigns) do list[#list + 1] = c end
    table.sort(list, function(a, b) return a.id < b.id end)
    local copy = {}
    for _, c in ipairs(list) do
      local chunks = {}
      for _, ch in ipairs(c.chunks) do
        chunks[#chunks + 1] = { ch.x1, ch.z1, ch.x2, ch.z2, ch.band, ch.owner or "", ch.tries, ch.failed and 1 or 0 }
      end
      copy[#copy + 1] = { id = c.id, label = c.label, box = c.box, bands = json.array(c.bands), chunks = json.array(chunks),
                          done = c.done, created = c.created, stopped = c.stopped and true or false }
    end
    U.write(campaignPath, json.encode(json.array(copy)), "600")
  end
  L.saveCampaigns = saveCampaigns

  -- box = { x1, z1, x2, z2, top, bottom } in world coordinates
  function L.newCampaign(id, label, box)
    local x1, x2 = math.min(box.x1, box.x2), math.max(box.x1, box.x2)
    local z1, z2 = math.min(box.z1, box.z2), math.max(box.z1, box.z2)
    local top, bottom = math.max(box.top, box.bottom), math.min(box.top, box.bottom)
    local bands = {}
    local y = top
    while y >= bottom do bands[#bands + 1] = { y, math.max(y - 8, bottom) } y = y - 9 end
    local chunks = {}
    for cx = x1 // 16, x2 // 16 do
      for cz = z1 // 16, z2 // 16 do
        chunks[#chunks + 1] = { x1 = math.max(x1, cx * 16), z1 = math.max(z1, cz * 16),
                                x2 = math.min(x2, cx * 16 + 15), z2 = math.min(z2, cz * 16 + 15),
                                band = 1, tries = 0 }
      end
    end
    local c = { id = id, label = label, box = { x1 = x1, z1 = z1, x2 = x2, z2 = z2, top = top, bottom = bottom },
                bands = bands, chunks = chunks, done = 0, created = os.time() }
    L.campaigns[id] = c
    saveCampaigns()
    return c
  end

  function L.campaignTotal(c) return #c.chunks * #c.bands end

  -- drones that keep failing (no pickaxe, stuck...) pause instead of spoiling chunk after chunk
  L.droneFails = {}

  -- the next piece of any active campaign for drone n (its own chunk first, then a free one)
  function L.campaignPiece(n)
    local f = L.droneFails[n.name]
    if f and f.count >= 2 and os.time() < f.untilT then return nil end
    local ids = {}
    for id in pairs(L.campaigns) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local c = L.campaigns[id]
      if not c.stopped then
        local pickCh
        for _, ch in ipairs(c.chunks) do
          if ch.owner == n.name and not ch.job and not ch.failed and ch.band <= #c.bands then pickCh = ch break end
        end
        if not pickCh then
          for _, ch in ipairs(c.chunks) do
            if not ch.owner and not ch.job and not ch.failed and ch.band <= #c.bands and ch.lastFailedBy ~= n.name then
              pickCh = ch break
            end
          end
        end
        if pickCh then
          pickCh.owner = n.name
          local b = c.bands[pickCh.band]
          local j = L.addJob(("drone clear %d %d %d %d %d %d"):format(pickCh.x1, b[1], pickCh.z1, pickCh.x2, b[2], pickCh.z2),
            n.name, 14400, "order-" .. c.id, c.id,
            ("chunk %d,%d y%d..%d"):format(pickCh.x1 // 16, pickCh.z1 // 16, b[1], b[2]))
          j.campaign, j.chunkRef = c.id, pickCh
          pickCh.job = j.id
          saveCampaigns()
          return j
        end
      end
    end
  end

  -- a campaign job ended (done, failed, lost or cancelled)
  function L.jobEnded(j)
    local c = j.campaign and L.campaigns[j.campaign]
    local ch = j.chunkRef
    if not c or not ch or ch.job ~= j.id then return end
    ch.job = nil
    local who = j.node
    if j.state == "done" then
      ch.band, ch.tries, ch.lastFailedBy = ch.band + 1, 0, nil
      c.done = c.done + 1
      if ch.band > #c.bands then ch.owner = nil end
      if who then L.droneFails[who] = nil end
    else
      ch.tries, ch.owner, ch.lastFailedBy = ch.tries + 1, nil, who
      if who and j.state ~= "lost" then
        local f = L.droneFails[who] or { count = 0, untilT = 0 }
        f.count = f.count + 1
        if f.count >= 2 then
          f.untilT = os.time() + 600
          L.note(("%s failed %d pieces in a row: paused 10 min (check it: swarm drone %s check)"):format(who, f.count, who))
        end
        L.droneFails[who] = f
      end
      if ch.tries >= 3 then ch.failed = true L.note(("order %d: %s failed 3 times, skipped"):format(c.id, j.label or "")) end
    end
    saveCampaigns()
  end

  -- campaigns from before a restart
  local savedCampaigns = json.decode(U.read(campaignPath) or "")
  if type(savedCampaigns) == "table" then
    for _, sc in ipairs(savedCampaigns) do
      local c = { id = sc.id, label = sc.label, box = sc.box, bands = sc.bands, done = sc.done or 0,
                  created = sc.created, stopped = sc.stopped, chunks = {} }
      for _, t in ipairs(sc.chunks or {}) do
        c.chunks[#c.chunks + 1] = { x1 = t[1], z1 = t[2], x2 = t[3], z2 = t[4], band = t[5],
                                    owner = (t[6] ~= "" and t[6]) or nil, tries = t[7] or 0, failed = t[8] == 1 }
      end
      L.campaigns[c.id] = c
      L.orders[#L.orders + 1] = { id = c.id, label = c.label, kind = "clear", created = c.created, group = "order-" .. c.id }
      if c.id >= L.nextOrder then L.nextOrder = c.id + 1 end
    end
  end

  -- a node asks for work: its own jobs first, then the shared ones ("any" for computers, "drone" for drones)
  local function pick(n)
    if n.busy then return nil end
    for _, j in ipairs(L.jobs) do
      if j.state == "queued" and j.target == n.name then return j end
    end
    local shared = isDrone(n) and "drone" or "any"
    if isDrone(n) and (tonumber(n.stats.drone.charge) or 100) < 25 then return nil end   -- let it charge first
    for _, j in ipairs(L.jobs) do
      if j.state == "queued" and j.target == shared then return j end
    end
    if isDrone(n) then return L.campaignPiece(n) end
  end

  -- jobs whose node vanished are queued again (once) or marked lost
  function L.reap()
    local byName = {}
    for _, x in pairs(L.nodes) do byName[x.name] = x end
    for _, j in ipairs(L.jobs) do
      if j.state == "running" then
        local n = byName[j.node]
        local overdue = j.started and os.time() - j.started > j.timeout + 60
        if not n or not online(n) or overdue then
          local tries = j.retried == true and 1 or (tonumber(j.retried) or 0)
          if (j.target == "any" or j.target == "drone") and not j.stop and tries < (j.target == "drone" and 3 or 1) then
            j.state, j.node, j.retried = "queued", nil, tries + 1
            L.note(("job %d requeued (%s went away)"):format(j.id, tostring(n and n.name)))
          else
            j.state = "lost"
            j.finished = os.time()
            L.jobEnded(j)
          end
          if n and n.busy == j.id then n.busy = nil end
        end
      end
    end
  end

  local H = {}

  function H.join(msg)
    local mac = msg.stats and msg.stats.mac or msg.mac
    if not mac then return { error = "no MAC address" } end
    local n = L.nodes[mac]
    if not n then
      if os.time() > L.enrollUntil then
        return { error = "the swarm is not accepting new nodes: run `swarm enroll` on the main node" }
      end
      n = { name = nodeName(msg.stats.drone and "drone" or "node"), mac = mac, joined = os.date("%Y-%m-%d %H:%M") }
      L.nodes[mac] = n
      L.note(n.name .. " joined (" .. tostring(msg.stats and msg.stats.ip) .. ")")
      save()
    end
    n.seen, n.stats, n.ip, n.via = os.time(), msg.stats, msg.stats and msg.stats.ip, msg.via
    return { ok = true, name = n.name, token = L.conf.token }
  end

  function H.heartbeat(msg)
    local mac = msg.stats and msg.stats.mac
    local n = mac and L.nodes[mac]
    if not n then return { error = "unknown node: join first", rejoin = true } end
    -- traffic rates from the byte counters of the last two heartbeats
    local now = os.time()
    if n.stats and n.stats.rx and msg.stats.rx and n.seen and now > n.seen then
      local dt = now - n.seen
      n.rxRate = math.max(0, (msg.stats.rx - n.stats.rx) / dt)
      n.txRate = math.max(0, (msg.stats.tx - n.stats.tx) / dt)
    end
    if msg.light and type(n.stats) == "table" then
      -- a light beat: merge into the last full statistics (a drone keeps its module list)
      local merged = {}
      for k, v in pairs(n.stats) do merged[k] = v end
      for k, v in pairs(msg.stats) do
        if k == "drone" and type(v) == "table" and type(merged.drone) == "table" then
          local d = {}
          for dk, dv in pairs(merged.drone) do d[dk] = dv end
          for dk, dv in pairs(v) do d[dk] = dv end
          merged.drone = d
        else
          merged[k] = v
        end
      end
      n.stats = merged
    else
      n.stats = msg.stats
    end
    n.seen, n.ip, n.via = now, msg.stats.ip or n.ip, msg.via
    -- results of finished jobs
    for _, r in ipairs(msg.results or {}) do
      local j = L.job(r.id)
      if j and j.state == "running" and j.node == n.name then
        j.state = (tonumber(r.rc) == 0) and "done" or "failed"
        j.rc, j.out, j.finished = tonumber(r.rc), tostring(r.out or ""):sub(-M.MAX_OUTPUT), os.time()
        L.jobEnded(j)
      end
      if n.busy == tonumber(r.id) then n.busy = nil end
    end
    if msg.running then n.busy = tonumber(msg.running) else n.busy = nil end
    local reply = { ok = true, name = n.name, os = M.osToken() }
    -- running jobs someone stopped (swarm stop): the node kills them and reports the result
    for _, x in ipairs(L.jobs) do
      if x.state == "running" and x.node == n.name and x.stop then
        reply.stop = reply.stop or {}
        reply.stop[#reply.stop + 1] = x.id
      end
    end
    if reply.stop then reply.stop = json.array(reply.stop) end
    local j = pick(n)
    if j then
      j.state, j.node, j.started = "running", n.name, os.time()
      n.busy = j.id
      reply.job = { id = j.id, cmd = j.cmd, timeout = j.timeout }
    end
    return reply
  end

  -- compact = true: only what the Control Center, dashboard and monitor show (small replies, fast)
  local function compactStats(st)
    if type(st) ~= "table" then return nil end
    local d = type(st.drone) == "table" and { charge = st.drone.charge, pos = st.drone.pos, world = st.drone.world } or nil
    return { load = st.load, alerts = st.alerts, energy = st.energy, drone = d }
  end

  function H.status(msg)
    local compact = msg and msg.compact
    local nodes = {}
    for _, n in pairs(L.nodes) do
      nodes[#nodes + 1] = { name = n.name, mac = not compact and n.mac or nil, ip = n.ip, online = online(n), busy = n.busy,
                            seen = n.seen and (os.time() - n.seen) or nil,
                            stats = compact and compactStats(n.stats) or n.stats,
                            rx_rate = n.rxRate, tx_rate = n.txRate, main = n.mac == L.mainMac, via = n.via }
    end
    table.sort(nodes, function(a, b)
      return (tonumber(a.name:match("%d+")) or 0) < (tonumber(b.name:match("%d+")) or 0)
    end)
    local q, r = 0, 0
    for _, j in ipairs(L.jobs) do
      if j.state == "queued" then q = q + 1 elseif j.state == "running" then r = r + 1 end
    end
    local gw = U.trim(U.read("/tmp/swarm-gateway") or "")
    return { ok = true, nodes = json.array(nodes), queued = q, running = r, gateway = gw ~= "" and gw or "unknown",
             leader = { ip = M.ip(), host = U.trim(U.read("/etc/hostname") or "") },
             enrolling = math.max(0, L.enrollUntil - os.time()),
             log = json.array(compact and { L.log[1], L.log[2], L.log[3], L.log[4], L.log[5], L.log[6] } or L.log) }
  end

  -- submit: { cmd, target = "any"|"all"|name, timeout } or { map = {items}, cmd with {} }
  function H.submit(msg)
    local ids = {}
    local group = tostring(os.time()) .. "-" .. L.nextJob
    if type(msg.map) == "table" then
      for _, item in ipairs(msg.map) do
        local cmd = tostring(msg.cmd):gsub("{}", function() return U.q(tostring(item)) end)
        ids[#ids + 1] = L.addJob(cmd, "any", msg.timeout, group).id
      end
    elseif msg.target == "all" then
      for _, n in pairs(L.nodes) do
        if online(n) then ids[#ids + 1] = L.addJob(msg.cmd, n.name, msg.timeout, group).id end
      end
      if #ids == 0 then return { error = "no node is online" } end
    else
      ids[1] = L.addJob(msg.cmd, msg.target or "any", msg.timeout, group).id
    end
    return { ok = true, ids = json.array(ids), group = group }
  end

  function H.jobs(msg)
    local out = {}
    for _, j in ipairs(L.jobs) do
      local want = true
      if msg.ids then
        want = false
        for _, id in ipairs(msg.ids) do if tonumber(id) == j.id then want = true end end
      end
      if want then
        out[#out + 1] = { id = j.id, cmd = j.cmd, target = j.target, node = j.node, state = j.state,
                          order = j.order, label = j.label,
                          rc = j.rc, out = msg.full and j.out or nil, created = j.created, started = j.started,
                          finished = j.finished }
      end
    end
    return { ok = true, jobs = json.array(out) }
  end

  -- seconds = how long new computers and drones may join; always = keep accepting (a growing fleet);
  -- off = stop now. The window is saved, so it survives restarts of the main.
  function H.enroll(msg)
    if msg.always then
      L.enrollUntil = os.time() + 10 * 365 * 24 * 3600
      L.note("accepting new nodes from now on (swarm enroll off to stop)")
    elseif msg.off then
      L.enrollUntil = 0
      L.note("not accepting new nodes")
    else
      L.enrollUntil = os.time() + math.min(tonumber(msg.seconds) or 1800, 24 * 3600)
      L.note("accepting new nodes for " .. math.floor((L.enrollUntil - os.time()) / 60) .. " min")
    end
    save()
    return { ok = true, until_ = L.enrollUntil }
  end

  function H.forget(msg)
    for mac, n in pairs(L.nodes) do
      if n.name == msg.name or mac == msg.name then
        L.nodes[mac] = nil
        save()
        L.note(n.name .. " removed")
        return { ok = true }
      end
    end
    return { error = "no node " .. tostring(msg.name) }
  end

  -- cancel: { id } one job, { order } every piece of an order, { all = true } everything;
  -- queued pieces are dropped, running ones are stopped on their node (stop = true)
  function H.cancel(msg)
    local n = 0
    for _, j in ipairs(L.jobs) do
      local hit = msg.all or j.id == tonumber(msg.id) or (msg.order and j.order == tonumber(msg.order))
      if hit and j.state == "queued" then
        j.state, j.out, j.finished = "failed", "cancelled", os.time()
        L.jobEnded(j)
        n = n + 1
      elseif hit and j.state == "running" and (msg.stop or msg.order) then
        j.stop = true
        n = n + 1
      end
    end
    for id, c in pairs(L.campaigns) do
      if msg.all or (msg.order and tonumber(msg.order) == id) then c.stopped = true saveCampaigns() end
    end
    return { ok = true, cancelled = n }
  end

  -- order: { label, kind, pieces = { { cmd, target, label, timeout } } } -> one job per piece
  function H.order(msg)
    if type(msg.campaign) == "table" then
      local b = msg.campaign
      for _, k in ipairs({ "x1", "z1", "x2", "z2", "top", "bottom" }) do
        if not tonumber(b[k]) then return { error = "campaign box needs " .. k } end
      end
      local o = { id = L.nextOrder, label = tostring(msg.label or "clear"), kind = "clear", created = os.time() }
      L.nextOrder = L.nextOrder + 1
      o.group = "order-" .. o.id
      local c = L.newCampaign(o.id, o.label, { x1 = tonumber(b.x1), z1 = tonumber(b.z1), x2 = tonumber(b.x2),
        z2 = tonumber(b.z2), top = tonumber(b.top), bottom = tonumber(b.bottom) })
      L.orders[#L.orders + 1] = o
      L.note(("order %d: %s (%d chunks x %d bands)"):format(o.id, o.label, #c.chunks, #c.bands))
      return { ok = true, id = o.id, chunks = #c.chunks, bands = #c.bands }
    end
    if type(msg.pieces) ~= "table" or #msg.pieces == 0 then return { error = "an order needs pieces" } end
    local o = { id = L.nextOrder, label = tostring(msg.label or "order"), kind = tostring(msg.kind or "run"),
                created = os.time() }
    L.nextOrder = L.nextOrder + 1
    o.group = "order-" .. o.id
    for _, p in ipairs(msg.pieces) do
      L.addJob(tostring(p.cmd), p.target or "any", p.timeout or msg.timeout, o.group, o.id, p.label)
    end
    L.orders[#L.orders + 1] = o
    local i = 1
    while #L.orders > 30 and i <= #L.orders do
      if L.campaigns[L.orders[i].id] then i = i + 1 else table.remove(L.orders, i) end
    end
    L.note(("order %d: %s (%d pieces)"):format(o.id, o.label, #msg.pieces))
    return { ok = true, id = o.id }
  end

  -- orders with progress: counts per state and the pieces (who does what)
  function H.orders(msg)
    local out = {}
    for i = #L.orders, 1, -1 do
      local o = L.orders[i]
      if not msg.id or tonumber(msg.id) == o.id then
        local counts, pieces = { queued = 0, running = 0, done = 0, failed = 0, lost = 0 }, {}
        for _, j in ipairs(L.jobs) do
          if j.order == o.id then
            counts[j.state] = (counts[j.state] or 0) + 1
            pieces[#pieces + 1] = { id = j.id, label = j.label, target = j.target, node = j.node, state = j.state,
                                    rc = j.rc, started = j.started, finished = j.finished,
                                    out = msg.id and j.out or nil }
          end
        end
        local total = #pieces
        if not msg.id and #pieces > 40 then
          -- list mode: the work in hand first, at most 40 (an order with hundreds of pieces stays small)
          local keep = {}
          for _, p in ipairs(pieces) do if p.state == "running" then keep[#keep + 1] = p end end
          for _, p in ipairs(pieces) do if #keep < 40 and p.state ~= "running" and p.state ~= "done" then keep[#keep + 1] = p end end
          pieces = { table.unpack(keep, 1, math.min(#keep, 40)) }
        end
        local state = counts.queued + counts.running > 0 and "running" or
          ((counts.failed + counts.lost > 0) and "failed" or "done")
        local c = L.campaigns[o.id]
        if c then
          -- a campaign: progress counts bands of chunks; pieces lists only the work in hand
          local failedBands, active = 0, {}
          for _, ch in ipairs(c.chunks) do
            if ch.failed then failedBands = failedBands + (#c.bands - ch.band + 1) end
          end
          for _, p in ipairs(pieces) do
            if p.state == "running" or p.state == "queued" or (msg.id and p.state ~= "done") then active[#active + 1] = p end
          end
          total = L.campaignTotal(c)
          counts = { done = c.done, running = counts.running, queued = total - c.done - failedBands - counts.running,
                     failed = failedBands, lost = 0 }
          state = c.stopped and "stopped" or (c.done + failedBands >= total and (failedBands > 0 and "failed" or "done") or "running")
          pieces = active
        end
        out[#out + 1] = { id = o.id, label = o.label, kind = o.kind, created = o.created, total = total,
                          counts = counts, state = state, pieces = json.array(pieces) }
      end
    end
    return { ok = true, orders = json.array(out) }
  end

  -- handle one request (already decoded); joins use the enrollment window instead of the token
  function L.handle(msg)
    if type(msg) ~= "table" or type(msg.op) ~= "string" then return { error = "bad request" } end
    if msg.op ~= "join" and msg.token ~= L.conf.token then return { error = "wrong swarm token" } end
    local h = H[msg.op]
    if not h then return { error = "unknown op " .. msg.op } end
    local ok, res = pcall(h, msg)
    if not ok then return { error = "main node error: " .. tostring(res) } end
    return res
  end

  return L
end

---------------------------------------------------------------- drone base
-- A drone base is a swarm node with network tunnel cards: each tunnel (eth1, eth2, ...) is a private
-- link to one drone. The base gives each link the subnet 10.43.K.0/24 (it is 10.43.K.1), hands the
-- drone an address by DHCP, and relays the drone's swarm requests and network install to the main node.
function M.links()
  local out = {}
  local list = M.ifaces()
  -- the uplink is the interface on the swarm network (10.42.0.x); every other one is a drone link.
  -- Without a known uplink there are no links: handing out drone addresses on the swarm network
  -- itself would break it
  local uplink = M.findUplink()
  if not uplink then return out, nil end
  local k = 0
  for _, n in ipairs(list) do
    if n ~= uplink then
      k = k + 1
      out[#out + 1] = { iface = n, net = "10.43." .. k, ip = "10.43." .. k .. ".1" }
    end
  end
  return out, uplink
end

function M.setupBase()
  local links = M.links()
  local conf = { "# Shulker drone base: DHCP for the drones on the tunnel links", "port=0", "bind-interfaces",
                 "dhcp-leasefile=/tmp/base-dnsmasq.leases", "dhcp-authoritative" }
  for _, l in ipairs(links) do
    os.execute(("ip link set %s up; ip addr add %s/24 dev %s 2>/dev/null"):format(l.iface, l.ip, l.iface))
    conf[#conf + 1] = "interface=" .. l.iface
    conf[#conf + 1] = ("dhcp-range=%s.10,%s.60,255.255.255.0,12h"):format(l.net, l.net)
  end
  U.write(U.etcdir() .. "/base-dnsmasq.conf", table.concat(conf, "\n") .. "\n")
  return links
end

---------------------------------------------------------------- services
-- the DHCP server of the main node: hands out 10.42.0.100-250, the gateway address and a name server
function M.dnsmasqConf()
  return table.concat({
    "# Shulker Swarm DHCP (written by `swarm init`)",
    "interface=eth0", "bind-interfaces", "port=0",
    "dhcp-range=" .. M.SUBNET .. ".100," .. M.SUBNET .. ".250,255.255.255.0,12h",
    "dhcp-option=3," .. M.GATEWAY_IP, "dhcp-option=6,1.1.1.1",
    "dhcp-authoritative", "dhcp-leasefile=/tmp/dnsmasq.leases",
  }, "\n") .. "\n"
end

local function pidAlive(file)
  local pid = U.trim(U.read(file) or "")
  return pid ~= "" and os.execute("kill -0 " .. pid .. " 2>/dev/null") == true
end
M.pidAlive = pidAlive

-- start what this node's role needs (idempotent); used by `swarm` and the boot script
function M.startServices(conf)
  conf = conf or M.loadConf()
  local bin = U.home() .. "/bin/swarmd"
  local function start(what)
    local pidf = "/tmp/swarmd-" .. what .. ".pid"
    if pidAlive(pidf) then return end
    os.execute(("SHULKER_HOME=%s nohup %s %s >> /tmp/swarmd-%s.log 2>&1 < /dev/null & echo $! > %s")
      :format(U.q(U.home()), U.q(bin), what, what, pidf))
  end
  if conf.role == "main" then
    if not pidAlive("/tmp/swarm-dnsmasq.pid") then
      os.execute("dnsmasq -C " .. U.q(U.etcdir() .. "/swarm-dnsmasq.conf") .. " -x /tmp/swarm-dnsmasq.pid 2>> /tmp/swarmd-leader.log")
    end
    start("leader")
    if conf.work == "1" then start("worker") end
  elseif conf.role == "worker" then
    start("worker")
    if conf.base == "1" then
      local links = M.setupBase()
      if #links > 0 and not pidAlive("/tmp/base-dnsmasq.pid") then
        os.execute("dnsmasq -C " .. U.q(U.etcdir() .. "/base-dnsmasq.conf") .. " -x /tmp/base-dnsmasq.pid 2>> /tmp/swarmd-relay.log")
      end
      start("relay")
    end
  end
end

function M.stopServices()
  for _, what in ipairs({ "leader", "worker", "relay" }) do
    local pid = U.trim(U.read("/tmp/swarmd-" .. what .. ".pid") or "")
    if pid ~= "" then os.execute("kill " .. pid .. " 2>/dev/null") end
    os.remove("/tmp/swarmd-" .. what .. ".pid")
  end
  for _, f in ipairs({ "/tmp/swarm-dnsmasq.pid", "/tmp/base-dnsmasq.pid" }) do
    local pid = U.trim(U.read(f) or "")
    if pid ~= "" then os.execute("kill " .. pid .. " 2>/dev/null") end
  end
end

---------------------------------------------------------------- network install (the main node serves Shulker OS)
-- GET /join            a script for a stock Sedna computer: install Shulker OS from this node and join
-- GET /swarm/install.sh, /swarm/manifest.txt, /swarm/src/<path>   what the normal installer expects
M.HTTP_PORT = 80

-- manifest of the running install, built once (works for /opt/shulker and the data pack alike)
local manifestCache
local manifestKey
function M.manifest()
  local home = U.home()
  -- rebuilt whenever this computer's own Shulker OS changes (shulker update): a stale list would make
  -- every worker's update fail its checksums
  local key = (U.read(home .. "/manifest.txt") or "") .. (U.read(home .. "/VERSION") or "")
  if manifestCache and key == manifestKey then return manifestCache end
  manifestKey = key
  if not U.isdir(home) then manifestCache, M.osTokenCache = "", nil return "" end
  local list = U.capture("cd " .. U.q(home) .. " && find . -type f ! -name manifest.txt ! -name '*.tmp' | sed 's|^./||' | LC_ALL=C sort")
  local lines = { "version " .. U.trim(U.read(home .. "/VERSION") or U.VERSION) }
  for path in list:gmatch("[^\n]+") do
    local sum = (U.capture("sha256sum " .. U.q(home .. "/" .. path))):match("^(%x+)")
    local data = U.read(home .. "/" .. path)
    if sum and data then lines[#lines + 1] = sum .. " " .. #data .. " " .. path end
  end
  manifestCache = table.concat(lines, "\n") .. "\n"
  M.osTokenCache = require("shulker.pkg").sha256Text(manifestCache)
  return manifestCache
end

-- a fingerprint of the Shulker OS the main hands out: a worker whose own manifest.txt hashes to
-- something else is behind and updates itself (swarmd, automatic updates)
local tokenAt = 0
function M.osToken()
  if not M.osTokenCache or os.time() - tokenAt >= 10 then
    tokenAt = os.time()
    M.manifest()
  end
  return M.osTokenCache
end

function M.joinScript(leaderIp)
  return table.concat({
    "#!/bin/sh",
    "# Shulker Swarm network install, served by the main node " .. leaderIp,
    "set -e",
    "echo ':: installing Shulker OS from the swarm main node " .. leaderIp .. "'",
    "wget -qO- http://" .. leaderIp .. "/swarm/install.sh | SHULKER_REPO=http://" .. leaderIp .. " SHULKER_BRANCH=swarm sh",
    "mkdir -p /etc/shulker",
    "printf 'leader=" .. leaderIp .. "\\nport=" .. M.PORT .. "\\nrole=worker\\n' > /etc/shulker/swarm.conf",
    "chmod 600 /etc/shulker/swarm.conf",
    "[ -f /etc/shulker/setup.conf ] || printf 'role=worker\\nclaude=off\\n' > /etc/shulker/setup.conf",
    "/opt/shulker/bin/netcfg dhcp >/dev/null 2>&1 || true",
    "/opt/shulker/bin/swarm services",
    "echo ':: joined. This computer shows up in `swarm status` on the main node in a few seconds.'",
  }, "\n") .. "\n"
end

-- answer one HTTP request on an accepted connection
-- the main's copy of repository files (apps, kernel and system images) for the swarm
function M.cacheDir()
  local d = U.isdir("/data") and "/data/.shulker-cache" or "/tmp/shulker-cache"
  U.mkdir(d)
  return d
end
M.CACHE_TTL = 600

-- rel = "packages/..." or "linux/dist/...": the cached file | nil, "fetching" | "missing"
function M.cached(rel)
  local dir = M.cacheDir()
  local file = dir .. "/" .. rel:gsub("/", "__")
  local stamp = file .. ".time"
  local age = os.time() - (tonumber(U.read(stamp) or "") or 0)
  if U.exists(file) and age < M.CACHE_TTL then return file end
  if U.exists(file .. ".missing") and age < 60 then return nil, "missing" end
  -- a stale copy is still served while a fresh one is fetched in the background
  local busy = file .. ".fetching"
  local since = tonumber(U.read(busy) or "") or 0
  if os.time() - since > 300 then
    U.write(busy, tostring(os.time()))
    local pkg = require("shulker.pkg")
    local pc = pkg.conf()
    local url = (pc.swarm and pkg.DEFAULT_REPO or pc.repo) .. "/" .. (pc.swarm and "main" or pc.branch) .. "/" .. rel
    local get = pkg.verifiedTLS() and "curl -fsSL --max-time 600 -o %s.part %s" or "wget -q -T 60 -O %s.part %s"
    os.execute(("(rm -f %s.missing; if " .. get .. " 2>/dev/null; then mv %s.part %s; date +%%s > %s; " ..
      "else rm -f %s.part; date +%%s > %s; touch %s.missing; fi; rm -f %s) >/dev/null 2>&1 &")
      :format(U.q(file), U.q(file), U.q(url), U.q(file), U.q(file), U.q(stamp), U.q(file), U.q(stamp), U.q(file), U.q(busy)))
  end
  if U.exists(file) then return file end
  return nil, "fetching"
end

function M.sendFile(c, file)
  local f = io.open(file, "rb")
  if not f then return end
  local size = f:seek("end")
  f:seek("set", 0)
  c:settimeout(30)
  c:send(("HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"):format(size))
  while true do
    local chunk = f:read(16384)
    if not chunk then break end
    local i = 1
    while i <= #chunk do
      local n, err, last = c:send(chunk, i)
      if n then i = n + 1 elseif last and last >= i then i = last + 1 else f:close() return end
      if err == "closed" then f:close() return end
    end
  end
  f:close()
end

function M.serveHttp(c, leaderIp)
  c:settimeout(3)
  local request = c:receive("*l") or ""
  local host
  repeat
    local h = c:receive("*l")
    local v = h and h:match("^[Hh]ost:%s*([%d%.]+)")
    if v then host = v end
  until not h or h == ""
  leaderIp = host or leaderIp
  local path = request:match("^GET%s+(%S+)") or ""
  path = path:gsub("%?.*$", "")
  local body, ctype = nil, "text/plain"
  if path == "/join" then
    body = M.joinScript(leaderIp)
  elseif path == "/swarm/install.sh" then
    for _, candidate in ipairs({ U.home() .. "/share/install.sh" }) do body = U.read(candidate) if body then break end end
  elseif path == "/swarm/manifest.txt" then
    body = M.manifest()
  elseif path:match("^/swarm/packages/") or path:match("^/swarm/linux/dist/") then
    -- apps and Shulker Linux images: the main fetches them from GitHub once and keeps a copy, so the
    -- swarm does not hit the Internet Gateway from every computer at once. 503 = fetching, ask again
    local rel = path:sub(#"/swarm/" + 1)
    if rel:find("..", 1, true) or not rel:match("^[%w%._/%-]+$") then
      c:send("HTTP/1.0 404 Not Found\r\nContent-Length: 10\r\nConnection: close\r\n\r\nnot found\n")
      c:close()
      return
    end
    local file, state = M.cached(rel)
    if file then
      M.sendFile(c, file)
      c:close()
      return
    end
    local msg = state == "missing" and "not in the repository\n" or "fetching, try again in a moment\n"
    c:send(("HTTP/1.0 %s\r\nContent-Length: %d\r\nRetry-After: 3\r\nConnection: close\r\n\r\n%s")
      :format(state == "missing" and "404 Not Found" or "503 Service Unavailable", #msg, msg))
    c:close()
    return
  elseif path:match("^/swarm/src/") then
    local rel = path:sub(#"/swarm/src/" + 1)
    if not rel:find("%.%.") and M.manifest():find(" " .. rel:gsub("%p", "%%%0") .. "\n", 1) then
      body = U.read(U.home() .. "/" .. rel)
      ctype = "application/octet-stream"
    end
  end
  if body then
    c:send("HTTP/1.0 200 OK\r\nContent-Type: " .. ctype .. "\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n")
    local i = 1
    while i <= #body do
      local n = c:send(body, i, math.min(#body, i + 8191))
      if not n then break end
      i = n + 1
    end
  else
    c:send("HTTP/1.0 404 Not Found\r\nContent-Length: 10\r\nConnection: close\r\n\r\nnot found\n")
  end
  c:close()
end

---------------------------------------------------------------- formatting
function M.exitText(rc)
  rc = tonumber(rc)
  return rc and tostring(math.floor(rc)) or "?"
end

function M.age(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  return math.floor(seconds / 86400) .. "d"
end

return M
