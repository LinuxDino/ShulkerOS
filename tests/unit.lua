-- Host unit tests for the Shulker OS libraries (plain Lua 5.4, no luaposix needed).
--   lua5.4 tests/unit.lua
package.path = "src/lib/?.lua;" .. package.path
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp)
-- keep every test away from the real home directory
local env = { SHULKER_STATE = tmp .. "/state", SHULKER_ETC = tmp .. "/etc", SHULKER_NO_CROND = "1", HOME = tmp }
local realGetenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] end return realGetenv(k) end

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 print("  ok    " .. name)
  else fail = fail + 1 print("  FAIL  " .. name .. "\n        " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or "expected true", 2) end end

local json = require("shulker.json")
local http = require("shulker.http")
local api = require("shulker.api")
local tasks = require("shulker.tasks")
local jobs = require("shulker.jobs")
local tools = require("shulker.tools")
local U = require("shulker.util")
U.setColor(false)

print("json (" .. json.backend .. ")")
test("arrays, objects and empties round-trip", function()
  local v = json.decode('{"a":[],"b":{},"c":[1,2,{"d":null}],"e":"x\\ny\\u00e9\\ud83d\\ude00"}')
  eq(json.encode(v), '{"a":[],"b":{},"c":[1,2,{"d":null}],"e":"x\\nyé😀"}')
end)
test("keys are sorted (stable cache prefix)", function()
  eq(json.encode({ b = 1, a = 2, c = { z = true, y = false } }), '{"a":2,"b":1,"c":{"y":false,"z":true}}')
end)
test("integers stay integers, floats keep precision", function()
  eq(json.encode({ 1, 2.5, 1e20, -3 }), "[1,2.5,1e+20,-3]")
end)
test("control characters are escaped", function()
  eq(json.encode("a\1b\"c\\"), '"a\\u0001b\\"c\\\\"')
end)
test("decode errors don't throw", function()
  local v, err = json.decode("{bad")
  eq(v, nil) truthy(err)
end)
test("pure Lua decoder agrees", function()
  local s = '{"n":-1.5e3,"t":true,"f":false,"a":[[],{}],"s":"\\"q\\" \\/"}'
  local v = json._luaDecode(s)
  eq(v.n, -1500.0) eq(v.t, true) eq(v.s, '"q" /')
end)

print("http")
test("parses chunked responses split anywhere", function()
  local raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: 1\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
  for split = 1, #raw - 1 do
    local p = http.parser()
    local body, done, head = {}, false, nil
    for _, part in ipairs({ raw:sub(1, split), raw:sub(split + 1) }) do
      for _, e in ipairs(p:feed(part)) do
        if e[1] == "head" then head = e
        elseif e[1] == "data" then body[#body + 1] = e[2]
        elseif e[1] == "done" then done = true end
      end
    end
    eq(head[2], 200) eq(head[4]["x-a"], "1")
    eq(table.concat(body), "hello world", "split " .. split)
    truthy(done, "done at split " .. split)
  end
end)
test("content-length and 100 Continue", function()
  local p = http.parser()
  local ev = p:feed("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many\r\nContent-Length: 3\r\nRetry-After: 7\r\n\r\nabcEXTRA")
  eq(ev[1][2], 429) eq(ev[1][4]["retry-after"], "7") eq(ev[2][2], "abc") eq(ev[3][1], "done")
end)
test("close-delimited bodies end at eof", function()
  local p = http.parser()
  p:feed("HTTP/1.0 200 OK\r\n\r\nsome")
  truthy(p:eof())
  local q = http.parser()
  q:feed("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc")
  truthy(not q:eof(), "a short body is not complete")
end)
test("URLs", function()
  local u = http.parseurl("https://api.anthropic.com/v1/messages")
  eq(u.host, "api.anthropic.com") eq(u.port, 443) eq(u.path, "/v1/messages") eq(u.tls, true)
  u = http.parseurl("http://10.0.2.2:8080")
  eq(u.port, 8080) eq(u.path, "/") eq(u.tls, false)
end)
test("request text carries the headers and length", function()
  local t = http.requestText("POST", http.parseurl("https://h:8443/x"), { ["x-api-key"] = "k" }, "{}")
  truthy(t:find("^POST /x HTTP/1.1\r\nHost: h:8443\r\nx%-api%-key: k\r\nConnection: close\r\nContent%-Length: 2\r\n\r\n{}$"), t)
end)
test("CIDR check", function()
  truthy(http.inCidr("160.79.104.10", "160.79.104.0/23"))
  truthy(http.inCidr("160.79.105.255", "160.79.104.0/23"))
  truthy(not http.inCidr("160.79.106.1", "160.79.104.0/23"))
  truthy(not http.inCidr("6.6.6.6", "160.79.104.0/23"))
end)

print("api")
test("pinning: DNS outside Anthropic's range is ignored", function()
  local real = http.resolve
  local warned
  http.resolve = function() return { "6.6.6.6" } end
  eq(api.target(api.DEFAULTS, function(w) warned = w end), "160.79.104.10")
  truthy(warned and warned:find("6.6.6.6"))
  http.resolve = function() return { "160.79.105.7" } end
  eq(api.target(api.DEFAULTS), "160.79.105.7")
  http.resolve = function() return nil, "no dns" end
  eq(api.target(api.DEFAULTS), "160.79.104.10")
  local cfg = {} for k, v in pairs(api.DEFAULTS) do cfg[k] = v end
  cfg.api_url = "https://10.0.2.2:8443/v1/messages"
  eq(api.target(cfg), nil, "other hosts are not pinned")
  http.resolve = real
end)
test("SSE assembler rebuilds text, thinking and tool calls", function()
  local texts = {}
  local A = api.assembler({ on_text = function(t) texts[#texts + 1] = t end })
  local sse = api.sseParser()
  local stream = table.concat({
    'event: message_start\ndata: {"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":5}}}\n\n',
    ': ping\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}\n\n',
    'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi "}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"there"}}\n\n',
    'event: content_block_stop\ndata: {"type":"content_block_stop","index":1}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"read_file","input":{}}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"pa"}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"th\\":\\"/etc\\"}"}}\n\n',
    'event: content_block_stop\ndata: {"type":"content_block_stop","index":2}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"t2","name":"list_dir","input":{}}}\n\n',
    'event: content_block_stop\ndata: {"type":"content_block_stop","index":3}\n\n',
    'event: content_block_start\ndata: {"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"t3","name":"x","input":{}}}\n\n',
    'event: content_block_delta\ndata: {"type":"content_block_delta","index":4,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\": \\"unterminated"}}\n\n',
    'event: content_block_stop\ndata: {"type":"content_block_stop","index":4}\n\n',
    'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}\n\n',
    'event: message_stop\ndata: {"type":"message_stop"}\n\n',
  })
  -- feed in awkward pieces
  for i = 1, #stream, 7 do
    for _, ev in ipairs(sse:feed(stream:sub(i, i + 6))) do A:event(ev) end
  end
  truthy(A.done)
  local m = A.msg
  eq(m.stop_reason, "tool_use") eq(m.usage.output_tokens, 9) eq(m.usage.input_tokens, 5)
  eq(m.content[1].thinking, "hm") eq(m.content[1].signature, "SIG")
  eq(m.content[2].text, "Hi there") eq(table.concat(texts), "Hi there")
  eq(m.content[3].input.path, "/etc")
  eq(json.encode(m.content[4].input), "{}", "empty input stays an object")
  truthy(m.content[5]._invalid, "invalid tool JSON is flagged, not run")
end)
test("stream error events are reported", function()
  local A = api.assembler()
  A:event({ data = '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' })
  eq(A.errType, "overloaded_error")
end)
test("request body: adaptive thinking, effort, fallbacks, caching, no budget", function()
  local b = api.body(api.DEFAULTS, "sys", json.array({}), json.array({ { role = "user", content = "hi" } }))
  local s = json.encode(b)
  truthy(s:find('"thinking":{"display":"updates","type":"adaptive"}', 1, true), s)
  truthy(s:find('"output_config":{"effort":"medium"}', 1, true))
  truthy(s:find('"fallbacks":"default"', 1, true))
  truthy(s:find('"cache_control":{"type":"ephemeral"}', 1, true))
  truthy(s:find('"stream":true', 1, true))
  truthy(not s:find("budget_tokens", 1, true))
  truthy(not s:find("tool_choice", 1, true))
end)
test("options are validated", function()
  local c = {} for k, v in pairs(api.DEFAULTS) do c[k] = v end
  truthy(api.setOption(c, "model", "sonnet")) eq(c.model, "claude-sonnet-5-5")
  truthy(not api.setOption(c, "effort", "huge"))
  truthy(api.setOption(c, "auto", "on")) eq(c.auto, true)
  truthy(not api.setOption(c, "nope", "1"))
end)
test("key file is saved with mode 600", function()
  truthy(api.setKey("sk-ant-test 123\n"))
  eq(api.getKey(), "sk-ant-test123")
  local mode = U.trim((U.capture("stat -c %a " .. U.q(api.keyPath()))))
  eq(mode, "600")
  api.forgetKey()
  eq(U.exists(api.keyPath()), false)
end)

print("tasks")
test("todo.txt parse and format round-trip", function()
  for _, line in ipairs({ "(A) 2026-10-08 Build the reactor +base @overworld", "x 2026-10-09 2026-10-08 Craft cables pri:B",
                          "plain task", "x 2026-01-01 done no created" }) do
    eq(tasks.format(tasks.parse(line, 1)), line)
  end
  local t = tasks.parse("(B) 2026-10-08 Mine +ore @nether", 3)
  eq(t.pri, "B") eq(t.projects[1], "ore") eq(t.contexts[1], "nether")
end)
test("add, done, priority, edit, remove, archive", function()
  local a = tasks.add("!! Fix the leak")
  eq(a.pri, "A") eq(a.text, "Fix the leak")
  tasks.add("Craft cables +base", "low")
  tasks.add("Explore")
  truthy(tasks.update(2, { done = true }))
  truthy(tasks.update(3, { pri = "medium", text = "Explore the end" }))
  local sel = tasks.select("open")
  eq(#sel, 2) eq(sel[1].text, "Fix the leak") eq(sel[2].text, "Explore the end")
  eq(#tasks.select("+base"), 1)
  truthy(not tasks.update(9, { done = true }))
  truthy(not tasks.update(1, { pri = "urgent" }))
  eq(tasks.archive(), 1)
  eq(#tasks.select("all"), 2)
  truthy(tasks.remove(1))
  eq(tasks.select("all")[1].text, "Explore the end")
end)

print("jobs")
test("schedules", function()
  local now = os.time({ year = 2026, month = 10, day = 8, hour = 23, min = 55, sec = 10 })
  local spec, once = jobs.parseWhen("in 10m", now)
  eq(spec, "6 0 9 10 *") eq(once, true)
  spec = jobs.parseWhen("at 07:30", now) eq(spec, "30 7 9 10 *")
  eq(jobs.parseWhen("every 5m"), "*/5 * * * *")
  eq(jobs.parseWhen("every 2h"), "0 */2 * * *")
  eq(jobs.parseWhen("daily 09:15"), "15 9 * * *")
  eq(jobs.parseWhen("*/15 * * * 1-5"), "*/15 * * * 1-5")
  eq(jobs.parseWhen("61 * * * *"), nil)
  eq(jobs.parseWhen("every 90m"), nil)
  eq(jobs.parseWhen("soon"), nil)
end)
test("add writes the managed crontab block and keeps user lines", function()
  os.execute("mkdir -p " .. U.q(env.SHULKER_ETC .. "/crontabs"))
  U.write(env.SHULKER_ETC .. "/crontabs/" .. jobs.user(), "0 3 * * * /root/backup.sh\n")
  local j = assert(jobs.add({ when = "hourly", kind = "claude", command = "check the disk", allow = { "run_command" } }))
  eq(j.id, "j1")
  local tab = U.read(env.SHULKER_ETC .. "/crontabs/" .. jobs.user())
  truthy(tab:find("0 3 * * * /root/backup.sh", 1, true), tab)
  truthy(tab:find("0 * * * * " .. U.home() .. "/bin/shulker-job run j1", 1, true), tab)
  truthy(jobs.commandLine(j):find("--allow 'run_command'", 1, true))
  truthy(jobs.remove("j1"))
  tab = U.read(env.SHULKER_ETC .. "/crontabs/" .. jobs.user())
  truthy(not tab:find("run j1", 1, true) and tab:find("backup.sh", 1, true))
end)
test("a one-time shell job runs, logs and removes itself", function()
  local j = assert(jobs.add({ when = "in 5m", kind = "shell", command = "echo hello-job" }))
  local code, out = jobs.run(j.id)
  eq(code, 0) truthy(out:find("hello-job", 1, true), "output: " .. tostring(out))
  truthy(jobs.tail(j.id):find("hello-job", 1, true))
  eq(jobs.get(j.id), nil)
end)

print("tools")
local kit = tools.new()
test("every tool has a schema and an implementation", function()
  for _, t in ipairs(kit.TOOLS) do
    truthy(t.input_schema and t.input_schema.type == "object", t.name)
    eq(t.eager_input_streaming, true)
    truthy(kit.DEFS[t.name])
  end
  truthy(kit.RISKY.run_command and kit.RISKY.write_file and kit.RISKY.call_device and kit.RISKY.job_add)
  truthy(not kit.RISKY.read_file and not kit.RISKY.task_add)
end)
test("inputs are validated before running", function()
  local _, bad = kit.run("read_file", { path = 5 }) eq(bad, true)
  local text = kit.run("read_file", {})
  truthy(text:find("missing required field: path"))
  text = kit.run("list_dir", { path = ".", extra = 1 })
  truthy(text:find("unknown field"))
  text = kit.run("task_add", { text = "x", priority = "urgent" })
  truthy(text:find("must be one of"))
end)
test("write, read and edit files", function()
  local p = tmp .. "/f.txt"
  local text, err = kit.run("write_file", { path = p, content = "one\ntwo\ntwo\n" })
  eq(err, false, text)
  text = kit.run("read_file", { path = p })
  truthy(text:find("     2\ttwo"), text)
  text, err = kit.run("edit_file", { path = p, old_text = "two", new_text = "2" })
  eq(err, true) truthy(text:find("occurs 2 times"))
  text, err = kit.run("edit_file", { path = p, old_text = "two", new_text = "2", replace_all = true })
  eq(err, false, text)
  eq(U.read(p), "one\n2\n2\n")
  text = kit.run("read_file", { path = p, offset = 2, limit = 1 })
  truthy(text:find("lines 2%-2 of 3"), text)
end)
test("run_command reports the exit code and stops at the timeout", function()
  local text = kit.run("run_command", { command = "echo out; echo err >&2; exit 3" })
  truthy(text:find("^exit code 3") and text:find("out") and text:find("err"), text)
  text = kit.run("run_command", { command = "sleep 5", timeout_seconds = 1 })
  truthy(text:find("stopped after 1 s"), text)
end)
test("task tools", function()
  local text = kit.run("task_add", { text = "From Claude", priority = "high" })
  truthy(text:find("added #%d+: %(A%)"), text)
  truthy(kit.run("task_list", {}):find("From Claude"))
end)
test("describe() gives readable approval lines", function()
  eq(kit.describe("run_command", { command = "rm -rf /tmp/x" }), "$ rm -rf /tmp/x")
  truthy(kit.describe("write_file", { path = tmp .. "/new.txt", content = "abc" }):find("create .- %(3 bytes%)"))
end)

print("chat")
test("non-interactive sessions refuse risky tools and keep history valid", function()
  local chat = require("shulker.chat")
  local S = chat.new({ interactive = false, quiet = true })
  eq(S:approve("run_command", { command = "id" }), "noninteractive")
  S.allow.run_command = true
  eq(S:approve("run_command", { command = "id" }), "allow")
  S.msgs[1] = { role = "user", content = "x" }
  S:rollback(0)
  eq(#S.msgs, 0)
end)

print("swarm")
test("leader: enrollment, names, heartbeats, jobs, map, requeue", function()
  local S = require("shulker.swarm")
  local L = S.newLeader({ token = "t0k" })
  local function st(mac) return { mac = mac, ip = "10.42.0." .. #mac, host = "h" } end
  truthy(L.handle({ op = "join", stats = st("aa") }).error, "closed enrollment refuses")
  L.enrollUntil = os.time() + 60
  local j1 = L.handle({ op = "join", stats = st("aa") })
  eq(j1.name, "node1") eq(j1.token, "t0k")
  eq(L.handle({ op = "join", stats = st("bb") }).name, "node2")
  eq(L.handle({ op = "join", stats = st("aa") }).name, "node1", "rejoin keeps the name")
  truthy(L.handle({ op = "status", token = "bad" }).error, "token is checked")
  local sub = L.handle({ op = "submit", token = "t0k", cmd = "echo {}", map = json.array({ "x", "y y" }) })
  eq(#sub.ids, 2)
  local h1 = L.handle({ op = "heartbeat", token = "t0k", stats = st("aa") })
  eq(h1.job.cmd, "echo 'x'")
  local h2 = L.handle({ op = "heartbeat", token = "t0k", stats = st("bb") })
  eq(h2.job.cmd, "echo 'y y'")
  eq(L.handle({ op = "heartbeat", token = "t0k", stats = st("aa"), running = h1.job.id }).job, nil, "busy nodes get no more work")
  L.handle({ op = "heartbeat", token = "t0k", stats = st("aa"), results = json.array({ { id = h1.job.id, rc = 0, out = "x\n" } }) })
  local jobs = L.handle({ op = "jobs", token = "t0k", full = true }).jobs
  eq(jobs[1].state, "done") eq(jobs[1].out, "x\n") eq(jobs[1].node, "node1")
  -- node2 vanishes: its job is queued again and node1 takes it
  for _, n in pairs(L.nodes) do if n.name == "node2" then n.seen = os.time() - 100 end end
  L.reap()
  eq(L.job(h2.job.id).state, "queued")
  eq(L.handle({ op = "heartbeat", token = "t0k", stats = st("aa") }).job.id, h2.job.id)
  local all = L.handle({ op = "submit", token = "t0k", cmd = "uptime", target = "all" })
  eq(#all.ids, 1, "only online nodes get an 'all' job")
  local status = L.handle({ op = "status", token = "t0k" })
  eq(#status.nodes, 2) eq(status.nodes[1].name, "node1")
end)

test("orders: words, mine planning, parse", function()
  local O = require("shulker.orders")
  local w = O.words([[map 'echo {} done' a "b c"]])
  eq(#w, 4) eq(w[2], "echo {} done") eq(w[4], "b c")
  -- 16 x 4 x 16 = 1024 blocks, 3 drones: 4 slices of 4 columns (about 256 blocks each)
  local pieces, vol = O.planMine({ 0, 60, 0, 15, 57, 15 }, 3)
  eq(vol, 1024) eq(#pieces, 4)
  eq(pieces[1].cmd, "drone mine 0 60 0 3 57 15") eq(pieces[4].cmd, "drone mine 12 60 0 15 57 15")
  eq(pieces[1].target, "drone")
  -- more drones than blocks along the axis: one slice per column, never empty slices
  local p2 = O.planMine({ 0, 0, 0, 2, 0, 0 }, 8)
  eq(#p2, 3)
  -- uneven: 10 columns over 3 drones -> 4 + 3 + 3
  local p3 = O.planMine({ 0, 0, 0, 9, 0, 0 }, 3, 1000)
  eq(p3[1].cmd, "drone mine 0 0 0 3 0 0") eq(p3[3].cmd, "drone mine 7 0 0 9 0 0")
  local status = { nodes = { { name = "node1", online = true, stats = {} },
                             { name = "drone1", online = true, stats = { drone = { charge = 80 } } } } }
  local o = O.parse("home all", status)
  eq(#o.pieces, 1) eq(o.pieces[1].target, "drone1")
  eq(#O.parse("run on all uptime", status).pieces, 2)
  eq(O.parse("map 'echo {}' 1 2 3", status).pieces[3].cmd, "echo '3'")
  truthy(select(2, O.parse("mine 1 2 3", status)), "mine needs six numbers")
  truthy(select(2, O.parse("fly", status)), "unknown commands are refused")
end)

test("leader: orders go to free drones, progress, stop", function()
  local S = require("shulker.swarm")
  local L = S.newLeader({ token = "t" })
  L.enrollUntil = os.time() + 60
  local function st(mac, drone) return { mac = mac, ip = "10.42.0.9", drone = drone } end
  L.handle({ op = "join", stats = st("c1") })
  L.handle({ op = "join", stats = st("d1", { charge = 90 }) })
  L.handle({ op = "join", stats = st("d2", { charge = 10 }) })
  local r = L.handle({ op = "order", token = "t", label = "mine", pieces = json.array({
    { cmd = "drone mine 0 0 0 1 0 0", target = "drone", label = "a" },
    { cmd = "drone mine 2 0 0 3 0 0", target = "drone", label = "b" } }) })
  eq(r.id, 1)
  eq(L.handle({ op = "heartbeat", token = "t", stats = st("c1") }).job, nil, "computers never take drone pieces")
  eq(L.handle({ op = "heartbeat", token = "t", stats = st("d2", { charge = 10 }) }).job, nil, "a flat drone charges first")
  local h = L.handle({ op = "heartbeat", token = "t", stats = st("d1", { charge = 90 }) })
  eq(h.job.cmd, "drone mine 0 0 0 1 0 0")
  local o = L.handle({ op = "orders", token = "t" }).orders[1]
  eq(o.total, 2) eq(o.counts.running, 1) eq(o.counts.queued, 1) eq(o.state, "running")
  -- stop: the queued piece is dropped, the running one is stopped on its drone
  L.handle({ op = "cancel", token = "t", order = 1, stop = true })
  local h2 = L.handle({ op = "heartbeat", token = "t", stats = st("d1", { charge = 90 }), running = h.job.id })
  eq(h2.stop[1], h.job.id)
  L.handle({ op = "heartbeat", token = "t", stats = st("d1", { charge = 90 }),
             results = json.array({ { id = h.job.id, rc = 143, out = "stopped" } }) })
  o = L.handle({ op = "orders", token = "t" }).orders[1]
  eq(o.state, "failed") eq(o.counts.queued, 0)
  -- a drone that vanishes mid-piece: the piece goes to another drone
  local r2 = L.handle({ op = "order", token = "t", label = "m2", pieces = json.array({ { cmd = "x", target = "drone" } }) })
  local h3 = L.handle({ op = "heartbeat", token = "t", stats = st("d1", { charge = 90 }) })
  eq(L.job(h3.job.id).order, r2.id)
  for _, n in pairs(L.nodes) do if n.name == "drone1" then n.seen = os.time() - 100 end end
  L.reap()
  eq(L.job(h3.job.id).state, "queued")
  eq(L.handle({ op = "heartbeat", token = "t", stats = st("d2", { charge = 60 }) }).job.id, h3.job.id)
end)

os.execute("rm -rf " .. U.q(tmp))
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
