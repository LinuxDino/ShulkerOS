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
M.HEARTBEAT = 3                    -- seconds between worker heartbeats
M.DEAD_AFTER = 15                  -- a node not heard from for this long is shown as offline
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

function M.ip()
  local out = U.capture("ip -4 -o addr show eth0 2>/dev/null")
  return out:match("inet (%d+%.%d+%.%d+%.%d+)")
end

-- a small status report: what the leader and the dashboards show
function M.stats()
  local meminfo = U.read("/proc/meminfo") or ""
  local total = tonumber(meminfo:match("MemTotal:%s*(%d+)")) or 0
  local avail = tonumber(meminfo:match("MemAvailable:%s*(%d+)")) or 0
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
  local ok, err = c:connect(conf.leader or M.LEADER_IP, conf.port or M.PORT)
  if not ok then c:close() return nil, ("cannot reach the main node %s:%s (%s)"):format(conf.leader, conf.port, err) end
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
-- jobs:   list of { id, cmd, target = "any"|"all"|name, node, state = queued|running|done|failed|lost,
--                   rc, out, created, started, finished, timeout, group }
function M.newLeader(conf)
  local L = { conf = conf, nodes = {}, jobs = {}, nextJob = 1, enrollUntil = 0, log = {}, mainMac = M.mac() }

  local statePath = (os.getenv("SHULKER_SWARM_STATE") or "/tmp/swarm-state.json")
  local function save()
    local nodes = {}
    for _, n in pairs(L.nodes) do nodes[#nodes + 1] = { name = n.name, mac = n.mac, joined = n.joined } end
    U.write(statePath, json.encode({ nodes = json.array(nodes), enrollUntil = L.enrollUntil }))
    -- the node list must survive reboots of the main node: keep it next to the config
    U.write(U.etcdir() .. "/swarm-nodes.json", json.encode(json.array(nodes)), "600")
  end
  L.save = save

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

  local function nodeName()
    local used = {}
    for _, n in pairs(L.nodes) do used[n.name] = true end
    for i = 1, 999 do if not used["node" .. i] then return "node" .. i end end
  end

  local function online(n) return os.time() - (n.seen or 0) <= M.DEAD_AFTER end
  L.online = online

  function L.addJob(cmd, target, timeout, group)
    local j = { id = L.nextJob, cmd = cmd, target = target or "any", state = "queued", created = os.time(),
                timeout = math.min(tonumber(timeout) or 600, 3600), group = group }
    L.nextJob = L.nextJob + 1
    L.jobs[#L.jobs + 1] = j
    -- keep the last 200 jobs
    while #L.jobs > 200 do table.remove(L.jobs, 1) end
    return j
  end

  function L.job(id)
    for _, j in ipairs(L.jobs) do if j.id == tonumber(id) then return j end end
  end

  -- a node asks for work: its own jobs first, then "any" jobs
  local function pick(n)
    if n.busy then return nil end
    for _, j in ipairs(L.jobs) do
      if j.state == "queued" and j.target == n.name then return j end
    end
    for _, j in ipairs(L.jobs) do
      if j.state == "queued" and j.target == "any" then return j end
    end
  end

  -- jobs whose node vanished are queued again (once) or marked lost
  function L.reap()
    for _, j in ipairs(L.jobs) do
      if j.state == "running" then
        local n
        for _, x in pairs(L.nodes) do if x.name == j.node then n = x end end
        local overdue = j.started and os.time() - j.started > j.timeout + 60
        if not n or not online(n) or overdue then
          if j.target == "any" and not j.retried then
            j.state, j.node, j.retried = "queued", nil, true
            L.note(("job %d requeued (%s went away)"):format(j.id, tostring(n and n.name)))
          else
            j.state = "lost"
            j.finished = os.time()
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
      n = { name = nodeName(), mac = mac, joined = os.date("%Y-%m-%d %H:%M") }
      L.nodes[mac] = n
      L.note(n.name .. " joined (" .. tostring(msg.stats and msg.stats.ip) .. ")")
      save()
    end
    n.seen, n.stats, n.ip = os.time(), msg.stats, msg.stats and msg.stats.ip
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
    n.seen, n.stats, n.ip = now, msg.stats, msg.stats.ip
    -- results of finished jobs
    for _, r in ipairs(msg.results or {}) do
      local j = L.job(r.id)
      if j and j.state == "running" and j.node == n.name then
        j.state = (tonumber(r.rc) == 0) and "done" or "failed"
        j.rc, j.out, j.finished = tonumber(r.rc), tostring(r.out or ""):sub(-M.MAX_OUTPUT), os.time()
      end
      if n.busy == tonumber(r.id) then n.busy = nil end
    end
    if msg.running then n.busy = tonumber(msg.running) else n.busy = nil end
    local reply = { ok = true, name = n.name }
    local j = pick(n)
    if j then
      j.state, j.node, j.started = "running", n.name, os.time()
      n.busy = j.id
      reply.job = { id = j.id, cmd = j.cmd, timeout = j.timeout }
    end
    return reply
  end

  function H.status()
    local nodes = {}
    for _, n in pairs(L.nodes) do
      nodes[#nodes + 1] = { name = n.name, mac = n.mac, ip = n.ip, online = online(n), busy = n.busy,
                            seen = n.seen and (os.time() - n.seen) or nil, stats = n.stats,
                            rx_rate = n.rxRate, tx_rate = n.txRate, main = n.mac == L.mainMac }
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
             enrolling = math.max(0, L.enrollUntil - os.time()), log = json.array(L.log) }
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
                          rc = j.rc, out = msg.full and j.out or nil, created = j.created, started = j.started,
                          finished = j.finished }
      end
    end
    return { ok = true, jobs = json.array(out) }
  end

  function H.enroll(msg)
    L.enrollUntil = os.time() + math.min(tonumber(msg.seconds) or 1800, 24 * 3600)
    L.note("accepting new nodes for " .. math.floor((L.enrollUntil - os.time()) / 60) .. " min")
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

  function H.cancel(msg)
    local n = 0
    for _, j in ipairs(L.jobs) do
      if j.state == "queued" and (msg.all or j.id == tonumber(msg.id)) then j.state = "failed" j.out = "cancelled" n = n + 1 end
    end
    return { ok = true, cancelled = n }
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
  end
end

function M.stopServices()
  for _, what in ipairs({ "leader", "worker" }) do
    local pid = U.trim(U.read("/tmp/swarmd-" .. what .. ".pid") or "")
    if pid ~= "" then os.execute("kill " .. pid .. " 2>/dev/null") end
    os.remove("/tmp/swarmd-" .. what .. ".pid")
  end
  local pid = U.trim(U.read("/tmp/swarm-dnsmasq.pid") or "")
  if pid ~= "" then os.execute("kill " .. pid .. " 2>/dev/null") end
end

---------------------------------------------------------------- network install (the main node serves Shulker OS)
-- GET /join            a script for a stock Sedna computer: install Shulker OS from this node and join
-- GET /swarm/install.sh, /swarm/manifest.txt, /swarm/src/<path>   what the normal installer expects
M.HTTP_PORT = 80

-- manifest of the running install, built once (works for /opt/shulker and the data pack alike)
local manifestCache
function M.manifest()
  if manifestCache then return manifestCache end
  local home = U.home()
  local list = U.capture("cd " .. U.q(home) .. " && find . -type f ! -name manifest.txt ! -name '*.tmp' | sed 's|^./||' | LC_ALL=C sort")
  local lines = { "version " .. U.trim(U.read(home .. "/VERSION") or U.VERSION) }
  for path in list:gmatch("[^\n]+") do
    local sum = (U.capture("sha256sum " .. U.q(home .. "/" .. path))):match("^(%x+)")
    local data = U.read(home .. "/" .. path)
    if sum and data then lines[#lines + 1] = sum .. " " .. #data .. " " .. path end
  end
  manifestCache = table.concat(lines, "\n") .. "\n"
  return manifestCache
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
function M.serveHttp(c, leaderIp)
  c:settimeout(3)
  local request = c:receive("*l") or ""
  repeat local h = c:receive("*l") until not h or h == ""
  local path = request:match("^GET%s+(%S+)") or ""
  path = path:gsub("%?.*$", "")
  local body, ctype = nil, "text/plain"
  if path == "/join" then
    body = M.joinScript(leaderIp)
  elseif path == "/swarm/install.sh" then
    for _, candidate in ipairs({ U.home() .. "/share/install.sh" }) do body = U.read(candidate) if body then break end end
  elseif path == "/swarm/manifest.txt" then
    body = M.manifest()
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
function M.age(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  return math.floor(seconds / 86400) .. "d"
end

return M
