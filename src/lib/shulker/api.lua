-- Claude Messages API client (raw HTTP + server-sent events; there is no Anthropic SDK for Lua).
local json = require("shulker.json")
local http = require("shulker.http")
local U = require("shulker.util")

local M = {}

M.URL = "https://api.anthropic.com/v1/messages"
M.MODELS = { "claude-opus-5-5", "claude-sonnet-5-5" }
M.MODEL_NAMES = { ["claude-opus-5-5"] = "Opus 5.5", ["claude-sonnet-5-5"] = "Sonnet 5.5" }
M.EFFORTS = { "low", "medium", "high", "xhigh", "max" }
M.THINKING = { "updates", "summarized", "omitted" }
-- Anthropic's published, fixed inbound range for api.anthropic.com (docs: "IP addresses").
M.PIN_CIDR = "160.79.104.0/23"
M.PIN_FALLBACK_IP = "160.79.104.10"
-- server-side refusal fallbacks ("default" routing) and short progress notes between tool calls
M.BETAS = "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18"

---------------------------------------------------------------- key + config
local function dir() return U.userdir() .. "/claude" end
function M.keyPath() return dir() .. "/key" end
function M.configPath() return dir() .. "/config.json" end

function M.getKey()
  local k = os.getenv("ANTHROPIC_API_KEY")
  if k and k:match("%S") then return (k:gsub("%s", "")), "env" end
  k = U.read(M.keyPath())
  k = k and k:gsub("%s", "")
  if k and k ~= "" then return k, "file" end
end

function M.setKey(k)
  U.mkdir(U.userdir(), "700")
  U.mkdir(dir(), "700")
  local ok, err = U.write(M.keyPath(), (k:gsub("%s", "")) .. "\n", "600")
  if not ok then return nil, err end
  os.execute("chmod 600 " .. U.q(M.keyPath()))
  return true
end

function M.forgetKey()
  if U.exists(M.keyPath()) then
    os.execute("shred -u " .. U.q(M.keyPath()) .. " 2>/dev/null || rm -f " .. U.q(M.keyPath()))
  end
end

M.DEFAULTS = {
  model = "claude-opus-5-5", effort = "low", thinking = "omitted", auto = false,
  max_tokens = 32000, api_url = M.URL, pin = true, idle_timeout = 180, retries = 4,
  tls_ack = false,
}

function M.loadConfig()
  local c = {}
  for k, v in pairs(M.DEFAULTS) do c[k] = v end
  local d = json.decode(U.read(M.configPath()) or "")
  if type(d) == "table" then
    for k, v in pairs(d) do if M.DEFAULTS[k] ~= nil and type(v) == type(M.DEFAULTS[k]) then c[k] = v end end
  end
  if os.getenv("SHULKER_API_URL") then c.api_url = os.getenv("SHULKER_API_URL") end
  return c
end

function M.saveConfig(c)
  U.mkdir(U.userdir(), "700")
  U.mkdir(dir(), "700")
  local out = {}
  for k in pairs(M.DEFAULTS) do out[k] = c[k] end
  return U.write(M.configPath(), json.encode(out) .. "\n", "600")
end

-- validate + set one config value from text; returns true | nil, why
function M.setOption(c, k, v)
  if M.DEFAULTS[k] == nil then return nil, "unknown option " .. k end
  local t = type(M.DEFAULTS[k])
  if t == "boolean" then
    if v == "on" or v == "true" or v == "yes" or v == "1" then v = true
    elseif v == "off" or v == "false" or v == "no" or v == "0" then v = false
    else return nil, k .. " is on or off" end
  elseif t == "number" then
    v = tonumber(v)
    if not v then return nil, k .. " must be a number" end
  end
  if k == "model" then
    local m = M.resolveModel(v)
    if not m then return nil, "model: opus, sonnet, or a full model ID (claude-...)" end
    v = m
  elseif k == "effort" then
    local okE = false
    for _, e in ipairs(M.EFFORTS) do if e == v then okE = true end end
    if not okE then return nil, "effort: " .. table.concat(M.EFFORTS, ", ") end
  elseif k == "thinking" then
    local okT = false
    for _, e in ipairs(M.THINKING) do if e == v then okT = true end end
    if not okT then return nil, "thinking: " .. table.concat(M.THINKING, ", ") end
  end
  c[k] = v
  return true
end

function M.resolveModel(v)
  v = tostring(v or ""):lower()
  if v == "opus" then return "claude-opus-5-5" end
  if v == "sonnet" then return "claude-sonnet-5-5" end
  if v:match("^claude%-[%w%-%.]+$") then return v end
end

---------------------------------------------------------------- where to connect
-- For api.anthropic.com we never trust DNS alone: the reply must lie in Anthropic's published range,
-- otherwise we connect to a known address in that range. This defeats DNS spoofing (the name server
-- is plain UDP to whatever /etc/resolv.conf says) and works without any name server at all.
-- It does NOT replace certificate checks: someone who can intercept traffic to that address can
-- still read the key. See README "Security".
function M.target(cfg, warn)
  local u = http.parseurl(cfg.api_url)
  if not u then return nil, "bad api_url" end
  if u.host ~= "api.anthropic.com" or cfg.pin == false then return nil end
  local ips = http.resolve(u.host)
  if ips then
    for _, ip in ipairs(ips) do
      if http.inCidr(ip, M.PIN_CIDR) then return ip end
    end
    if warn then
      warn(("DNS says api.anthropic.com is %s, outside Anthropic's published range %s: ignoring it and using %s.")
        :format(table.concat(ips, ", "), M.PIN_CIDR, M.PIN_FALLBACK_IP))
    end
  end
  return M.PIN_FALLBACK_IP
end

---------------------------------------------------------------- server-sent events
function M.sseParser()
  local p = { buf = "", event = nil, data = {} }
  function p:feed(text)
    local out = {}
    self.buf = self.buf .. text
    while true do
      local a, b = self.buf:find("\r?\n")
      if not a then break end
      local line = self.buf:sub(1, a - 1)
      self.buf = self.buf:sub(b + 1)
      if line == "" then
        if #self.data > 0 then out[#out + 1] = { event = self.event, data = table.concat(self.data, "\n") } end
        self.event, self.data = nil, {}
      elseif line:sub(1, 1) ~= ":" then
        local k, v = line:match("^([^:]+):%s?(.*)$")
        if k == "event" then self.event = v elseif k == "data" then self.data[#self.data + 1] = v end
      end
    end
    return out
  end
  return p
end

-- Rebuilds the final Message from the event stream.
-- cb: on_start(message), on_block(block, index), on_text(text, index), on_thinking(text, index),
--     on_tool_progress(bytes_so_far, index)
function M.assembler(cb)
  cb = cb or {}
  local A = { msg = nil, partial = {}, done = false, err = nil }
  function A:event(ev)
    local d, jerr = json.decode(ev.data)
    if type(d) ~= "table" then self.err = "unreadable event: " .. tostring(jerr) return end
    local t = d.type or ev.event
    if t == "message_start" then
      self.msg = d.message
      if type(self.msg.content) ~= "table" then self.msg.content = json.array() end
      setmetatable(self.msg.content, getmetatable(json.array()))
      if cb.on_start then cb.on_start(self.msg) end
    elseif t == "content_block_start" then
      local i = (d.index or 0) + 1
      local b = d.content_block
      if b.type == "tool_use" or b.type == "server_tool_use" then
        self.partial[i] = {}
      end
      self.msg.content[i] = b
      if cb.on_block then cb.on_block(b, i) end
    elseif t == "content_block_delta" then
      local i = (d.index or 0) + 1
      local b, delta = self.msg.content[i], d.delta or {}
      if not b then return end
      if delta.type == "text_delta" then
        b.text = (b.text or "") .. delta.text
        if cb.on_text then cb.on_text(delta.text, i) end
      elseif delta.type == "input_json_delta" then
        local parts = self.partial[i] or {}
        self.partial[i] = parts
        parts[#parts + 1] = delta.partial_json or ""
        parts.n = (parts.n or 0) + #(delta.partial_json or "")
        if cb.on_tool_progress then cb.on_tool_progress(parts.n, i) end
      elseif delta.type == "thinking_delta" then
        b.thinking = (b.thinking or "") .. (delta.thinking or "")
        if cb.on_thinking then cb.on_thinking(delta.thinking or "", i) end
      elseif delta.type == "signature_delta" then
        b.signature = delta.signature
      elseif delta.type == "citations_delta" then
        if type(b.citations) ~= "table" then b.citations = json.array() end
        b.citations[#b.citations + 1] = delta.citation
      end
    elseif t == "content_block_stop" then
      local i = (d.index or 0) + 1
      local b = self.msg.content[i]
      if b and self.partial[i] then
        local raw = table.concat(self.partial[i])
        if raw == "" then
          b.input = json.object({})
        else
          local v = json.decode(raw)
          if type(v) == "table" and not json.isarray(v) then
            b.input = v
          else
            b.input = json.object({})
            b._invalid = raw                  -- answered with an INVALID_JSON error, never run
          end
        end
        self.partial[i] = nil
      end
    elseif t == "message_delta" then
      local delta = d.delta or {}
      for k, v in pairs(delta) do self.msg[k] = v end
      if type(d.usage) == "table" then
        self.msg.usage = self.msg.usage or {}
        for k, v in pairs(d.usage) do self.msg.usage[k] = v end
      end
    elseif t == "message_stop" then
      self.done = true
    elseif t == "error" then
      local e = type(d.error) == "table" and d.error or {}
      self.err = (e.type or "error") .. ": " .. tostring(e.message or "stream error")
      self.errType = e.type
    end
  end
  return A
end

---------------------------------------------------------------- one request
local function apiError(status, body, headers)
  local msg = ("HTTP %d"):format(status)
  local d = json.decode(body or "")
  local etype
  if type(d) == "table" and type(d.error) == "table" then
    etype = d.error.type
    msg = msg .. ": " .. tostring(d.error.message or etype)
  elseif body and body:match("%S") then
    msg = msg .. ": " .. U.trim(body):sub(1, 200)
  end
  if status == 401 then msg = "The API key was rejected (401). Set a new one with `claude key`." end
  if status == 403 and not etype then msg = msg .. " (the server admin may have blocked this host in the Internet Gateway config)" end
  local retry = status == 408 or status == 409 or status == 429 or status >= 500
  local after = tonumber((headers or {})["retry-after"] or "")
  return msg, retry, after
end

-- Send one streaming request. Returns message | nil, err, retryable, retry_after
function M.streamOnce(cfg, key, body, cb)
  cb = cb or {}
  local u = http.parseurl(cfg.api_url)
  local ip = M.target(cfg, cb.on_warn)
  local payload = json.encode(body)
  local sse = M.sseParser()
  local asm = M.assembler(cb)
  local status, headers
  local res, err, retry = http.request({
    url = cfg.api_url, method = "POST", ip = ip, sni = u and u.host,
    headers = {
      ["content-type"] = "application/json",
      ["accept"] = "text/event-stream",
      ["x-api-key"] = key,
      ["anthropic-version"] = "2023-06-01",
      ["anthropic-beta"] = M.BETAS,
      ["user-agent"] = "ShulkerOS/" .. U.VERSION,
    },
    body = payload,
    idle_timeout = cfg.idle_timeout, connect_timeout = 30,
    on_head = function(s, h) status, headers = s, h end,
    on_data = function(bytes)
      for _, ev in ipairs(sse:feed(bytes)) do
        asm:event(ev)
        if asm.err then return false end
      end
    end,
    on_wait = cb.on_wait,
  })
  if asm.err then
    local retryable = asm.errType == "overloaded_error" or asm.errType == "api_error" or asm.errType == "rate_limit_error"
    return nil, asm.err, retryable
  end
  if not res then return nil, err, retry end
  if res.status ~= 200 then
    local msg, r, after = apiError(res.status, res.body, res.headers)
    return nil, msg, r, after
  end
  if not asm.done or not asm.msg then
    -- a non-streaming JSON reply (the wget fallback) is also fine
    local d = json.decode(res.body or "")
    if type(d) == "table" and d.type == "message" then return d end
    return nil, "the reply stream ended early (connection dropped?)", true
  end
  return asm.msg
end

-- With retries for 429 / 5xx / overloaded / dropped connections.
-- cb.on_retry(err, wait, attempt) is told before each wait.
function M.send(cfg, key, body, cb)
  cb = cb or {}
  local tries = math.max(1, (cfg.retries or 4) + 1)
  local msg, err, retry, after
  for attempt = 1, tries do
    msg, err, retry, after = M.streamOnce(cfg, key, body, cb)
    if msg or not retry or attempt == tries then break end
    local wait = math.min(after or (2 ^ attempt), 60)
    if cb.on_retry then cb.on_retry(err, wait, attempt) end
    os.execute("sleep " .. math.floor(wait))
  end
  if not msg then return nil, err end
  return msg
end

-- the request body for a conversation
function M.body(cfg, system, tools, messages)
  local thinking = { type = "adaptive" }
  if cfg.thinking == "updates" or cfg.thinking == "summarized" or cfg.thinking == "omitted" then
    thinking.display = cfg.thinking               -- omitted: Claude still thinks, the terminal stays quiet
  end
  return {
    model = cfg.model,
    max_tokens = cfg.max_tokens,
    stream = true,
    system = json.array({ { type = "text", text = system } }),
    tools = tools,
    messages = messages,
    thinking = thinking,
    output_config = { effort = cfg.effort },
    fallbacks = "default",            -- a declined request is retried on another model by the API
    cache_control = { type = "ephemeral" },
  }
end

return M
