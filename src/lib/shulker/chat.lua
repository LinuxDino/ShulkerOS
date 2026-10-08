-- The `claude` command: interactive chat in the terminal, and one-shot `claude -p`.
local json = require("shulker.json")
local api = require("shulker.api")
local U = require("shulker.util")
local tools = require("shulker.tools")

local M = {}
local c = U.c
local MAX_STEPS = 40

M.PRICES = {                                  -- $ per million tokens: input, output, cache read
  ["claude-opus-5-5"] = { 4, 20, 0.2 },
  ["claude-sonnet-5-5"] = { 2, 10, 0.2 },
}

M.TLS_WARNING = [[
  !! Security warning: HTTPS on Sedna Linux does not verify certificates.

  Sedna has no list of trusted certificate authorities, so BusyBox TLS encrypts
  traffic but cannot prove it is talking to the real api.anthropic.com. Shulker
  OS only connects to Anthropic's published address range (160.79.104.0/23),
  which stops fake DNS answers, but anyone who can intercept traffic between
  the Minecraft server and Anthropic could still read your API key.

  Also: the key is saved in ~/.shulker/claude/key (mode 600) on this computer's
  disk, which is part of the world save. The server owner can read it.

  Use a key with a low spending limit (console.anthropic.com > Limits) and
  revoke it if in doubt. API use is billed to the key's account.]]

---------------------------------------------------------------- terminal helpers
local function out(s) io.stdout:write(s) io.stdout:flush() end
local function err(s) io.stderr:write(s) io.stderr:flush() end

-- read a line from the user's terminal even when stdin is a pipe; nil when there is no terminal
local function ttyRead(prompt, hidden)
  local tty = io.open("/dev/tty", "r")
  if not tty then return nil end
  local w = io.open("/dev/tty", "w")
  if w then w:write(prompt) w:flush() end
  if hidden then os.execute("stty -echo < /dev/tty 2>/dev/null") end
  local ok, line = pcall(tty.read, tty, "l")
  if hidden then os.execute("stty echo < /dev/tty 2>/dev/null") if w then w:write("\n") end end
  tty:close()
  if w then w:close() end
  if not ok then error(line, 0) end
  return line
end
M.ttyRead = ttyRead

function M.askKey()
  print(c("warn", M.TLS_WARNING))
  print()
  local ans = ttyRead("Type yes to continue: ")
  if not ans or U.trim(ans):lower() ~= "yes" then return nil, "cancelled" end
  local key = ttyRead("Anthropic API key (sk-ant-..., input hidden): ", true)
  if not key or not key:match("%S") then return nil, "no key entered" end
  key = key:gsub("%s", "")
  if not key:match("^sk%-ant%-") then print(c("warn", "That doesn't look like an Anthropic API key (sk-ant-...), saving it anyway.")) end
  local ok, e = api.setKey(key)
  if not ok then return nil, e end
  local cfg = api.loadConfig()
  cfg.tls_ack = true
  api.saveConfig(cfg)
  print(c("ok", "Key saved to " .. api.keyPath() .. " (mode 600)."))
  return key
end

---------------------------------------------------------------- session
function M.new(opts)
  opts = opts or {}
  local S = {
    cfg = opts.cfg or api.loadConfig(),
    kit = tools.new(),
    msgs = json.array({}),
    always = {},                     -- tool name -> true after "always"
    allow = opts.allow or {},        -- pre-approved tools (-p --allow, scheduled jobs)
    interactive = opts.interactive ~= false,
    quiet = opts.quiet,              -- -p: only the reply text on stdout
    usage = { input = 0, output = 0, cache_read = 0, cache_write = 0, requests = 0 },
    cost = 0,
  }
  S.system = S.kit.system
  local cwd = os.getenv("PWD")
  local host = U.trim((U.read("/etc/hostname") or "sedna"))
  S.system = S.system .. ("\n\nThis session: host %s, user %s, started in %s."):format(host, os.getenv("USER") or "root", cwd or "/")
  return setmetatable(S, { __index = M })
end

function M:sessionPath() return U.userdir() .. "/claude/session.json" end

function M:save()
  local text = json.encode({ model = self.cfg.model, messages = self.msgs })
  if #text > 200 * 1024 then return end                    -- the disk is small; don't keep huge sessions
  U.mkdir(U.userdir() .. "/claude", "700")
  U.write(self:sessionPath(), text, "600")
end

function M:load()
  local d = json.decode(U.read(self:sessionPath()) or "")
  if type(d) == "table" and type(d.messages) == "table" then
    self.msgs = json.array(d.messages)
    return #self.msgs
  end
  return 0
end

-- undo the current turn: back to before the user's last typed message (the history stays valid)
function M:rollback(mark)
  while #self.msgs > mark do table.remove(self.msgs) end
end

function M:account(msg)
  local u = type(msg.usage) == "table" and msg.usage or {}
  local function n(v) return tonumber(v ~= json.null and v or 0) or 0 end
  local a = self.usage
  a.input = a.input + n(u.input_tokens)
  a.output = a.output + n(u.output_tokens)
  a.cache_read = a.cache_read + n(u.cache_read_input_tokens)
  a.cache_write = a.cache_write + n(u.cache_creation_input_tokens)
  a.requests = a.requests + 1
  local p = M.PRICES[msg.model] or M.PRICES[self.cfg.model] or { 4, 20, 0.2 }
  self.cost = self.cost + (n(u.input_tokens) * p[1] + n(u.cache_creation_input_tokens) * p[1] * 1.25
    + n(u.cache_read_input_tokens) * p[3] + n(u.output_tokens) * p[2]) / 1e6
end

---------------------------------------------------------------- approvals
-- returns "allow" | "always" | "deny" | "noninteractive"
function M:approve(name, input)
  if self.cfg.auto or self.always[name] or self.allow[name] or self.allow["*"] then return "allow" end
  if not self.interactive then return "noninteractive" end
  local desc = self.kit.describe(name, input)
  err("\n" .. c("warn", "? ") .. c("bold", name) .. "  " .. desc .. "\n")
  while true do
    local ans = ttyRead(c("accent", "  Allow? [y]es / [a]lways for " .. name .. " / [n]o: "))
    if ans == nil then return "noninteractive" end
    ans = U.trim(ans):lower()
    if ans == "y" or ans == "yes" then return "allow" end
    if ans == "a" or ans == "always" then return "always" end
    if ans == "n" or ans == "no" or ans == "" then return "deny" end
  end
end

---------------------------------------------------------------- printing a streamed reply
local function printer(S)
  local P = { col = 0, kind = nil, spinner = false, started = os.time(), printed = false }
  local frames = { "|", "/", "-", "\\" }
  local function clearSpin()
    if P.spinner then err("\r" .. string.rep(" ", 50) .. "\r") P.spinner = false end
  end
  local function begin(kind)
    clearSpin()
    if P.kind ~= kind then
      if P.printed and not S.quiet then out("\n") end
      P.kind = kind
    end
    P.printed = true
  end
  return {
    on_wait = function(quiet)
      if S.quiet or not U.isatty(2) or P.printed and P.kind == "text" then return end
      local t = os.time() - P.started
      err(("\r%s %s"):format(c("accent", frames[t % 4 + 1]), c("dim", ("Claude is thinking... %ds"):format(t))))
      P.spinner = true
    end,
    on_block = function(b)
      if b.type == "thinking" and not S.quiet then
        P.thinkingOpen = false
      elseif b.type == "text" then
        begin("text")
      end
    end,
    on_thinking = function(text)
      if S.quiet or text == "" then return end
      if not P.thinkingOpen then begin("thinking") err(c("dim", "  ~ ")) P.thinkingOpen = true end
      err(c("dim", (text:gsub("\n", "\n    "))))
    end,
    on_text = function(text)
      begin("text")
      out(text)
      S.printedText = true
    end,
    on_warn = function(w) clearSpin() err(c("warn", "! " .. w) .. "\n") end,
    on_retry = function(e, wait, attempt)
      clearSpin()
      err("\n" .. c("warn", ("! %s - retrying in %ds (attempt %d)"):format(e, wait, attempt + 1)) .. "\n")
      P.started = os.time()
      P.printed, P.kind = false, nil
    end,
    finish = function() clearSpin() if P.printed and not S.quiet then out("\n") end end,
    printed = function() return P.printed end,
  }
end

---------------------------------------------------------------- one user turn
-- returns final text | nil, error
function M:turn(content)
  local mark = #self.msgs
  self.msgs[#self.msgs + 1] = { role = "user", content = content }
  local key = api.getKey()
  if not key then self:rollback(mark) return nil, "no API key: run `claude key`" end
  local finalText = {}
  for step = 1, MAX_STEPS do
    if step > 1 and self.quiet and self.printedText then out("\n") self.printedText = false end
    local P = printer(self)
    local body = api.body(self.cfg, self.system, self.kit.TOOLS, self.msgs)
    local ok, msg, e = pcall(api.send, self.cfg, key, body, P)
    P.finish()
    if not ok then
      self:rollback(mark)
      if tostring(msg):find("interrupted") then return nil, "cancelled" end
      return nil, "internal error: " .. tostring(msg)
    end
    if not msg then
      self:rollback(mark)
      return nil, e .. (step > 1 and "\n(this turn was undone; actions already done stay done)" or "")
    end
    self:account(msg)
    if msg.model and msg.model ~= self.cfg.model and not self.quiet then
      err(c("dim", ("(answered by %s)"):format(msg.model)) .. "\n")
    end
    if msg.stop_reason == "refusal" then
      self:rollback(mark)
      return nil, "Claude declined this request."
    end

    local content = type(msg.content) == "table" and msg.content or json.array({})
    -- after a mid-reply model fallback, blocks before the last fallback marker are not echoed back
    -- (except text); the marker itself is dropped
    local lastFb = 0
    for i, b in ipairs(content) do if b.type == "fallback" then lastFb = i end end
    local clean, uses = json.array({}), {}
    for i, b in ipairs(content) do
      local skip = b.type == "fallback" or (i < lastFb and (b.type == "thinking" or b.type == "redacted_thinking" or b.type == "tool_use"))
      if not skip then
        local invalid = b._invalid
        b._invalid = nil
        clean[#clean + 1] = b
        if b.type == "tool_use" then uses[#uses + 1] = { block = b, invalid = invalid } end
        if b.type == "text" and type(b.text) == "string" then finalText[#finalText + 1] = b.text end
      end
    end

    if msg.stop_reason ~= "tool_use" or #uses == 0 then
      if #uses > 0 then                           -- tool calls cut off by max_tokens can't stay
        self:rollback(mark)
        return nil, "The reply was cut off in the middle of an action; nothing was run. Try again (or raise max_tokens)."
      end
      if msg.stop_reason == "max_tokens" then err(c("warn", "(reply cut off: max_tokens)") .. "\n") end
      if #clean == 0 then clean = json.array({ { type = "text", text = "(no reply)" } }) end
      self.msgs[#self.msgs + 1] = { role = "assistant", content = clean }
      self:save()
      return table.concat(finalText, "\n")
    end

    self.msgs[#self.msgs + 1] = { role = "assistant", content = clean }    -- appended unchanged
    local results = json.array({})
    for _, u in ipairs(uses) do
      local b = u.block
      local name, input = tostring(b.name), b.input
      local text, isErr
      if u.invalid then
        text, isErr = json.encode({ INVALID_JSON = u.invalid }), true
      elseif not self.kit.DEFS[name] then
        text, isErr = "unknown tool " .. name, true
      else
        local decision = "allow"
        if self.kit.RISKY[name] then decision = self:approve(name, input) end
        if decision == "always" then self.always[name] = true decision = "allow" end
        if decision == "allow" then
          if not self.quiet then err(c("accent", "> ") .. c("soft", name) .. " " .. c("dim", self.kit.describe(name, input):sub(1, 70)) .. "\n") end
          local okr, a, bb = pcall(self.kit.run, name, input)
          if okr then text, isErr = a, bb else
            if tostring(a):find("interrupted") then text, isErr = "The user interrupted this tool.", true
            else text, isErr = "tool crashed: " .. tostring(a), true end
          end
          if isErr and not self.quiet then err(c("dim", "  " .. tostring(text):gsub("\n.*", ""):sub(1, 76)) .. "\n") end
        elseif decision == "noninteractive" then
          text, isErr = ("%s needs the user's permission, and nobody is at the terminal to give it. It was not run. (The user can allow it with --allow %s.)"):format(name, name), true
          if not self.quiet then err(c("warn", "  not allowed without a terminal: " .. name) .. "\n") end
        else
          text, isErr = "The user denied this action.", true
          err(c("dim", "  denied") .. "\n")
        end
      end
      results[#results + 1] = { type = "tool_result", tool_use_id = b.id, content = U.clip(text, 12000), is_error = isErr and true or false }
    end
    self.msgs[#self.msgs + 1] = { role = "user", content = results }
  end
  self:rollback(mark)
  return nil, ("stopped after %d steps"):format(MAX_STEPS)
end

---------------------------------------------------------------- REPL
local HELP = [[
Type a message and press Enter. A line ending in \ continues on the next line;
""" on its own line starts and ends a multi-line block.
  /model [opus|sonnet]   show or switch the model     /effort [low..max]
  /thinking [updates|summarized|omitted]              /auto [on|off]  run tools without asking
  /clear   new conversation    /cost   tokens and estimated cost
  /tools   list Claude's tools  /key   set the API key   /exit   quit (or Ctrl-D)
Ctrl-C cancels a reply in progress.]]

function M:banner()
  local name = api.MODEL_NAMES[self.cfg.model] or self.cfg.model
  local lines = require("shulker.art").beside({
    "", c("bold", "Claude") .. c("dim", " on Shulker OS"),
    c("dim", ("%s, effort %s%s"):format(name, self.cfg.effort, self.cfg.auto and ", auto (no prompts)" or "")),
    "", c("dim", "/help for commands, Ctrl-D to quit") }, c, nil, not U.colored())
  print(table.concat(lines, "\n"))
  print()
end

function M:command(line)
  local cmd, arg = line:match("^/(%S+)%s*(.-)%s*$")
  local cfg = self.cfg
  local function set(k, v)
    local ok, e = api.setOption(cfg, k, v)
    if not ok then print(c("err", e)) return end
    api.saveConfig(cfg)
    print(c("ok", ("%s = %s"):format(k, tostring(cfg[k]))))
  end
  if cmd == "help" or cmd == "?" then print(HELP)
  elseif cmd == "exit" or cmd == "quit" or cmd == "q" then return "exit"
  elseif cmd == "clear" or cmd == "new" then self.msgs = json.array({}) print(c("dim", "(new conversation)"))
  elseif cmd == "model" then
    if arg == "" then print(cfg.model .. "  (opus = claude-opus-5-5, sonnet = claude-sonnet-5-5)") else set("model", arg) end
  elseif cmd == "effort" then
    if arg == "" then print(cfg.effort .. "  (" .. table.concat(api.EFFORTS, ", ") .. ")") else set("effort", arg) end
  elseif cmd == "thinking" then
    if arg == "" then print(cfg.thinking .. "  (" .. table.concat(api.THINKING, ", ") .. ")") else set("thinking", arg) end
  elseif cmd == "auto" then
    if arg == "" then print(cfg.auto and "on" or "off") else
      set("auto", arg)
      if cfg.auto then print(c("warn", "Claude now runs commands, edits files and calls devices without asking.")) end
    end
  elseif cmd == "cost" then
    local a = self.usage
    print(("%d requests · input %d · cache read %d · cache write %d · output %d tokens"):format(
      a.requests, a.input, a.cache_read, a.cache_write, a.output))
    print(("estimated cost this session: $%.4f (list prices)"):format(self.cost))
  elseif cmd == "tools" then
    for _, t in ipairs(tools.LIST) do print(("  %-15s %s"):format(t.name, t.risky and c("warn", "asks first") or "")) end
  elseif cmd == "key" then
    local ok, e = M.askKey()
    if not ok then print(c("err", e)) end
  else
    print(c("err", "unknown command /" .. tostring(cmd) .. " (try /help)"))
  end
end

function M:readInput()
  local okr, line = pcall(io.read, "l")
  if not okr then out("\n") return "" end              -- Ctrl-C at the prompt
  if line == nil then return nil end
  if U.trim(line) == '"""' then
    local parts = {}
    while true do
      out(c("dim", "... "))
      local l = io.read("l")
      if l == nil or U.trim(l) == '"""' then break end
      parts[#parts + 1] = l
    end
    return table.concat(parts, "\n")
  end
  while line:sub(-1) == "\\" do
    out(c("dim", "... "))
    local l = io.read("l")
    if not l then break end
    line = line:sub(1, -2) .. "\n" .. l
  end
  return line
end

function M:repl()
  self:banner()
  if #self.msgs > 0 then print(c("dim", ("(continuing a conversation of %d messages)"):format(#self.msgs))) end
  while true do
    out(c("accent", "you") .. c("soft", " > "))
    local line = self:readInput()
    if line == nil then out("\n") break end
    if line:match("^%s*/") then
      if self:command(U.trim(line)) == "exit" then break end
    elseif line:match("%S") then
      out("\n")
      local text, e = self:turn(line)
      if not text then err(c("err", "! " .. e) .. "\n") end
      out("\n")
    end
  end
end

return M
