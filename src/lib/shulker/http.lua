-- HTTP(S) client for Sedna Linux.
--
-- Sedna has no TLS library for Lua. BusyBox does have TLS, in two shapes: wget (which hides the body
-- of every non-2xx reply and needs headers, i.e. the API key, on its command line) and ssl_client, the
-- helper wget itself uses. So we connect the TCP socket ourselves with luaposix, then hand it to
-- `ssl_client -s 3 -n <host>`: the request goes in on its stdin, the decrypted reply comes out on
-- its stdout, and we parse the HTTP ourselves. That gives us error bodies, headers (retry-after),
-- streaming with an idle timeout, and no secrets in the process list.
--
-- !! BusyBox TLS does NOT verify certificates (there is no CA bundle on Sedna). See api.lua for the
-- address pinning we do for api.anthropic.com, and README "Security" for what that does and doesn't
-- protect against.
--
-- Without luaposix this falls back to BusyBox wget (no streaming, no error bodies).
local M = {}

local okp, P = pcall(function()
  return {
    sock = require("posix.sys.socket"),
    unistd = require("posix.unistd"),
    poll = require("posix.poll"),
    fcntl = require("posix.fcntl"),
    wait = require("posix.sys.wait"),
    signal = require("posix.signal"),
    errno = require("posix.errno"),
    time = require("posix.time"),
  }
end)
M.posix = okp and P or nil

---------------------------------------------------------------- incremental HTTP/1.1 response parser
-- p = M.parser(); p:feed(bytes) -> list of events:
--   { "head", status, reason, headers }   headers: lower-case name -> value
--   { "data", bytes }                     body bytes (chunked transfer decoded)
--   { "done" }                            body complete (by length or last chunk)
function M.parser()
  local p = { buf = "", state = "status", headers = {}, remaining = nil, chunked = false }
  function p:feed(bytes)
    local ev = {}
    self.buf = self.buf .. bytes
    while true do
      if self.state == "status" or self.state == "headers" then
        local a, b = self.buf:find("\r?\n")
        if not a then break end
        local line = self.buf:sub(1, a - 1)
        self.buf = self.buf:sub(b + 1)
        if self.state == "status" then
          local code, reason = line:match("^HTTP/%d[%.%d]*%s+(%d%d%d)%s*(.*)$")
          if not code then error("bad HTTP status line: " .. line:sub(1, 80), 0) end
          self.status, self.reason = tonumber(code), reason
          self.state = "headers"
        elseif line == "" then
          if self.status >= 100 and self.status < 200 then  -- 100 Continue: another head follows
            self.state, self.headers = "status", {}
          else
            local te = (self.headers["transfer-encoding"] or ""):lower()
            self.chunked = te:find("chunked") ~= nil
            self.remaining = (not self.chunked) and tonumber(self.headers["content-length"] or "") or nil
            ev[#ev + 1] = { "head", self.status, self.reason, self.headers }
            if self.chunked then
              self.state = "chunksize"
            elseif self.remaining == 0 or self.status == 204 or self.status == 304 then
              self.state = "done"
              ev[#ev + 1] = { "done" }
            else
              self.state = "body"
            end
          end
        else
          local k, v = line:match("^([^:]+):%s*(.-)%s*$")
          if k then
            k = k:lower()
            self.headers[k] = self.headers[k] and (self.headers[k] .. ", " .. v) or v
          end
        end
      elseif self.state == "body" then
        if #self.buf == 0 then break end
        if self.remaining then
          local take = self.buf:sub(1, self.remaining)
          self.buf = self.buf:sub(#take + 1)
          self.remaining = self.remaining - #take
          ev[#ev + 1] = { "data", take }
          if self.remaining == 0 then self.state = "done" ev[#ev + 1] = { "done" } end
        else                                        -- read until close
          ev[#ev + 1] = { "data", self.buf }
          self.buf = ""
        end
        break
      elseif self.state == "chunksize" then
        local a, b = self.buf:find("\r?\n")
        if not a then break end
        local size = tonumber((self.buf:sub(1, a - 1):match("^%s*(%x+)")) or "", 16)
        if not size then error("bad chunk header", 0) end
        self.buf = self.buf:sub(b + 1)
        if size == 0 then
          self.state = "trailer"
        else
          self.remaining, self.state = size, "chunk"
        end
      elseif self.state == "chunk" then
        if #self.buf == 0 then break end
        local take = self.buf:sub(1, self.remaining)
        self.buf = self.buf:sub(#take + 1)
        self.remaining = self.remaining - #take
        ev[#ev + 1] = { "data", take }
        if self.remaining == 0 then self.state = "chunkend" end
      elseif self.state == "chunkend" then
        local a, b = self.buf:find("\r?\n")
        if not a then break end
        self.buf = self.buf:sub(b + 1)
        self.state = "chunksize"
      elseif self.state == "trailer" then
        local a, b = self.buf:find("\r?\n")
        if not a then break end
        local line = self.buf:sub(1, a - 1)
        self.buf = self.buf:sub(b + 1)
        if line == "" then self.state = "done" ev[#ev + 1] = { "done" } end
      else -- done
        break
      end
    end
    return ev
  end
  -- the connection closed: a close-delimited body is complete, anything else was cut off
  function p:eof()
    if self.state == "body" and not self.remaining then
      self.state = "done"
      return true
    end
    return self.state == "done"
  end
  return p
end

---------------------------------------------------------------- URL / request text
function M.parseurl(url)
  local scheme, rest = url:match("^(https?)://(.+)$")
  if not scheme then return nil, "bad URL: " .. tostring(url) end
  local hostport, path = rest:match("^([^/]+)(/.*)$")
  if not hostport then hostport, path = rest, "/" end
  local host, port = hostport:match("^(.-):(%d+)$")
  host = host or hostport
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  return { scheme = scheme, host = host, port = port, path = path, tls = scheme == "https" }
end

function M.requestText(method, u, headers, body)
  local lines = { ("%s %s HTTP/1.1"):format(method, u.path) }
  local hostHeader = u.host
  if (u.tls and u.port ~= 443) or (not u.tls and u.port ~= 80) then hostHeader = hostHeader .. ":" .. u.port end
  lines[#lines + 1] = "Host: " .. hostHeader
  local names = {}
  for k in pairs(headers or {}) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do lines[#lines + 1] = k .. ": " .. headers[k] end
  lines[#lines + 1] = "Connection: close"
  if body then lines[#lines + 1] = "Content-Length: " .. #body end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")
end

---------------------------------------------------------------- DNS + IPv4 helpers
function M.resolve(host)
  if host:match("^%d+%.%d+%.%d+%.%d+$") then return { host } end
  if not P then return nil, "no luaposix" end
  local res, err = P.sock.getaddrinfo(host, "443", { family = P.sock.AF_INET, socktype = P.sock.SOCK_STREAM })
  if not res then return nil, "cannot resolve " .. host .. ": " .. tostring(err) end
  local out = {}
  for _, r in ipairs(res) do if r.addr then out[#out + 1] = r.addr end end
  if #out == 0 then return nil, "no IPv4 address for " .. host end
  return out
end

local function ip2n(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end
-- inCidr("160.79.104.10", "160.79.104.0/23") -> true
function M.inCidr(ip, cidr)
  local net, bits = cidr:match("^([%d%.]+)/(%d+)$")
  local n, m = ip2n(ip), ip2n(net or "")
  if not n or not m then return false end
  local size = 2 ^ (32 - tonumber(bits))
  return math.floor(n / size) == math.floor(m / size)
end

---------------------------------------------------------------- the posix transport
local function now() return os.time() end

local function connect(ip, port, timeout)
  local S, F = P.sock, P.fcntl
  local fd, err = S.socket(S.AF_INET, S.SOCK_STREAM, 0)
  if not fd then return nil, "socket: " .. tostring(err) end
  local flags = F.fcntl(fd, F.F_GETFL)
  F.fcntl(fd, F.F_SETFL, flags | F.O_NONBLOCK)
  local ok, cerr, errnum = S.connect(fd, { family = S.AF_INET, addr = ip, port = port })
  if not ok and errnum ~= P.errno.EINPROGRESS then
    P.unistd.close(fd)
    return nil, ("connect %s:%d: %s"):format(ip, port, tostring(cerr))
  end
  if not ok then
    local fds = { [fd] = { events = { OUT = true } } }
    local n = P.poll.poll(fds, math.floor(timeout * 1000))
    if not n or n == 0 then
      P.unistd.close(fd)
      return nil, ("connect %s:%d: timed out after %ds (is the Internet Gateway connected and powered? see `netcfg test`)"):format(ip, port, timeout)
    end
    local soerr = S.getsockopt(fd, S.SOL_SOCKET, S.SO_ERROR)
    if soerr and soerr ~= 0 then
      P.unistd.close(fd)
      return nil, ("connect %s:%d: %s"):format(ip, port, P.errno.errno and select(1, P.errno.errno(soerr)) or ("error " .. soerr))
    end
  end
  F.fcntl(fd, F.F_SETFL, flags)
  return fd
end

-- spawn ssl_client on the socket; returns pid, stdout read fd, stderr read fd
local function spawnTLS(sockfd, reqpath, sni)
  local U = P.unistd
  local outr, outw = U.pipe()
  local errr, errw = U.pipe()
  local reqfd = P.fcntl.open(reqpath, P.fcntl.O_RDONLY)
  if not reqfd then return nil, "cannot open request file" end
  local pid, ferr = U.fork()
  if pid == nil then return nil, "fork: " .. tostring(ferr) end
  if pid == 0 then
    U.dup2(reqfd, 0)
    U.dup2(outw, 1)
    U.dup2(errw, 2)
    if sockfd ~= 3 then U.dup2(sockfd, 3) end
    U.execp("ssl_client", { "-s", "3", "-n", sni })
    io.stderr:write("cannot run ssl_client\n")
    U._exit(127)
  end
  U.close(outw) U.close(errw) U.close(reqfd) U.close(sockfd)
  return pid, outr, errr
end

local function reap(pid, kill)
  if not pid then return end
  if kill then pcall(P.signal.kill, pid, P.signal.SIGTERM) end
  pcall(P.wait.wait, pid)
end

-- opts: url, method, headers, body, ip (connect here instead of resolving), connect_timeout,
--       idle_timeout (seconds without a byte), total_timeout, on_head(status, headers),
--       on_data(bytes) -> return false to abort, on_wait(seconds_idle) (called about every second)
-- returns { status=, headers=, body= (only when no on_data) } | nil, err, retryable
function M.request(opts)
  local u, perr = M.parseurl(opts.url)
  if not u then return nil, perr, false end
  if not P then return M.wget(opts, u) end
  local ip = opts.ip
  if not ip then
    local ips, rerr = M.resolve(u.host)
    if not ips then return nil, rerr, true end
    ip = ips[1]
  end
  local text = M.requestText(opts.method or (opts.body and "POST" or "GET"), u, opts.headers, opts.body)

  local sock, cerr = connect(ip, u.port, opts.connect_timeout or 20)
  if not sock then return nil, cerr, true end

  local pid, rfd, efd, reqpath
  if u.tls then
    -- the request (with the API key) only ever touches RAM: /tmp is a tmpfs, the file is mode 600
    reqpath = os.tmpname()
    local f = io.open(reqpath, "wb")
    f:write(text)
    f:close()
    pid, rfd, efd = spawnTLS(sock, reqpath, opts.sni or u.host)
    if not pid then os.remove(reqpath) return nil, rfd, false end
  else
    local sent = 0
    while sent < #text do
      local n, werr = P.sock.send(sock, text:sub(sent + 1))
      if not n then P.unistd.close(sock) return nil, "send: " .. tostring(werr), true end
      sent = sent + n
    end
    rfd = sock
  end

  local parser = M.parser()
  local res = { body = {} }
  local idle = opts.idle_timeout or 120
  local deadline = opts.total_timeout and (now() + opts.total_timeout)
  local last = now()
  local finished, aborted, failure = false, false, nil
  local okLoop, loopErr = pcall(function()
    while not finished do
      local fds = { [rfd] = { events = { IN = true } } }
      local n = P.poll.poll(fds, 1000)
      if n and n > 0 then
        local chunk = P.unistd.read(rfd, 16384)
        if not chunk or chunk == "" then break end   -- closed
        last = now()
        local events = parser:feed(chunk)
        for _, e in ipairs(events) do
          if e[1] == "head" then
            res.status, res.reason, res.headers = e[2], e[3], e[4]
            if opts.on_head then opts.on_head(e[2], e[4]) end
          elseif e[1] == "data" then
            if opts.on_data and res.status and res.status < 300 then
              if opts.on_data(e[2]) == false then aborted = true finished = true break end
            else
              res.body[#res.body + 1] = e[2]
            end
          elseif e[1] == "done" then
            finished = true
          end
        end
      else
        local quiet = now() - last
        if opts.on_wait then opts.on_wait(quiet) end
        if quiet >= idle then failure = ("no data from %s for %ds (the connection was probably dropped)"):format(u.host, idle) break end
        if deadline and now() >= deadline then failure = "request took too long" break end
      end
    end
  end)
  if not finished and okLoop and not failure and parser:eof() then finished = true end

  local errText = ""
  if efd then
    local fds = { [efd] = { events = { IN = true } } }
    if (P.poll.poll(fds, 0) or 0) > 0 then errText = P.unistd.read(efd, 2048) or "" end
    P.unistd.close(efd)
  end
  P.unistd.close(rfd)
  reap(pid, not finished or aborted)
  if reqpath then os.remove(reqpath) end

  if not okLoop then error(loopErr, 0) end           -- e.g. "interrupted!" (Ctrl-C): the caller decides
  if aborted then return nil, "aborted", false end
  if failure then return nil, failure, true end
  if not finished then
    local why = res.status and "connection closed mid-reply" or "connection closed before a reply"
    errText = errText:gsub("%s+$", "")
    if errText ~= "" then why = why .. " (" .. errText .. ")" end
    return nil, why, true
  end
  res.body = table.concat(res.body)
  return res
end

---------------------------------------------------------------- wget fallback (no luaposix)
function M.wget(opts, u)
  local U = require("shulker.util")
  local args = { "wget", "-q", "-O", "-", "-T", tostring(opts.idle_timeout or 120) }
  for k, v in pairs(opts.headers or {}) do args[#args + 1] = "--header" args[#args + 1] = k .. ": " .. v end
  local bodyfile
  if opts.body then
    bodyfile = os.tmpname()
    U.write(bodyfile, opts.body, "600")
    args[#args + 1] = "--post-file" args[#args + 1] = bodyfile
  end
  args[#args + 1] = opts.url
  for i, a in ipairs(args) do args[i] = U.q(a) end
  local out, code = U.capture(table.concat(args, " "))
  if bodyfile then os.remove(bodyfile) end
  if code ~= 0 then
    local st = tonumber(out:match("HTTP/%S+%s+(%d%d%d)") or "")
    return nil, "wget failed: " .. U.trim(out):sub(1, 200), st == nil or st == 429 or (st or 0) >= 500
  end
  if opts.on_head then opts.on_head(200, {}) end
  if opts.on_data then opts.on_data(out) return { status = 200, headers = {}, body = "" } end
  return { status = 200, headers = {}, body = out }
end

return M
