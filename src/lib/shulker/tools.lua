-- Claude's tools on Sedna Linux, and the system prompt.
--   local kit = require("shulker.tools").new()
--   kit.TOOLS           JSON array for the request (built once, so the request prefix stays cacheable)
--   kit.RISKY[name]     true: ask the user first (Allow / Always / Deny) unless auto mode
--   kit.run(name, input) -> text, isError
--   kit.describe(name, input) -> one line for the approval prompt and the transcript
--   kit.system          the system prompt (no times or other changing data: it is cached)
local json = require("shulker.json")
local U = require("shulker.util")
local tasks = require("shulker.tasks")
local jobs = require("shulker.jobs")
local devices = require("shulker.devices")

local M = {}

local MAX_OUT = 12000

local function obj(props, required)
  return { type = "object", properties = json.object(props or {}), required = json.array(required or {}),
           additionalProperties = false }
end
local STR = function(d) return { type = "string", description = d } end
local INT = function(d) return { type = "integer", description = d } end
local BOOL = function(d) return { type = "boolean", description = d } end

M.LIST = {
  { name = "run_command", risky = true,
    description = "Run a shell command on this Sedna Linux computer (BusyBox ash) and get its output (stdout and stderr together) and exit code. The working directory is the user's current directory. Commands run without a terminal: don't start interactive programs (nano, vi, top, less). Long output is cut in the middle.",
    input_schema = obj({ command = STR("shell command line"),
                         timeout_seconds = INT("optional, default 60, at most 600") }, { "command" }) },
  { name = "read_file",
    description = "Read a text file. Lines come back numbered (like cat -n). For big files read a part with offset and limit.",
    input_schema = obj({ path = STR("file path"), offset = INT("optional: first line, from 1"),
                         limit = INT("optional: number of lines, default 400") }, { "path" }) },
  { name = "write_file", risky = true,
    description = "Create or overwrite a text file with the given content. Parent directories are created. The root disk is only 8 MB, so keep files small.",
    input_schema = obj({ path = STR("file path"), content = STR("the complete new file content") }, { "path", "content" }) },
  { name = "edit_file", risky = true,
    description = "Replace exact text in a file. old_text must occur exactly once (include enough surrounding lines to make it unique), unless replace_all is true.",
    input_schema = obj({ path = STR("file path"), old_text = STR("text to find, exactly as in the file"),
                         new_text = STR("replacement text"), replace_all = BOOL("optional: replace every occurrence") },
                       { "path", "old_text", "new_text" }) },
  { name = "list_dir",
    description = "List a directory (like ls -la).",
    input_schema = obj({ path = STR("directory, default the current directory") }) },
  { name = "system_info",
    description = "This computer's status: kernel, uptime, memory, disk space, network addresses, Shulker OS version, running services.",
    input_schema = obj() },
  { name = "network_info",
    description = "Network diagnostics: interfaces and addresses, routes, name servers, /etc/network/interfaces, and a ping to the default gateway. Use it when the internet doesn't work.",
    input_schema = obj() },
  { name = "list_devices",
    description = "List the OpenComputers II devices on this computer's device bus (redstone interfaces, file import/export card, energy storage, inventories, projectors, ... from any mod) with their IDs and type names.",
    input_schema = obj() },
  { name = "device_methods",
    description = "Show the methods of one bus device (with parameters and descriptions). device is a device ID or a type name from list_devices.",
    input_schema = obj({ device = STR("device ID or type name") }, { "device" }) },
  { name = "call_device", risky = true,
    description = "Call a method on a bus device and get its return values (as JSON). device is a device ID or type name.",
    input_schema = obj({ device = STR("device ID or type name"), method = STR("method name"),
                         args = { type = "array", description = "arguments, optional", items = json.object({}) } },
                       { "device", "method" }) },
  { name = "task_list",
    description = "Show the user's task list (todo.txt). filter: open (default), done, all, or a word / +project / @context to search for.",
    input_schema = obj({ filter = STR("optional") }) },
  { name = "task_add",
    description = "Add a task to the user's task list. Use +project and @context words in the text when they fit.",
    input_schema = obj({ text = STR("the task"), priority = { type = "string", enum = json.array({ "high", "medium", "low", "none" }) } },
                       { "text" }) },
  { name = "task_update",
    description = "Change a task by its number: mark it done or not done, change its priority or its text.",
    input_schema = obj({ id = INT("task number"), done = BOOL("optional"),
                         priority = { type = "string", enum = json.array({ "high", "medium", "low", "none" }) },
                         text = STR("optional new text") }, { "id" }) },
  { name = "task_remove", risky = true,
    description = "Delete a task by its number (the numbers of later tasks shift down by one).",
    input_schema = obj({ id = INT("task number") }, { "id" }) },
  { name = "job_list",
    description = "List scheduled jobs (run by crond): id, schedule, kind, name, last run and exit code.",
    input_schema = obj() },
  { name = "job_add", risky = true,
    description = "Schedule a job: a shell command, or a Claude agent prompt (kind claude: you run later with `claude -p`, without the user present, so only the tools listed in allow are permitted). when: 'in 10m', 'at 14:30', 'every 5m', 'every 2h', 'daily 09:00', 'hourly', 'weekly', or a cron spec like '*/15 * * * *' (times are this computer's clock, usually UTC). Output goes to a log the user can review with `task job log <id>`.",
    input_schema = obj({ when = STR("schedule"), kind = { type = "string", enum = json.array({ "shell", "claude" }) },
                         command = STR("shell command, or the prompt for kind claude"),
                         name = STR("short name"),
                         allow = { type = "array", items = { type = "string" }, description = "kind claude: risky tools the job may use without asking, e.g. [\"run_command\"]" } },
                       { "when", "kind", "command", "name" }) },
  { name = "job_remove", risky = true,
    description = "Remove a scheduled job by id.",
    input_schema = obj({ id = STR("job id, e.g. j1") }, { "id" }) },
  { name = "job_log",
    description = "Read the end of a scheduled job's output log.",
    input_schema = obj({ id = STR("job id"), lines = INT("optional, default 40") }, { "id" }) },
  { name = "swarm_status",
    description = "The Shulker Swarm this computer belongs to: every computer (online, load, memory, disk, current job, alerts), every drone (battery, world position, modules, base), and the orders with their progress and pieces. Use it before answering anything about the swarm, the nodes or the drones.",
    input_schema = obj({ order = INT("optional: one order's details, with each piece's output") }) },
  { name = "swarm_order", risky = true,
    description = "Give the swarm an order; the main computer splits it into pieces that computers or drones work on at the same time. command is one of: 'mine X1 Y1 Z1 X2 Y2 Z2' (dig a box with all free drones, world coordinates), 'home all' or 'home DRONE...' (drones back to their chargers), 'go DRONE X Y Z', 'run on all CMD' / 'run on NAME CMD' / 'run CMD' (shell command on every / one / any free computer), \"map 'CMD {}' ITEM...\" (one piece per item on free computers). Returns the order number; follow it with swarm_status.",
    input_schema = obj({ command = STR("the order, e.g. mine 100 60 200 115 57 215") }, { "command" }) },
  { name = "swarm_stop", risky = true,
    description = "Stop an order: queued pieces are dropped and running ones are ended (drones stop where they are).",
    input_schema = obj({ order = INT("order number") }, { "order" }) },
  { name = "monitor_status",
    description = "Sensors and alarms on this computer (Shulker monitor): energy storage percent, redstone inputs, comparator, furnace, memory, disk, drone battery, swarm offline count, the active alerts and the alert rules.",
    input_schema = obj() },
}

---------------------------------------------------------------- system prompt
M.SYSTEM = [[
You are Claude, the assistant built into Shulker OS, on an OpenComputers II computer in Minecraft. The user reads you on an 80x24 terminal.

Answer style, always:
- Short. Most answers are 1 to 5 lines. No greeting, no restating the question, no summary at the end, no offers of further help.
- Do the work with the tools, then report the result in a line or two. Don't announce what you are about to do or narrate each tool call.
- Plain text: no headings, no tables, no bold. Commands on their own indented line. Lists only when there really are several items.
- If something is unclear, ask one short question instead of guessing.

The machine: a RISC-V computer running Sedna Linux (Linux 6.6, BusyBox ash, Lua 5.4 with cjson, luasocket, luaposix; nano). No bash, python3, git or apt. Shulker drives have the Shulker Linux kernel (RAID, ext4) and mdadm; MicroPython and tcc may be removed. The system disk is 8 MB with about 1 MB free: keep files small and check df before writing much. /tmp is RAM. The CPU is slow. Big storage, if set up, is /data (RAID over the other drives).

Shulker OS (each command has a man page):
- Swarm: one main computer (10.42.0.1) hands out addresses, keeps the list of computers and runs orders. Workers ("Lab" computers, node1, node2, ...) join it and run jobs. Drones are OC2 robots (drone1, ...) linked by a tunnel card to a drone base (a Lab computer with up to 3 tunnel cards, `swarm base`); they report battery and position, go home to charge below 15-20 %, and use world coordinates once `drone origin X Y Z` is set. Orders: mine, home, go, run, map (swarm_order); computers never take drone pieces and drones never take computer pieces. The user's screen for all this is `control` (Control Center); `swarm status`, `swarm drones`, `swarm orders`, `swarm top` in the shell.
- Updates and apps: the main updates from GitHub (`shulker update`), every other member updates from the main (`swarm run --on all shulker update`). `shulker mkdisk` on a spare computer writes ready Lab or Robot drives. `shulker disks setup` makes /data. `shulker linux kernel` installs the RAID kernel.
- monitor: sensors and alarm rules (redstone alarms); dashboard: status wall on a projector; desktop: full-screen launcher; task: to-do list and scheduled jobs; netcfg: network; sshctl: SSH.
- The internet goes through one Internet Gateway (reached at 10.42.0.254 in a swarm). HTTPS through BusyBox wget does not verify certificates.

How to work:
- Look before you answer about this computer or the swarm: swarm_status, monitor_status, system_info, list_devices. Don't guess names, coordinates or numbers.
- To make the swarm or drones do something, use swarm_order (the main splits the work). Use run_command only for this computer.
- In-game blocks on this computer's bus: list_devices, device_methods, call_device.
- Risky tools ask the user first; if they deny, don't retry the same way.
- Change the task list only when the user asks.]]

---------------------------------------------------------------- helpers
local function str(v, default)
  if v == nil or v == json.null then return default end
  return tostring(v)
end
local function num(v, default)
  v = (v ~= json.null) and tonumber(v) or nil
  return v and math.floor(v) or default
end

local function freeKB(path)
  local out = U.capture("df -k " .. U.q(path) .. " 2>/dev/null | tail -n 1")
  local fields = {}
  for w in out:gmatch("%S+") do fields[#fields + 1] = w end
  return tonumber(fields[4] or "")
end

local function dirname(p) return p:match("^(.*)/[^/]*$") or "." end

-- the input must match the schema (eager input streaming means the API doesn't check it for us)
function M.validate(def, input)
  if type(input) ~= "table" or json.isarray(input) then return "input must be an object" end
  local props = def.input_schema.properties or {}
  for _, r in ipairs(def.input_schema.required or {}) do
    if input[r] == nil or input[r] == json.null then return "missing required field: " .. r end
  end
  for k, v in pairs(input) do
    local p = props[k]
    if not p then return "unknown field: " .. tostring(k) end
    if v ~= json.null then
      local t = p.type
      if t == "string" and type(v) ~= "string" then return k .. " must be a string" end
      if t == "integer" and math.type(v) ~= "integer" and not (type(v) == "number" and v == math.floor(v)) then return k .. " must be an integer" end
      if t == "boolean" and type(v) ~= "boolean" then return k .. " must be true or false" end
      if t == "array" and type(v) ~= "table" then return k .. " must be an array" end
      if p.enum then
        local okE = false
        for _, e in ipairs(p.enum) do if e == v then okE = true end end
        if not okE then return k .. " must be one of " .. table.concat(p.enum, ", ") end
      end
    end
  end
end

---------------------------------------------------------------- tool implementations
local RUN = {}

function RUN.run_command(i)
  local t = math.min(math.max(num(i.timeout_seconds, 60), 1), 600)
  local out, code = U.capture(("timeout %d sh -c %s </dev/null"):format(t, U.q(i.command)))
  if code == 143 or code == 124 then out = out .. ("\n(stopped after %d s)"):format(t) end
  return ("exit code %d\n%s"):format(code, U.clip(out, MAX_OUT)), false
end

function RUN.read_file(i)
  local path = str(i.path)
  if U.isdir(path) then return path .. " is a directory (use list_dir)", true end
  local f = io.open(path, "rb")
  if not f then return "cannot open " .. path, true end
  local first = math.max(num(i.offset, 1), 1)
  local limit = math.min(math.max(num(i.limit, 400), 1), 2000)
  local out, n, size, total = {}, 0, 0, 0
  for line in f:lines() do
    n = n + 1
    if n >= first and #out < limit and size < MAX_OUT then
      out[#out + 1] = ("%6d\t%s"):format(n, line)
      size = size + #line + 8
    end
    total = n
  end
  f:close()
  if total == 0 then return "(empty file)", false end
  local text = table.concat(out, "\n")
  local last = first + #out - 1
  if first > 1 or last < total then text = text .. ("\n(lines %d-%d of %d)"):format(first, last, total) end
  if text:find("[%z\1-\8\14-\31]") and not text:find("\27") then text = "(this looks like a binary file)\n" .. text:sub(1, 400) end
  return text, false
end

function RUN.write_file(i)
  local path, content = str(i.path), str(i.content, "")
  U.mkdir(dirname(path))
  local free = freeKB(dirname(path))
  local old = U.read(path)
  local grow = #content - (old and #old or 0)
  if free and grow > 0 and (free - grow / 1024) < 64 then
    return ("not enough disk space: %d KB free, the file needs %d KB and 64 KB must stay free"):format(free, math.ceil(grow / 1024)), true
  end
  local ok, err = U.write(path, content)
  if not ok then return "write failed: " .. tostring(err), true end
  return ("%s %s (%d bytes)"):format(old and "overwrote" or "created", path, #content), false
end

function RUN.edit_file(i)
  local path = str(i.path)
  local s = U.read(path)
  if not s then return "cannot read " .. path, true end
  local old, new = str(i.old_text, ""), str(i.new_text, "")
  if old == "" then return "old_text is empty", true end
  local count, from = 0, 1
  while true do
    local a, b = s:find(old, from, true)
    if not a then break end
    count = count + 1
    from = b + 1
  end
  if count == 0 then return "old_text was not found in " .. path .. " (read the file again: it must match exactly)", true end
  if count > 1 and i.replace_all ~= true then
    return ("old_text occurs %d times in %s; add more context or set replace_all"):format(count, path), true
  end
  local out, pos, done = {}, 1, 0
  while true do
    local a, b = s:find(old, pos, true)
    if not a or (done >= 1 and i.replace_all ~= true) then break end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = new
    pos = b + 1
    done = done + 1
  end
  out[#out + 1] = s:sub(pos)
  local ok, err = U.write(path, table.concat(out))
  if not ok then return "write failed: " .. tostring(err), true end
  return ("edited %s: %d replacement%s"):format(path, done, done == 1 and "" or "s"), false
end

function RUN.list_dir(i)
  local p = str(i.path, ".")
  local out, code = U.capture("ls -la " .. U.q(p))
  return U.clip(out, MAX_OUT), code ~= 0
end

function RUN.system_info()
  local cmds = {
    "uname -a", "uptime", "free -k", "df -k / /tmp", "ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}'",
    "cat " .. U.q(U.home() .. "/VERSION") .. " 2>/dev/null | sed 's/^/Shulker OS /'",
    "echo SHULKER_HOME=" .. U.q(U.home()),
    "pidof crond >/dev/null && echo 'crond: running' || echo 'crond: stopped'",
    "pidof dropbear >/dev/null && echo 'ssh (dropbear): running' || echo 'ssh (dropbear): stopped'",
    "pidof lua >/dev/null; ls /run/oc2busd.pid >/dev/null 2>&1 && echo 'oc2busd: running' || echo 'oc2busd: not running'",
  }
  local out = {}
  for _, c in ipairs(cmds) do out[#out + 1] = (U.capture(c)) end
  return table.concat(out), false
end

function RUN.network_info()
  local cmds = {
    "echo '# ip addr'; ip addr", "echo '# ip route'; ip route",
    "echo '# /etc/resolv.conf'; cat /etc/resolv.conf 2>&1",
    "echo '# /etc/network/interfaces'; cat /etc/network/interfaces 2>&1",
    "gw=$(ip route | awk '/^default/ {print $3; exit}'); if [ -n \"$gw\" ]; then echo \"# ping $gw\"; ping -c 1 -W 3 $gw 2>&1 | tail -n 2; else echo '# no default route (run netcfg)'; fi",
  }
  local out = {}
  for _, c in ipairs(cmds) do out[#out + 1] = (U.capture(c)) end
  return U.clip(table.concat(out), MAX_OUT), false
end

function RUN.list_devices()
  local list, err = devices.list()
  if not list then return err, true end
  if #list == 0 then return "(no devices on the bus)", false end
  local out = {}
  for _, d in ipairs(list) do out[#out + 1] = d.id .. "  " .. table.concat(d.types, ", ") end
  return table.concat(out, "\n"), false
end

function RUN.device_methods(i)
  local m, id = devices.methods(str(i.device))
  if not m then return id, true end
  return ("device %s\n%s"):format(id, devices.describeMethods(m)), false
end

function RUN.call_device(i)
  local args = {}
  if type(i.args) == "table" then for k, v in ipairs(i.args) do args[k] = v end end
  local res, err = devices.invoke(str(i.device), str(i.method), args)
  if not res then return err, true end
  local vals = json.array({})
  for k = 1, res.n do vals[k] = res[k] == nil and json.null or res[k] end
  local ok, text = pcall(json.encode, vals)
  return ok and U.clip(text, MAX_OUT) or tostring(res[1]), false
end

function RUN.task_list(i)
  return tasks.plain(tasks.select(str(i.filter, "open"))), false
end

function RUN.task_add(i)
  local t, err = tasks.add(str(i.text), str(i.priority))
  if not t then return err, true end
  return ("added #%d: %s"):format(t.id, tasks.format(t)), false
end

function RUN.task_update(i)
  local changes = {}
  if type(i.done) == "boolean" then changes.done = i.done end
  if i.priority ~= nil and i.priority ~= json.null then changes.pri = i.priority end
  if i.text ~= nil and i.text ~= json.null then changes.text = i.text end
  local t, err = tasks.update(num(i.id), changes)
  if not t then return err, true end
  return ("#%d is now: %s"):format(num(i.id), tasks.format(t)), false
end

function RUN.task_remove(i)
  local t, err = tasks.remove(num(i.id))
  if not t then return err, true end
  return "removed: " .. t.text, false
end

function RUN.job_list()
  return jobs.plain(jobs.load()), false
end

function RUN.job_add(i)
  local allow = {}
  if type(i.allow) == "table" then for _, t in ipairs(i.allow) do allow[#allow + 1] = tostring(t) end end
  local j, err = jobs.add({ when = str(i.when), kind = str(i.kind), command = str(i.command), name = str(i.name),
                            allow = allow, by = "claude" })
  if not j then return err, true end
  return ("scheduled %s: %s (%s, cron '%s')"):format(j.id, j.name, j.when, j.schedule), false
end

function RUN.job_remove(i)
  local j, err = jobs.remove(str(i.id))
  if not j then return err, true end
  return "removed job " .. j.id .. ": " .. j.name, false
end

function RUN.job_log(i)
  local text = jobs.tail(str(i.id), math.min(num(i.lines, 40), 200))
  if text == "" then return "(no output logged yet for " .. str(i.id) .. ")", false end
  return U.clip(text, MAX_OUT), false
end

---------------------------------------------------------------- swarm and monitor
local function swarmCall(msg)
  local S = require("shulker.swarm")
  local conf = S.loadConf()
  if not conf.role then return nil, "this computer is not in a swarm (swarm init on the main, or a Lab drive)" end
  if conf.role == "main" then conf.leader = "127.0.0.1" end
  return S.call(conf, msg, 10)
end

function RUN.swarm_status(i)
  local oid = num(i.order, nil)
  if oid then
    local r, err = swarmCall({ op = "orders", id = oid })
    if not r then return err, true end
    local o = r.orders[1]
    if not o then return "no order " .. oid, true end
    local out = { ("order %d: %s, %s, %d/%d done"):format(o.id, o.label, o.state, o.counts.done or 0, o.total) }
    for _, p in ipairs(o.pieces) do
      out[#out + 1] = ("  %s %s on %s%s"):format(p.state, p.label or "", p.node or p.target or "?", p.rc and (" exit " .. p.rc) or "")
      if p.out and p.out ~= "" then out[#out + 1] = "    " .. U.clip((tostring(p.out):gsub("%s+$", "")), 300):gsub("\n", "\n    ") end
    end
    return U.clip(table.concat(out, "\n"), MAX_OUT), false
  end
  local st, err = swarmCall({ op = "status" })
  if not st then return err, true end
  local out = { ("main %s; %d queued, %d running jobs; gateway %s"):format(tostring(st.leader and st.leader.ip or "10.42.0.1"),
    st.queued or 0, st.running or 0, tostring(st.gateway)) }
  out[#out + 1] = "computers:"
  local drones = {}
  for _, n in ipairs(st.nodes or {}) do
    local x = n.stats or {}
    if type(x.drone) == "table" then drones[#drones + 1] = n else
      out[#out + 1] = ("  %s %s %s load %.2f mem %d/%dK free, disk %sK free%s%s%s"):format(n.name, n.ip or "?",
        n.online and (n.busy and ("busy job " .. n.busy) or "idle") or "OFFLINE", tonumber(x.load) or 0,
        tonumber(x.mem_free) or 0, tonumber(x.mem_total) or 0, tostring(x.disk_free or "?"),
        n.main and " (main)" or "", x.energy and (" energy " .. x.energy .. "%") or "",
        (tonumber(x.alerts) or 0) > 0 and (" ALERTS " .. x.alerts) or "")
    end
  end
  out[#out + 1] = "drones:"
  if #drones == 0 then out[#out + 1] = "  none" end
  for _, n in ipairs(drones) do
    local d = n.stats.drone
    local p = d.pos and ("%d %d %d%s"):format(d.pos.x or 0, d.pos.y or 0, d.pos.z or 0, d.world and "" or " (relative: no origin set)") or "?"
    out[#out + 1] = ("  %s via %s %s battery %s%% at %s facing %s modules %s"):format(n.name, n.via or "?",
      n.online and (n.busy and ("busy job " .. n.busy) or "idle") or "OFFLINE", tostring(d.charge or "?"), p,
      tostring(d.facing or "?"), table.concat(type(d.modules) == "table" and d.modules or {}, ","))
  end
  local o = swarmCall({ op = "orders" })
  out[#out + 1] = "orders:"
  if not o or #o.orders == 0 then out[#out + 1] = "  none" end
  for k, x in ipairs(o and o.orders or {}) do
    if k > 8 then break end
    out[#out + 1] = ("  #%d %s: %s, %d/%d done, %d running, %d failed"):format(x.id, x.label, x.state,
      x.counts.done or 0, x.total, x.counts.running or 0, (x.counts.failed or 0) + (x.counts.lost or 0))
  end
  return U.clip(table.concat(out, "\n"), MAX_OUT), false
end

function RUN.swarm_order(i)
  local O = require("shulker.orders")
  local st, err = swarmCall({ op = "status" })
  if not st then return err, true end
  local o, perr = O.parse(str(i.command, ""), st)
  if not o then return perr, true end
  local r, oerr = swarmCall({ op = "order", label = o.label, kind = o.kind, pieces = o.pieces })
  if not r then return oerr, true end
  return ("order %d started: %s (%d pieces%s)"):format(r.id, o.label, #o.pieces, o.note and ("; " .. o.note) or ""), false
end

function RUN.swarm_stop(i)
  local r, err = swarmCall({ op = "cancel", order = num(i.order, 0), stop = true })
  if not r then return err, true end
  return ("order %d: %d piece(s) stopped"):format(num(i.order, 0), r.cancelled), false
end

function RUN.monitor_status()
  local mon = require("shulker.monitor")
  local st = mon.state(20)
  local sensors = st and st.sensors or mon.read()
  local out = { st and "monitor daemon: running" or "monitor daemon: not running (values read now)" }
  local names = {}
  for k in pairs(sensors) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    local v = sensors[k]
    out[#out + 1] = ("  %s = %s%s%s"):format(k, tostring(v.value), v.unit or "", v.label and (" (" .. v.label .. ")") or "")
  end
  out[#out + 1] = "alerts: " .. ((st and #(st.alerts or {}) > 0) and "" or "none")
  for _, a in ipairs(st and st.alerts or {}) do out[#out + 1] = ("  %s: %s = %s"):format(a.name, a.sensor, tostring(a.value)) end
  out[#out + 1] = "rules:"
  for _, r in ipairs(mon.load().rules) do out[#out + 1] = ("  %s: %s %s %s -> %s"):format(r.name, r.sensor, r.op, r.value, r.action) end
  return U.clip(table.concat(out, "\n"), MAX_OUT), false
end

---------------------------------------------------------------- descriptions for the approval prompt
local function short(s, n)
  s = tostring(s or ""):gsub("%s+", " ")
  n = n or 60
  if #s > n then return s:sub(1, n - 3) .. "..." end
  return s
end

function M.describe(name, i)
  i = type(i) == "table" and i or {}
  if name == "run_command" then return "$ " .. short(i.command, 200) end
  if name == "write_file" then
    local old = U.read(str(i.path, ""))
    return ("%s %s (%d bytes%s)"):format(old and "overwrite" or "create", str(i.path), #str(i.content, ""),
      old and (", was " .. #old) or "")
  end
  if name == "edit_file" then
    return ("edit %s: %q -> %q"):format(str(i.path), short(i.old_text, 40), short(i.new_text, 40))
  end
  if name == "call_device" then
    local ok, a = pcall(json.encode, type(i.args) == "table" and i.args or json.array({}))
    return ("%s.%s(%s)"):format(str(i.device), str(i.method), ok and short(a:sub(2, -2), 60) or "")
  end
  if name == "job_add" then
    return ("[%s] %s: %s%s"):format(str(i.when), str(i.kind), short(i.command, 120),
      (type(i.allow) == "table" and #i.allow > 0) and ("  (may use: " .. table.concat(i.allow, ", ") .. ")") or "")
  end
  if name == "job_remove" then
    local j = jobs.get(str(i.id, ""))
    return "remove job " .. str(i.id) .. (j and (": " .. j.name) or "")
  end
  if name == "task_remove" then return "delete task #" .. str(i.id) end
  if name == "swarm_order" then return "swarm order: " .. short(i.command, 150) end
  if name == "swarm_stop" then return "stop swarm order #" .. str(i.order) end
  local ok, enc = pcall(json.encode, i)
  return ok and short(enc, 100) or name
end

---------------------------------------------------------------- the kit
function M.new()
  local list, risky, defs = {}, {}, {}
  for _, t in ipairs(M.LIST) do
    risky[t.name] = t.risky == true
    defs[t.name] = t
    list[#list + 1] = { name = t.name, description = t.description, input_schema = t.input_schema,
                        eager_input_streaming = true }
  end
  local kit = { TOOLS = json.array(list), RISKY = risky, DEFS = defs, system = M.SYSTEM, describe = M.describe }
  function kit.run(name, input)
    local def = defs[name]
    if not def then return "unknown tool " .. tostring(name), true end
    local bad = M.validate(def, input)
    if bad then return "invalid input: " .. bad, true end
    local ok, a, b = pcall(RUN[name], input)
    if not ok then return "tool failed: " .. tostring(a), true end
    return a, b
  end
  return kit
end

return M
