--- BlockOS networking API, available as `blockos.net` while the net service runs.
--
-- Built on rednet (see CLAUDE.md):
--
-- * Names are registered and looked up with rednet.host / rednet.lookup under
--   the "blockos" protocol.
-- * The peer table adds what rednet lacks, liveness and metadata, from regular
--   "blockos.announce" broadcasts.
--
-- Wire messages are tables with a `v` field (wire version). Unknown fields are
-- ignored and messages with a newer major version are dropped.
-- @module net

local config = import("config")
local device = import("device")
local log = import("log")

local net = {}

net.HOST_PROTOCOL = "blockos"
net.ANNOUNCE_PROTOCOL = "blockos.announce"
net.RENAME_EVENT = "blockos_net_rename"
net.WIRE_VERSION = 1

--- Seconds without an announce before a peer is forgotten.
net.PEER_EXPIRY_SECONDS = 90

local MAX_HOSTNAME_LENGTH = 32 -- the computer label limit

config.define("blockos.net.hostname", {
  description = "Hostname on the BlockOS network (default: the label, or pc-<id>).",
  type = "string",
})
config.define("blockos.net.announce_interval", {
  description = "Seconds between peer announcements.",
  default = 30,
  type = "number",
})

local state = {
  hostname = nil,
  is_online = false,
  peers = {}, -- [computer id] = peer record
  info = {},  -- extra fields for our own announcements
}

local function copy_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

--- Normalise a hostname: lower case, letters, digits, "-", "_" and "." only.
-- @param name
-- @treturn string|nil nil if nothing usable is left.
function net.sanitize(name)
  if type(name) ~= "string" then
    return nil
  end
  local clean = name:lower():gsub("[^%w%-_%.]", "-"):sub(1, MAX_HOSTNAME_LENGTH)
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

--- Build this device's announce message.
-- @tparam[opt] boolean is_hello Ask receivers to answer straight away.
-- @treturn table
function net.build_announce(is_hello)
  local running = {}
  if blockos and blockos.services then
    running = blockos.services.running()
  end
  return {
    v = net.WIRE_VERSION,
    hostname = state.hostname,
    kind = device.kind(),
    version = blockos and blockos.version,
    services = running,
    info = copy_table(state.info),
    hello = is_hello or nil,
  }
end

--- Check that a message is an announce this version understands.
-- @param message
-- @treturn boolean
function net.is_valid_announce(message)
  if type(message) ~= "table" then
    return false
  end
  local version = message.v
  if type(version) ~= "number" or version < 1 or math.floor(version) > net.WIRE_VERSION then
    return false
  end
  local hostname = message.hostname
  if type(hostname) ~= "string" or #hostname == 0 or #hostname > MAX_HOSTNAME_LENGTH then
    return false
  end
  if message.info ~= nil and type(message.info) ~= "table" then
    return false
  end
  if message.services ~= nil and type(message.services) ~= "table" then
    return false
  end
  return true
end

local function text_or_unknown(value)
  if type(value) == "string" then
    return value
  end
  return "?"
end

--- Record an announce. Liveness uses the local receive time; the sender's
-- clock is never trusted.
-- @tparam number sender Computer ID.
-- @param message
-- @tparam[opt] number now Defaults to os.clock().
-- @treturn boolean False if the message was invalid.
function net.handle_announce(sender, message, now)
  if not net.is_valid_announce(message) then
    return false
  end
  for id, peer in pairs(state.peers) do
    if id ~= sender and peer.hostname == message.hostname then
      log.warn("net", "duplicate hostname %s used by #%d and #%d", peer.hostname, id, sender)
    end
  end
  state.peers[sender] = {
    id = sender,
    hostname = message.hostname,
    kind = text_or_unknown(message.kind),
    version = text_or_unknown(message.version),
    services = message.services or {},
    info = message.info or {},
    last_seen = now or os.clock(),
  }
  return true
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

--- Find the computer ID for a hostname.
--
-- Checks the peer table first, then falls back to rednet.lookup (which waits
-- about two seconds for answers).
-- @tparam string name
-- @treturn number|nil
function net.resolve(name)
  name = net.sanitize(name) or name
  if name == state.hostname then
    return os.getComputerID()
  end
  for _, peer in ipairs(net.peers()) do
    if peer.hostname == name then
      return peer.id
    end
  end
  if not rednet.isOpen() then
    return nil
  end
  return rednet.lookup(net.HOST_PROTOCOL, name)
end

--- Forget all state (tests).
function net.reset()
  state = { hostname = nil, is_online = false, peers = {}, info = {} }
end

return net
