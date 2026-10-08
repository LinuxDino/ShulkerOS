-- JSON for Shulker OS.
-- Sedna ships lua-cjson 2.1.0.10 (the OpenResty fork): fast C decode, and arrays decoded with
-- cjson.array_mt so they encode back as arrays even when empty. Encoding is done here in Lua so that
-- the rules are the same everywhere: a table marked with json.array() (or cjson.array_mt) is an
-- array, a plain table with keys 1..n is an array, any other table (including {}) is an object.
-- Without a suitable cjson (a host Lua for tests) a small pure Lua decoder is used.
local M = {}

local ok, cjson = pcall(require, "cjson")
if ok and not (cjson.array_mt and cjson.decode_array_with_array_mt) then ok = false end
if os.getenv("SHULKER_PURE_JSON") == "1" then ok = false end

local ARRAY = ok and cjson.array_mt or { __name = "json.array" }
M.null = ok and cjson.null or setmetatable({}, { __name = "json.null", __tostring = function() return "null" end })
M.backend = ok and "cjson" or "lua"

function M.array(t) return setmetatable(t or {}, ARRAY) end
function M.isarray(t) return getmetatable(t) == ARRAY end
function M.object(t) return t or {} end

---------------------------------------------------------------- encode
local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
                  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function escape(s)
  return (s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end))
end

local function isSequence(t)
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0
end

local encodeValue
local function encodeTable(t, out, depth)
  if depth > 100 then error("json: nesting too deep", 0) end
  if getmetatable(t) == ARRAY or isSequence(t) then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encodeValue(t[i], out, depth + 1)
    end
    out[#out + 1] = "]"
  else
    local keys = {}
    for k in pairs(t) do
      if type(k) ~= "string" and type(k) ~= "number" then error("json: bad key type " .. type(k), 0) end
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)                     -- stable output: keeps the cached request prefix byte-identical
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
      if i > 1 then out[#out + 1] = "," end
      local v = t[k]
      if v == nil then v = t[tonumber(k)] end
      out[#out + 1] = '"' .. escape(k) .. '":'
      encodeValue(v, out, depth + 1)
    end
    out[#out + 1] = "}"
  end
end

function encodeValue(v, out, depth)
  local tv = type(v)
  if v == nil or v == M.null then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif math.type(v) == "integer" then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.14g", v)
    end
  elseif tv == "string" then
    out[#out + 1] = '"' .. escape(v) .. '"'
  elseif tv == "table" then
    encodeTable(v, out, depth)
  else
    error("json: cannot encode " .. tv, 0)
  end
end

function M.encode(v)
  local out = {}
  encodeValue(v, out, 0)
  return table.concat(out)
end

---------------------------------------------------------------- decode
local function utf8char(cp)
  return utf8.char(cp)
end

local function luaDecode(s)
  local pos = 1
  local function fail(msg) error(("json: %s at position %d"):format(msg, pos), 0) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function str()
    pos = pos + 1
    local parts = {}
    while true do
      local a, b = s:find('["\\]', pos)
      if not a then fail("unterminated string") end
      parts[#parts + 1] = s:sub(pos, a - 1)
      if s:sub(a, a) == '"' then pos = a + 1 break end
      local c = s:sub(a + 1, a + 1)
      if c == "u" then
        local hex = s:sub(a + 2, a + 5)
        if not hex:match("^%x%x%x%x$") then fail("bad unicode escape") end
        local cp = tonumber(hex, 16)
        local nextPos = a + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(nextPos, nextPos + 1) == "\\u" then
          local lo = tonumber(s:sub(nextPos + 2, nextPos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            nextPos = nextPos + 6
          end
        end
        parts[#parts + 1] = utf8char(cp)
        pos = nextPos
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if not map[c] then fail("bad escape") end
        parts[#parts + 1] = map[c]
        pos = a + 2
      end
    end
    return table.concat(parts)
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local t = {}
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then fail("expected key") end
        local k = str()
        ws()
        if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
        pos = pos + 1
        t[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1
      local t = M.array({})
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif c == '"' then
      return str()
    elseif s:find("^true", pos) then pos = pos + 4 return true
    elseif s:find("^false", pos) then pos = pos + 5 return false
    elseif s:find("^null", pos) then pos = pos + 4 return M.null
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" or num == "-" then fail("unexpected character") end
      pos = pos + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  local v = value()
  ws()
  if pos <= #s then fail("trailing garbage") end
  return v
end

if ok then
  cjson.decode_array_with_array_mt(true)
  pcall(cjson.encode_max_depth, 200)
  pcall(cjson.decode_max_depth, 200)
end

-- decode(text) -> value | nil, error   (never throws)
function M.decode(s)
  if type(s) ~= "string" then return nil, "json: not a string" end
  local okd, v
  if ok then okd, v = pcall(cjson.decode, s) else okd, v = pcall(luaDecode, s) end
  if not okd then return nil, tostring(v) end
  return v
end

-- the pure Lua decoder is always available for tests
M._luaDecode = luaDecode

return M
