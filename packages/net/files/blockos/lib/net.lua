--- BlockOS networking API, available as `blockos.net` while the net service runs.
--
-- Built on rednet (see CLAUDE.md):
--
-- * Names are registered and looked up with rednet.host / rednet.lookup under
--   the "blockos" protocol.
-- * The peer table adds what rednet lacks, liveness and metadata, from regular
--   "blockos.announce" broadcasts.
--
-- Announces are wire events (see wire.lua) with topic "announce".
-- @module net

local config = import("config")
local device = import("device")
local log = import("log")
local wire = import("wire")

local net = {}

net.HOST_PROTOCOL = "blockos"
net.ANNOUNCE_PROTOCOL = "blockos.announce"
net.RENAME_EVENT = "blockos_net_rename"

--- Seconds without an announce before a peer is forgotten.
net.PEER_EXPIRY_SECONDS = 90

local MAX_HOSTNAME_LENGTH = 32 -- the computer label limit

config.define("blockos.net.hostname", {
  description = "Hostname on the BlockOS network (default: the label, or pc-<id>).",
  type = "string",
})
config.define("blockos.net.announce_interval", {
  description = "Seconds between peer announcements.",
  default = 300,
  type = "number",
})

local state = {
  hostname = nil,
  is_online = false,
  peers = {}, -- [computer id] = peer record
  info = {},  -- extra fields for our own announcements
  directory = nil,
  resolve_cache = {},
}

local function copy_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

--- Normalise a hostname: lower case, letters, digits, "-" and "_" only. "." is
-- reserved for the domain suffix (e.g. storage.home).
-- @param name
-- @treturn string|nil nil if nothing usable is left.
function net.sanitize(name)
  if type(name) ~= "string" then
    return nil
  end
  local clean = name:lower():gsub("[^%w%-_]", "-"):sub(1, MAX_HOSTNAME_LENGTH)
  if clean == "" or clean == "localhost" then
    return nil
  end
  return clean
end

--- The configured hostname, else the computer label, else pc-<id> / turtle-<id>.
-- @treturn string
function net.default_hostname()
  local configured = net.sanitize(config.get("blockos.net.hostname"))
  if configured then
    return configured
  end
  local from_label = net.sanitize(os.getComputerLabel())
  if from_label then
    return from_label
  end
  local prefix = device.kind() == "turtle" and "turtle-" or "pc-"
  return prefix .. os.getComputerID()
end

--- @treturn string|nil This device's hostname.
function net.hostname()
  return state.hostname
end

--- @treturn boolean True when at least one modem is open.
function net.is_online()
  return state.is_online
end

--- Record the hostname (called by the net service).
-- @tparam string name
function net.set_current_hostname(name)
  state.hostname = name
end

--- Record whether a modem is open (called by the net service).
-- @tparam boolean is_online
function net.set_online(is_online)
  state.is_online = is_online
end

--- Rename this device. The net service re-registers the name with rednet.
-- @tparam string name
-- @treturn[1] string The cleaned-up name.
-- @treturn[2] nil
-- @treturn[2] string error message
function net.rename(name)
  local clean = net.sanitize(name)
  if not clean then
    return nil, "invalid hostname"
  end
  config.set("blockos.net.hostname", clean)
  os.queueEvent(net.RENAME_EVENT, clean)
  return clean
end

--- Attach extra information to this device's announcements (e.g. turtle fuel).
-- @tparam string key
-- @param value Any serialisable value; nil removes it.
function net.set_info(key, value)
  state.info[key] = value
end

--- Payload of an announce event (see wire.lua).
net.ANNOUNCE_SCHEMA = {
  hostname = { type = "string", max = MAX_HOSTNAME_LENGTH },
  kind = { type = "string", optional = true },
  version = { type = "string", optional = true },
  services = { type = "table", optional = true },
  info = { type = "table", optional = true },
  hello = { type = "boolean", optional = true },
}

--- Build this device's announce event.
-- @tparam[opt] boolean is_hello Ask receivers to answer straight away.
-- @treturn table A wire event with topic "announce".
function net.build_announce(is_hello)
  local running = {}
  if blockos and blockos.services then
    running = blockos.services.running()
  end
  return wire.event("announce", {
    hostname = state.hostname,
    kind = device.kind(),
    version = blockos and blockos.version,
    services = running,
    info = copy_table(state.info),
    hello = is_hello or nil,
  })
end

--- The announce payload of a message, if it is a valid announce event.
-- @param message
-- @treturn table|nil
function net.parse_announce(message)
  local event = wire.parse(message, "event", net.ANNOUNCE_SCHEMA)
  if not event or event.topic ~= "announce" or event.data.hostname == "" then
    return nil
  end
  return event.data
end

--- Record an announce. Liveness uses the local receive time; the sender's
-- clock is never trusted.
-- @tparam number sender Computer ID.
-- @param message
-- @tparam[opt] number now Defaults to os.clock().
-- @treturn table|nil The announce payload, or nil if the message was invalid.
function net.handle_announce(sender, message, now)
  local announce = net.parse_announce(message)
  if not announce then
    return nil
  end
  for id, peer in pairs(state.peers) do
    if id ~= sender and peer.hostname == announce.hostname then
      log.warn("net", "duplicate hostname %s used by #%d and #%d", peer.hostname, id, sender)
    end
  end
  state.peers[sender] = {
    id = sender,
    hostname = announce.hostname,
    kind = announce.kind or "?",
    version = announce.version or "?",
    services = announce.services or {},
    info = announce.info or {},
    last_seen = now or os.clock(),
  }
  return announce
end

--- Forget peers that have not announced recently.
-- @tparam[opt] number now
function net.prune(now)
  now = now or os.clock()
  for id, peer in pairs(state.peers) do
    if now - peer.last_seen > net.PEER_EXPIRY_SECONDS then
      state.peers[id] = nil
    end
  end
end

--- Live peers, sorted by hostname.
-- @tparam[opt] number now
-- @treturn {table...} { id, hostname, kind, version, services, info, age }
function net.peers(now)
  now = now or os.clock()
  net.prune(now)
  local peers = {}
  for _, peer in pairs(state.peers) do
    local copy = copy_table(peer)
    copy.age = now - peer.last_seen
    peers[#peers + 1] = copy
  end
  table.sort(peers, function(a, b) return a.hostname < b.hostname end)
  return peers
end

------------------------------------------------------------------------------
-- Directory (domain controller)
--
-- When the computer has joined a domain, the domain package sets a directory:
--   name()             the domain name, e.g. "home"
--   resolve(hostname)  -> computer ID, or nil and an error message
--   list_hosts()       -> { { hostname, id, kind, version, info, age }, ... }
-- Lookups then ask the controller instead of broadcasting, and periodic
-- announces stop.
------------------------------------------------------------------------------

local RESOLVE_CACHE_SECONDS = 60

--- @tparam table|nil directory
function net.set_directory(directory)
  state.directory = directory
  state.resolve_cache = {}
end

--- @treturn table|nil The directory, when joined to a domain.
function net.directory()
  return state.directory
end

--- This device's full name, with the domain suffix when joined (e.g. storage.home).
-- @treturn string|nil
function net.full_hostname()
  if state.hostname and state.directory then
    return state.hostname .. "." .. state.directory.name()
  end
  return state.hostname
end

-- "storage.home" -> "storage" when "home" is our domain.
local function short_name(name)
  local lowered = name:lower()
  local directory = state.directory
  if directory then
    local suffix = "." .. directory.name()
    if #lowered > #suffix and lowered:sub(-#suffix) == suffix then
      lowered = lowered:sub(1, -#suffix - 1)
    end
  end
  return net.sanitize(lowered) or lowered
end

--- Find the computer ID for a hostname (short, or full with the domain suffix).
--
-- Asks the domain controller when joined (answers are cached for a minute),
-- then the local peer table, then rednet.lookup (a broadcast that waits about
-- two seconds).
-- @tparam string name
-- @treturn number|nil
function net.resolve(name)
  local short = short_name(name)
  if short == state.hostname then
    return os.getComputerID()
  end

  local cached = state.resolve_cache[short]
  if cached and os.clock() - cached.time < RESOLVE_CACHE_SECONDS then
    return cached.id
  end
  if state.directory then
    local id = state.directory.resolve(short)
    if id then
      state.resolve_cache[short] = { id = id, time = os.clock() }
      return id
    end
  end

  for _, peer in ipairs(net.peers()) do
    if peer.hostname == short then
      return peer.id
    end
  end
  if not rednet.isOpen() then
    return nil
  end
  return rednet.lookup(net.HOST_PROTOCOL, short)
end

--- Forget all state (tests).
function net.reset()
  state = {
    hostname = nil,
    is_online = false,
    peers = {},
    info = {},
    directory = nil,
    resolve_cache = {},
  }
end

return net
