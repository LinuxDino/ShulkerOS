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
  truthy(s:find('"thinking":{"display":"omitted","type":"adaptive"}', 1, true), s)
  truthy(s:find('"output_config":{"effort":"low"}', 1, true))
  local c2 = {}
  for k, v in pairs(api.DEFAULTS) do c2[k] = v end
  c2.thinking, c2.effort = "updates", "high"
  local s2 = json.encode(api.body(c2, "sys", json.array({}), json.array({ { role = "user", content = "hi" } })))
  truthy(s2:find('"thinking":{"display":"updates","type":"adaptive"}', 1, true), s2)
  truthy(s2:find('"output_config":{"effort":"high"}', 1, true))
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

test("storage: inventories, tanks, find, swarm find (fake bus)", function()
  local devices = require("shulker.devices")
  local realList, realBus = devices.list, devices.bus
  local slots = {
    chest = { { id = "minecraft:diamond", count = 5 }, false, { id = "minecraft:iron_ingot", count = 64 } },
    me = { { id = "minecraft:diamond", count = 100 }, { id = "mekanism:ingot_osmium", count = 7 } },
  }
  devices.list = function() return {
    { id = "chest", types = { "item_handler" } },
    { id = "me", types = { "item_handler", "storage_me" } },
    { id = "tank", types = { "fluid_handler" } },
    { id = "cell", types = { "energy_storage" } } } end
  local fakeBus = { invoke = function(_, id, m, a1)
    if m == "getItemSlotCount" then return #slots[id] end
    if m == "getItemStackInSlot" then local st = slots[id][a1 + 1] return st or nil end
    if m == "getFluidTankCount" then return 1 end
    if m == "getFluidInTank" then return { id = "minecraft:water", amount = 4000 } end
    if m == "getFluidTankCapacity" then return 16000 end
  end }
  devices.bus = function() return fakeBus end
  package.loaded["shulker.storage"] = nil
  local ST = require("shulker.storage")
  local inv = ST.list()
  eq(#inv.items, 2) eq(inv.items[1].name, "inventory 1") eq(inv.items[2].name, "storage_me", "custom names win")
  eq(#inv.fluids, 1) eq(#inv.energy, 1)
  local r = ST.scanItems("chest")
  eq(r.slots, 3) eq(r.used, 2) eq(r.total, 69) eq(r.items["minecraft:diamond"], 5)
  local f = ST.scanFluids("tank")
  eq(f.amount, 4000) eq(f.capacity, 16000) eq(f.tanks[1].fluid, "minecraft:water")
  local found = ST.find("diamond")
  eq(#found, 1) eq(found[1].count, 105) eq(#found[1].where, 2)
  eq(#ST.find("mekanism:"), 1)
  eq(ST.short("minecraft:diamond_ore"), "diamond ore") eq(ST.short("mekanism:ingot_osmium"), "mekanism:ingot osmium")
  truthy(ST.matches("minecraft:diamond_ore", "diamond ore"))
  -- swarm find: two computers answer, one drone is skipped
  local submitted = {}
  local outs = {
    node1 = json.encode({ host = "node1", found = json.array({ { item = "minecraft:diamond", count = 105 } }) }),
    node2 = "noise\n" .. json.encode({ host = "node2", found = json.array({ { item = "minecraft:diamond", count = 3 } }) }),
  }
  local function call(msg)
    if msg.op == "status" then return { nodes = {
      { name = "node1", online = true, stats = {} }, { name = "node2", online = true, stats = {} },
      { name = "drone1", online = true, stats = { drone = { charge = 50 } } } } } end
    if msg.op == "submit" then submitted[#submitted + 1] = msg.target return { ids = { #submitted } } end
    if msg.op == "jobs" then
      local js = {}
      for i, t in ipairs(submitted) do js[#js + 1] = { id = i, node = t, state = "done", out = outs[t] } end
      return { jobs = js }
    end
  end
  local real = os.execute
  os.execute = function(c) if c == "sleep 2" then return true end return real(c) end
  local res = ST.swarmFind(call, "diamond")
  os.execute = real
  eq(#submitted, 2, "drones are not asked") eq(res.answered, 2) eq(res.list[1].count, 108)
  devices.list, devices.bus = realList, realBus
end)

test("clear: chunk coordinates, campaign pieces, ownership, retries, restart", function()
  local O = require("shulker.orders")
  local st = { nodes = { { name = "drone1", online = true, stats = { drone = { charge = 90 } } } } }
  local o = O.parse("clear chunks 10 -3 25 80 -59", st)
  eq(o.kind, "clear") eq(o.campaign.x1, 160) eq(o.campaign.z1, -48) eq(o.campaign.x2, 559) eq(o.campaign.z2, 351)
  eq(o.campaign.top, 80) eq(o.campaign.bottom, -59)
  truthy(o.note:find("625 chunks", 1, true), o.note)
  local o2 = O.parse("clear chunks 0 0 1 1 64 60", st)
  eq(o2.campaign.x2, 31) eq(o2.campaign.z2, 31)
  local o3 = O.parse("clear 5 5 20 7", st)
  eq(o3.campaign.top, O.DEFAULT_TOP) eq(o3.campaign.bottom, O.DEFAULT_BOTTOM)
  truthy(select(2, O.parse("clear chunks 1 2", st)), "too few numbers are refused")

  local S = require("shulker.swarm")
  os.remove(U.etcdir() .. "/swarm-campaigns.json")
  local L = S.newLeader({ token = "t" })
  L.enrollUntil = os.time() + 60
  local function dr(mac, charge) return { mac = mac, ip = "10.43.1.9", drone = { charge = charge or 90 } } end
  L.handle({ op = "join", stats = dr("d1") })
  L.handle({ op = "join", stats = dr("d2") })
  L.handle({ op = "join", stats = { mac = "c1", ip = "10.42.0.9" } })
  -- 2 x 1 chunks (x 0..31, z 0..15), y 64..55: two bands of 9 and 1 layer
  local r = L.handle({ op = "order", token = "t", label = "clear test", campaign = { x1 = 0, z1 = 0, x2 = 31, z2 = 15, top = 64, bottom = 55 } })
  eq(r.chunks, 2) eq(r.bands, 2)
  eq(L.handle({ op = "heartbeat", token = "t", stats = { mac = "c1", ip = "x" } }).job, nil, "computers get no clear pieces")
  local h1 = L.handle({ op = "heartbeat", token = "t", stats = dr("d1") })
  eq(h1.job.cmd, "drone clear 0 64 0 15 56 15")
  local h2 = L.handle({ op = "heartbeat", token = "t", stats = dr("d2") })
  eq(h2.job.cmd, "drone clear 16 64 0 31 56 15", "the second drone gets the other chunk")
  -- d1 finishes its band: it gets the next band of the same chunk
  local h1b = L.handle({ op = "heartbeat", token = "t", stats = dr("d1"), results = json.array({ { id = h1.job.id, rc = 0, out = "ok" } }) })
  eq(h1b.job.cmd, "drone clear 0 55 0 15 55 15")
  local ord = L.handle({ op = "orders", token = "t" }).orders[1]
  eq(ord.total, 4) eq(ord.counts.done, 1) eq(ord.state, "running")
  -- d2 fails: its chunk goes back to the pool and the next free drone takes the same band
  L.handle({ op = "heartbeat", token = "t", stats = dr("d2"), results = json.array({ { id = h2.job.id, rc = 1, out = "stuck" } }) })
  local h1c = L.handle({ op = "heartbeat", token = "t", stats = dr("d1"), results = json.array({ { id = h1b.job.id, rc = 0, out = "ok" } }) })
  eq(h1c.job.cmd, "drone clear 16 64 0 31 56 15", "a failed band is done again by another drone")
  -- the main restarts: the campaign comes back, the band in hand is handed out again
  local L2 = S.newLeader({ token = "t" })
  L2.enrollUntil = os.time() + 60
  L2.handle({ op = "join", stats = dr("d1") })
  local ord2 = L2.handle({ op = "orders", token = "t" }).orders[1]
  eq(ord2.total, 4) eq(ord2.counts.done, 2)
  eq(L2.handle({ op = "heartbeat", token = "t", stats = dr("d1") }).job.cmd, "drone clear 16 64 0 31 56 15")
  -- stop: no more pieces
  L2.handle({ op = "cancel", token = "t", order = ord2.id, stop = true })
  L2.handle({ op = "join", stats = dr("d2") })
  eq(L2.handle({ op = "heartbeat", token = "t", stats = dr("d2") }).job, nil, "a stopped campaign hands out nothing")
  eq(L2.handle({ op = "orders", token = "t" }).orders[1].state, "stopped")
  os.remove(U.etcdir() .. "/swarm-campaigns.json")
end)

-- a simulated OC2 robot: world of blocks, 12 slots, pickaxe wear, trash can, the module APIs drone.lua uses
local function simRobot(opts)
  local W = { solid = {}, pos = { x = 0, y = 0, z = 0 }, facing = "north", dropped = 0, inv = {}, sel = 0,
              digs = 0, trashed = 0, clock = 0, cd = 0, energy = 1000, flat = false, trips = 0 }
  local function key(x, y, z) return x .. "," .. y .. "," .. z end
  for x = opts.box[1], opts.box[4] do for y = opts.box[2], opts.box[5] do for z = opts.box[3], opts.box[6] do
    W.solid[key(x, y, z)] = "minecraft:stone"
  end end end
  for i, st in pairs(opts.inv) do W.inv[i] = st end
  local D = { north = { 0, -1 }, south = { 0, 1 }, east = { 1, 0 }, west = { -1, 0 } }
  local ORDER = { "north", "east", "south", "west" }
  local function target(side)
    local p = W.pos
    if side == "up" or side == "upward" then return p.x, p.y + 1, p.z end
    if side == "down" or side == "downward" then return p.x, p.y - 1, p.z end
    local d = D[W.facing]
    if side == "backward" then return p.x - d[1], p.y, p.z - d[2] end
    return p.x + d[1], p.y, p.z + d[2]
  end
  local function insert(id)
    for k = 1, 12 do
      local s = (W.sel + k) % 12
      local st = W.inv[s]
      if not st then W.inv[s] = { id = id, count = 1 } return end
      if st.id == id and st.count < 64 and not st.tool then st.count = st.count + 1 return end
    end
    W.dropped = W.dropped + 1
  end
  local robot = {
    position = function() return { x = W.pos.x, y = W.pos.y, z = W.pos.z } end,
    facing = function() return W.facing end,
    energy = function() return W.energy end, capacity = function() return 1000 end,
    slot = function(v) if v then W.sel = v end return W.sel end,
    stack = function(s) local st = W.inv[s or W.sel] return st and { id = st.id, count = st.count } or nil end,
    detect = function(side) return W.solid[key(target(side))] ~= nil end,
    turn = function(dir)
      local i
      for k, v in ipairs(ORDER) do if v == W.facing then i = k end end
      W.facing = ORDER[(i - 1 + (dir == "right" and 1 or -1)) % 4 + 1]
      return true
    end,
    move = function(dir)
      if W.energy <= 0 then W.flat = true return false end
      local x, y, z = target(dir)
      if W.solid[key(x, y, z)] then return false end
      W.pos = { x = x, y = y, z = z }
      W.tick(1)                                   -- OC2: one block per second
      return true
    end,
  }
  local blockOps = {
    excavate = function(_, side)
      if W.clock < W.cd then return false end     -- OC2: refused during the cooldown
      W.cd = W.clock + 1
      local x, y, z = target(side or "front")
      local b = W.solid[key(x, y, z)]
      if not b then return false end
      local tool = W.inv[W.sel]
      if not tool or not tool.tool or tool.dur <= 0 then return false end
      tool.dur = tool.dur - 1
      if tool.dur <= 0 then W.inv[W.sel] = nil end
      W.solid[key(x, y, z)] = nil
      W.digs = W.digs + 1
      insert(b == "minecraft:stone" and "minecraft:cobblestone" or b)
      return true
    end,
    place = function(_, side)
      if W.clock < W.cd then return false end
      W.cd = W.clock + 1
      local st = W.inv[W.sel]
      local x, y, z = target(side or "front")
      if not st or st.tool or W.solid[key(x, y, z)] then return false end
      W.solid[key(x, y, z)] = st.id
      st.count = st.count - 1
      if st.count == 0 then W.inv[W.sel] = nil end
      return true
    end,
    durability = function() local t = W.inv[W.sel] return t and t.tool and t.dur or nil end,
  }
  local invOps = {
    getItemSlotCount = function(_, side)
      local b = W.solid[key(target(side or "front"))]
      return (b == "trashcans:trash_can" or b == "minecraft:chest") and 27 or 0
    end,
    drop = function(_, count, side)
      local st = W.inv[W.sel]
      if not st then return 0 end
      local n = math.min(count, st.count)
      local x, y, z = target(side or "front")
      local b = W.solid[key(x, y, z)]
      if b == "trashcans:trash_can" or b == "minecraft:chest" then W.trashed = W.trashed + n
      else W.dropped = W.dropped + n end
      st.count = st.count - n
      if st.count == 0 then W.inv[W.sel] = nil end
      return n
    end,
  }
  local mods = { block_operations = blockOps, inventory_operations = invOps }
  local devices = require("shulker.devices")
  devices.bus = function() return { find = function(_, name) return mods[name] end } end
  package.loaded["robot"] = robot
  package.loaded["shulker.drone"] = nil
  -- battery: 1000 lasts 1500 s (OC2: ~25 min); the charger under home (0 0 0) fills it fast
  W.tick = function(sec)
    W.clock = W.clock + sec
    if W.pos.x == 0 and W.pos.y == 0 and W.pos.z == 0 then
      if W.energy < 900 and W.clock > 5 then W.charged = true end
      W.energy = math.min(1000, W.energy + 200 * sec)
    else
      W.energy = math.max(0, W.energy - (1000 / 1500) * sec)
    end
  end
  local Dr = require("shulker.drone")
  Dr.sleep = function(sec) W.tick(sec) end
  Dr.now = function() return W.clock end
  W.box = opts.box
  W.remaining = function()
    local n = 0
    for x = opts.box[1], opts.box[4] do for y = opts.box[2], opts.box[5] do for z = opts.box[3], opts.box[6] do
      if W.solid[key(x, y, z)] and W.solid[key(x, y, z)] ~= "trashcans:trash_can" then n = n + 1 end
    end end end
    return n
  end
  return W, Dr
end

test("drone clear far from its charger: turns back in time, never runs flat", function()
  local realBus = require("shulker.devices").bus
  -- the box is 300 blocks out: the trip home alone eats ~20 % of a charge
  -- 1,200 blocks need more than one charge: it must fly home and come back
  local W, Dr = simRobot({ box = { 300, -3, -18, 309, 2, 1 }, inv = {
    [0] = { id = "minecraft:netherite_pickaxe", count = 1, tool = true, dur = 100000 },
    [1] = { id = "trashcans:trash_can", count = 1 } } })
  local n, err = Dr.clear(300, -3, -18, 309, 2, 1, {})
  eq(err, nil) eq(n, 1200) eq(W.remaining(), 0)
  eq(W.flat, false, "it never ran out of power")
  truthy(W.charged, "it went home to charge in the middle of the job")
  truthy(W.energy > 0)
  require("shulker.devices").bus = realBus
  package.loaded["robot"] = nil
  package.loaded["shulker.drone"] = nil
end)

test("drone clear (simulated robot): every block, nothing on the ground, dump block, spare pickaxe", function()
  local realBus = require("shulker.devices").bus
  -- 10 x 6 x 10 box (600 blocks: the inventory fills several times); a worn pickaxe, a spare, a trash can
  local W, Dr = simRobot({ box = { 2, -6, -12, 11, -1, -3 }, inv = {
    [0] = { id = "minecraft:diamond_pickaxe", count = 1, tool = true, dur = 60 },
    [1] = { id = "trashcans:trash_can", count = 1 },
    [2] = { id = "minecraft:netherite_pickaxe", count = 1, tool = true, dur = 5000 } } })
  local n, err = Dr.clear(2, -6, -12, 11, -1, -3, {})
  eq(err, nil) eq(n, 600)
  eq(W.remaining(), 0, "every block of the box is gone")
  local rate = 600 / W.clock * 3600
  print(("        (simulated: 600 blocks in %.0f s = %.0f blocks/hour)"):format(W.clock, rate))
  truthy(rate > 1800 and rate < 4000, "speed fits the estimate (about 2,400/h)")
  eq(W.dropped, 0, "nothing was dropped on the ground")
  truthy(W.trashed > 0, "the trash can was used")
  local sl = Dr.slots()
  truthy(sl.dump ~= nil, "the trash can came back into the inventory")
  eq(#sl.tools, 2, "the worn pickaxe is kept (repairable), not broken")
  truthy(W.inv[0].dur <= 8 and W.inv[0].dur > 0, "it stopped using the worn one in time")
  truthy(W.inv[2].dur < 5000, "the spare took over")
  -- without a dump block and without a chest at home it stops instead of littering
  local W2, Dr2 = simRobot({ box = { 1, 0, -12, 10, 5, -3 }, inv = {
    [0] = { id = "minecraft:netherite_pickaxe", count = 1, tool = true, dur = 5000 } } })
  local n2, err2 = Dr2.clear(1, 0, -12, 10, 5, -3, {})
  eq(n2, nil) truthy(tostring(err2):find("chest north of its charger"), err2)
  eq(W2.dropped, 0, "nothing littered at home")
  -- with a chest north of the charger it empties there and finishes
  local W3, Dr3b = simRobot({ box = { 1, 0, -12, 10, 5, -3 }, inv = {
    [0] = { id = "minecraft:netherite_pickaxe", count = 1, tool = true, dur = 5000 } } })
  W3.solid["0,0,-1"] = "minecraft:chest"
  local n3b, err3b = Dr3b.clear(1, 0, -12, 10, 5, -3, {})
  eq(err3b, nil) eq(n3b, 600) eq(W3.remaining(), 0) eq(W3.dropped, 0) truthy(W3.trashed > 0)
  eq(W3.solid["0,0,-1"], "minecraft:chest", "the chest next to the charger is never dug up")
  eq(W3.pos.x .. "," .. W3.pos.z, "10,-12", "it finished at the end of the box")
  -- no pickaxe: refuses at once
  local _, Dr3 = simRobot({ box = { 1, 0, 1, 1, 0, 1 }, inv = {} })
  local n3, err3 = Dr3.clear(1, 0, 1, 1, 0, 1, {})
  eq(n3, nil) truthy(tostring(err3):find("pickaxe"))
  require("shulker.devices").bus = realBus
  package.loaded["robot"] = nil
  package.loaded["shulker.drone"] = nil
end)

os.execute("rm -rf " .. U.q(tmp))
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
