-- Shulker Linux: the kernel and the whole system image, plus the computer's extra drives.
--
-- OC2's firmware loads /boot/Image from the first drive's ext2, so a kernel upgrade is one file.
-- The full system (a 16 MB drive image) cannot be rewritten under the running system, so it goes to
-- another drive; then you swap the drives. Images live in the repository under linux/dist/:
--   Image  rootfs.ext2.gz  SHA256SUMS  (sums of Image and the unpacked rootfs.ext2)
local U = require("shulker.util")
local pkg = require("shulker.pkg")

local M = {}

function M.base() return pkg.base() .. "/linux/dist" end

function M.osName()
  for _, l in ipairs(U.lines("/etc/os-release")) do
    local v = l:match('^PRETTY_NAME="?(.-)"?$')
    if v then return v end
  end
  return "Linux"
end

-- mdadm: part of Shulker Linux, or the `mdadm` app on stock Sedna (/usr/local/bin is not on the boot PATH)
function M.mdadm()
  return U.which("mdadm") or (U.exists("/usr/local/bin/mdadm") and "/usr/local/bin/mdadm") or nil
end

function M.isShulkerLinux() return M.osName():match("^Shulker Linux") ~= nil end
function M.hasMD() return U.exists("/proc/mdstat") end

---------------------------------------------------------------- drives
local function sysread(p) return U.trim(U.read(p) or "") end

-- the drive mounted at /. /proc/mounts often says /dev/root, so match the device number instead
function M.rootDev()
  for _, l in ipairs(U.lines("/proc/self/mountinfo")) do
    local majmin, mnt = l:match("^%S+%s+%S+%s+(%d+:%d+)%s+%S+%s+(%S+)")
    if mnt == "/" then
      local ls = U.capture("ls /sys/block 2>/dev/null")
      for name in ls:gmatch("%S+") do
        if sysread("/sys/block/" .. name .. "/dev") == majmin then return "/dev/" .. name end
      end
    end
  end
  for _, l in ipairs(U.lines("/proc/mounts")) do
    local dev, mnt = l:match("^(%S+)%s+(%S+)")
    if mnt == "/" and dev:match("^/dev/vd") then return dev end
  end
  return "/dev/vda"   -- OC2 always boots from the first drive
end

function M.mounts()
  local m = {}
  for _, l in ipairs(U.lines("/proc/mounts")) do
    local dev, mnt = l:match("^(%S+)%s+(%S+)")
    if dev then m[dev] = mnt end
  end
  return m
end

-- {name, dev, kb, mount, root, md}
function M.drives()
  local out = {}
  local mounts, root = M.mounts(), M.rootDev()
  local mdOf = {}
  for _, l in ipairs(U.lines("/proc/mdstat")) do
    local md, rest = l:match("^(md%d+)%s*:%s*(.*)$")
    if md then for d in rest:gmatch("(vd%a+)%[") do mdOf["/dev/" .. d] = md end end
  end
  local ls = U.capture("ls /sys/block 2>/dev/null")
  for name in ls:gmatch("%S+") do
    if name:match("^vd%a+$") or name:match("^md%d+$") then
      local dev = "/dev/" .. name
      out[#out + 1] = {
        name = name, dev = dev, kb = math.floor((tonumber(sysread("/sys/block/" .. name .. "/size")) or 0) / 2),
        mount = mounts[dev], root = dev == root, md = mdOf[dev],
      }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- drives that hold nothing we know of: not root, not mounted, not in an array
function M.spare()
  local s = {}
  for _, d in ipairs(M.drives()) do
    -- an empty disk drive (floppy slot) shows up as a 0 KB drive: skip anything under 1 MB
    if d.name:match("^vd") and not d.root and d.name ~= "vda" and not d.mount and not d.md and d.kb >= 1024 then
      s[#s + 1] = d
    end
  end
  return s
end

---------------------------------------------------------------- downloads
local function sums()
  local text, err = pkg.fetchText(M.base() .. "/SHA256SUMS")
  if not text then return nil, err end
  local s = {}
  for sum, name in text:gmatch("(%x+)%s+%*?(%S+)") do s[name] = sum:lower() end
  if not s.Image or not s["rootfs.ext2"] then return nil, "SHA256SUMS lists no Image / rootfs.ext2" end
  return s
end

-- kernel upgrade: /boot/Image on the running system's drive
function M.upgradeKernel(log)
  local s, err = sums()
  if not s then return nil, err end
  local cur = pkg.sha256("/boot/Image")
  if cur == s.Image then return true, "the kernel is already current" end
  local tmp = "/tmp/shulker-Image"
  log("downloading the kernel")
  local ok, ferr = pkg.fetch(M.base() .. "/Image", tmp)
  if not ok then return nil, ferr end
  if pkg.sha256(tmp) ~= s.Image then os.remove(tmp) return nil, "the downloaded kernel does not match SHA256SUMS" end
  local newKB = math.ceil((U.capture("wc -c < " .. tmp):match("%d+") or 0) / 1024)
  local oldKB = math.ceil((U.capture("wc -c < /boot/Image"):match("%d+") or 0) / 1024)
  if newKB - oldKB > (pkg.freeKB("/boot") or 0) - 64 then
    os.remove(tmp) return nil, "not enough room in /boot for the new kernel"
  end
  -- not enough room for two kernels on an 8 MB drive: keep the old one in RAM, write in place
  local keep = "/tmp/shulker-Image.old"
  U.capture("cp /boot/Image " .. keep)
  log("writing /boot/Image")
  U.capture("cat " .. tmp .. " > /boot/Image && sync")
  if pkg.sha256("/boot/Image") ~= s.Image then
    U.capture("cat " .. keep .. " > /boot/Image && sync")
    os.remove(tmp)
    return nil, "writing the kernel failed; the old kernel was put back"
  end
  os.remove(tmp)
  os.remove(keep)
  return true, "kernel upgraded: reboot to use it"
end

-- what we carry over from the running system to a fresh image
M.CARRY = {
  "/root", "/etc/shulker", "/etc/shadow", "/etc/passwd", "/etc/group", "/etc/hostname",
  "/etc/network/interfaces", "/etc/dropbear", "/etc/profile.d/shulker.sh",
}

-- write the full Shulker Linux image to DEV (whole drive), then carry the settings over
function M.installTo(dev, log)
  local found
  for _, d in ipairs(M.spare()) do if d.dev == dev then found = d end end
  if not found then return nil, dev .. " is not a free drive (see `shulker disks`)" end
  if found.kb < 16384 then return nil, dev .. " is too small: Shulker Linux needs a 16 MB drive" end
  local s, err = sums()
  if not s then return nil, err end
  log("downloading and writing Shulker Linux to " .. dev .. " (16 MB)")
  local url = M.base() .. "/rootfs.ext2.gz"
  local get = pkg.verifiedTLS() and "curl -fsSL --max-time 600 %s" or "wget -q -T 60 -O - %s"
  local out, code = U.capture(("set -o pipefail 2>/dev/null; " .. get .. " | gunzip -c | dd of=%s bs=64k 2>&1")
    :format(U.q(url), dev))
  if code ~= 0 then return nil, "writing failed: " .. U.trim(out:gsub("wget: note: TLS certificate validation not implemented\n?", "")) end
  U.capture("sync")
  log("verifying")
  local got = U.capture(("dd if=%s bs=1024 count=16384 2>/dev/null | sha256sum"):format(dev)):match("^(%x+)")
  if got ~= s["rootfs.ext2"] then return nil, "the written image does not match SHA256SUMS (got " .. tostring(got) .. ")" end
  log("carrying over your files and settings")
  local mnt = "/tmp/shulker-newroot"
  U.mkdir(mnt)
  local _, mc = U.capture(("mount -t ext2 %s %s"):format(dev, mnt))
  if mc ~= 0 then return nil, "could not mount the new system" end
  for _, p in ipairs(M.CARRY) do
    if U.exists(p) then
      local parent = mnt .. p:match("^(.*)/[^/]+$")
      U.capture(("mkdir -p %s && cp -a %s %s/"):format(U.q(parent), U.q(p), U.q(parent)))
    end
  end
  -- Shulker OS settings (Claude key, tasks) live in /root and /etc/shulker: both carried above
  U.capture("sync; umount " .. mnt)
  return true
end

---------------------------------------------------------------- making node drives (the disk maker)
-- `shulker mkdisk`: write the slim system (stock Sedna without MicroPython and tcc, with the RAID kernel
-- and mdadm) onto blank drives, then this computer's own Shulker OS on top, set up as KIND:
--   node   "Lab": joins the swarm main at 10.42.0.1 by itself and turns its other drives into /data
--   drone  "Robot": joins through its drone base, reports battery and position, goes home to charge
--   plain  the setup wizard runs at the first login (for a main or a personal computer)
M.SLIM_KB = 8192

local function verifyImage(dev, kb, want)
  local got = U.capture(("dd if=%s bs=1024 count=%d 2>/dev/null | sha256sum"):format(dev, kb)):match("^(%x+)")
  return got == want, got
end

local function installShulker(mnt, kind)
  local home = U.home()
  local function sh(cmd) local out, code = U.capture(cmd) if code ~= 0 then error(U.trim(out), 0) end end
  sh(("mkdir -p %s/opt/shulker %s/etc/shulker/crontabs %s/etc/profile.d %s/etc/init.d")
    :format(mnt, mnt, mnt, mnt))
  sh(("cp -a %s/. %s/opt/shulker/"):format(U.q(home), mnt))
  sh(("cp %s/etc/profile.sh %s/etc/profile.d/shulker.sh"):format(U.q(home), mnt))
  sh(("cp %s/etc/rc.shulker %s/etc/init.d/S95shulker && chmod 755 %s/etc/init.d/S95shulker"):format(U.q(home), mnt, mnt))
  sh(("cp %s/share/issue %s/etc/issue && cp %s/share/motd %s/etc/motd"):format(U.q(home), mnt, U.q(home), mnt))
  U.write(mnt .. "/etc/shulker/repo.conf", ("repo=%s\nbranch=main\n"):format(pkg.DEFAULT_REPO))
  if kind == "node" or kind == "drone" then
    -- a lab node talks to the main directly; a robot reaches it through its drone base (its gateway)
    local leader = kind == "node" and "10.42.0.1" or "auto"
    U.write(mnt .. "/etc/shulker/swarm.conf", ("# Shulker Swarm (see `man swarm`)\nleader=%s\nport=4242\nrole=worker\n"):format(leader))
    sh("chmod 600 " .. mnt .. "/etc/shulker/swarm.conf")
    U.write(mnt .. "/etc/shulker/setup.conf", ("# a %s drive (shulker mkdisk): no setup wizard\nrole=%s\nclaude=off\n")
      :format(kind == "node" and "Shulker Lab" or "Shulker Robot", kind == "node" and "worker" or "drone"))
    U.write(mnt .. "/etc/network/interfaces", "auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n")
  end
  if kind == "node" then
    -- first start: the computer's other drives become one /data (rc.shulker, `shulker disks setup --yes`)
    U.write(mnt .. "/etc/shulker/autodisks", "made by shulker mkdisk " .. os.date("%Y-%m-%d") .. "\n")
  end
end

-- devs: list of drive entries from M.spare(); returns the number written
function M.makeDisks(devs, kind, log)
  local s, err = sums()
  if not s then return nil, err end
  local want = s["sedna-slim.img"]
  if not want then return nil, "the repository has no sedna-slim.img yet" end
  for _, d in ipairs(devs) do
    if d.kb < M.SLIM_KB then return nil, ("%s is %d KB: a node drive needs 8 MB"):format(d.dev, d.kb) end
  end
  -- the first drive from the internet, the others copied from it (much faster than downloading again)
  local first = devs[1].dev
  log(("downloading the slim system and writing it to %s"):format(first))
  local get = pkg.verifiedTLS() and "curl -fsSL --max-time 600 %s" or "wget -q -T 60 -O - %s"
  local out, code = U.capture(("set -o pipefail 2>/dev/null; " .. get .. " | gunzip -c | dd of=%s bs=64k 2>&1")
    :format(U.q(M.base() .. "/sedna-slim.img.gz"), first))
  if code ~= 0 then return nil, "writing failed: " .. U.trim(out:gsub("wget: note: TLS certificate validation not implemented\n?", "")) end
  U.capture("sync")
  local ok, got = verifyImage(first, M.SLIM_KB, want)
  if not ok then return nil, ("%s does not match SHA256SUMS (got %s): try again"):format(first, tostring(got):sub(1, 12)) end
  for i = 2, #devs do
    log(("copying it to %s"):format(devs[i].dev))
    local o, c = U.capture(("dd if=%s of=%s bs=64k count=128 2>&1 && sync"):format(first, devs[i].dev))
    if c ~= 0 then return nil, U.trim(o) end
    if not verifyImage(devs[i].dev, M.SLIM_KB, want) then return nil, devs[i].dev .. ": the copy does not match" end
  end
  local mnt = "/tmp/shulker-mkdisk"
  U.mkdir(mnt)
  for _, d in ipairs(devs) do
    log(("installing Shulker OS %s on %s (%s)"):format(U.trim(U.read(U.home() .. "/VERSION") or ""), d.dev, kind))
    local o, c = U.capture(("mount -t ext2 %s %s"):format(d.dev, mnt))
    if c ~= 0 then return nil, "cannot mount " .. d.dev .. ": " .. U.trim(o) end
    local okI, ierr = pcall(installShulker, mnt, kind)
    U.capture("sync; umount " .. mnt)
    if not okI then return nil, d.dev .. ": " .. tostring(ierr) end
  end
  return #devs
end

---------------------------------------------------------------- extra drives (/data)
M.DISKS_CONF = "/etc/shulker/disks.conf"

function M.disksConf()
  local c = {}
  for _, l in ipairs(U.lines(M.DISKS_CONF)) do
    local k, v = l:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then c[k] = v end
  end
  return c
end

-- mode: raid0 (striped, all the space), linear (all the space, one after another),
-- raid1 (mirrored), separate (each drive on its own: /data/1, /data/2, ...)
function M.setupDisks(mode, devs, log)
  if #devs == 0 then return nil, "no free drives: put more hard drives in the computer" end
  if mode ~= "separate" and not M.hasMD() then
    return nil, "this kernel has no RAID: run `shulker linux kernel` and reboot (or use --separate)"
  end
  if mode ~= "separate" and not M.mdadm() then return nil, "mdadm is missing: run `shulker install mdadm`" end
  local names = {}
  for _, d in ipairs(devs) do names[#names + 1] = d.dev end
  if mode == "separate" then
    for i, d in ipairs(devs) do
      log(("formatting %s -> /data/%d"):format(d.dev, i))
      local out, code = U.capture(("mke2fs -q -L data%d %s"):format(i, d.dev))
      if code ~= 0 then return nil, U.trim(out) end
    end
  else
    if mode == "raid1" and #devs < 2 then return nil, "a mirror needs at least 2 free drives" end
    local level = mode == "raid0" and "0" or mode == "raid1" and "1" or "linear"
    if #devs == 1 then level = "linear" end
    log(("creating /dev/md0 (%s) from %s"):format(mode, table.concat(names, " ")))
    local out, code = U.capture((U.q(M.mdadm()) .. " --create /dev/md0 --run --metadata=1.2 --level=%s --raid-devices=%d %s")
      :format(level, #devs, table.concat(names, " ")))
    if code ~= 0 then return nil, U.trim(out) end
    log("formatting /dev/md0")
    out, code = U.capture("mke2fs -q -L data /dev/md0")
    if code ~= 0 then return nil, U.trim(out) end
  end
  U.mkdir("/etc/shulker")
  U.write(M.DISKS_CONF, ("# extra drives (`shulker disks`)\nmode=%s\ndevices=%s\n"):format(mode, table.concat(names, " ")))
  local ok, merr = M.mountDisks()
  if not ok then return nil, merr end
  return true
end

-- undo the current /data (before setting it up again): unmount, stop the array, forget it
function M.releaseDisks()
  local c = M.disksConf()
  if not c.mode then return true end
  for dev, mnt in pairs(M.mounts()) do
    if mnt == "/data" or mnt:match("^/data/%d+$") then
      local out, code = U.capture("umount " .. U.q(mnt))
      if code ~= 0 then return nil, ("cannot unmount %s (in use? %s)"):format(mnt, U.trim(out)) end
    end
  end
  if c.mode ~= "separate" and U.exists("/sys/block/md0") and M.mdadm() then
    U.capture(U.q(M.mdadm()) .. " --stop /dev/md0")
    for d in (c.devices or ""):gmatch("%S+") do U.capture(U.q(M.mdadm()) .. " --zero-superblock " .. d) end
  end
  os.remove(M.DISKS_CONF)
  return true
end

-- at boot (rc.shulker) and after setup
function M.mountDisks()
  local c = M.disksConf()
  if not c.mode or not c.devices then return true end
  local devs = {}
  for d in c.devices:gmatch("%S+") do devs[#devs + 1] = d end
  local mounts = M.mounts()
  if c.mode == "separate" then
    for i, d in ipairs(devs) do
      if not mounts[d] then
        U.mkdir("/data/" .. i)
        U.capture(("mount -t ext2 %s /data/%d"):format(d, i))
      end
    end
    return true
  end
  if not M.hasMD() then return nil, "this kernel has no RAID support" end
  if not U.exists("/sys/block/md0/md/array_state") or sysread("/sys/block/md0/md/array_state") == "clear" then
    local out, code = U.capture(U.q(M.mdadm() or "mdadm") .. " --assemble --run /dev/md0 " .. table.concat(devs, " "))
    if code ~= 0 then return nil, "could not assemble /dev/md0: " .. U.trim(out) end
  end
  if not mounts["/dev/md0"] then
    U.mkdir("/data")
    local out, code = U.capture("mount -t ext2 /dev/md0 /data")
    if code ~= 0 then return nil, U.trim(out) end
  end
  return true
end

return M
