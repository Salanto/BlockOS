--- Request/response calls between computers, built on rednet.
--
-- rednet.send / rednet_message events carry the messages. Rednet itself has no
-- request/response, so this module only adds what is missing: matching a reply
-- to its request, timeouts and retries, and a server loop that can handle
-- several requests at once.
--
-- Request:  { v = 1, id, op, args, token?, computer_token? }
-- Response: { v = 1, reply_to = id, ok = true, result }
--       or  { v = 1, reply_to = id, ok = false, error }
--
-- Handlers return a result, or nil and an error message. A handler that has
-- nothing to return should return true.
-- @module rpc

local rpc = {}

rpc.WIRE_VERSION = 1
rpc.DEFAULT_TIMEOUT = 3
rpc.DEFAULT_RETRIES = 1
rpc.LOGIN_REQUIRED = "login required"
rpc.PERMISSION_DENIED = "permission denied"

local MAX_WORKERS = 16

local request_counter = 0

-- Swappable so tests can run client and server in one computer.
local transport = {
  send = function(recipient, message, protocol)
    rednet.send(recipient, message, protocol)
  end,
}

-- Set by the domain package: the token of the joined computer, and how to look
-- up the user behind a token.
local computer_token_provider = function() return nil end
local user_validator = function() return nil, "this computer is not in a domain" end
local computer_validator = function() return nil, "this computer is not in a domain" end

--- Replace how messages are sent (tests use a loopback transport).
-- @tparam table new_transport { send = function(recipient, message, protocol) }
function rpc.set_transport(new_transport)
  transport = new_transport
end

--- A transport that delivers every message to this computer (for tests).
-- @treturn table
function rpc.loopback_transport()
  return {
    send = function(_, message, protocol)
      os.queueEvent("rednet_message", os.getComputerID(), message, protocol)
    end,
  }
end

--- Use rednet again.
function rpc.use_rednet()
  rpc.set_transport({
    send = function(recipient, message, protocol)
      rednet.send(recipient, message, protocol)
    end,
  })
end

--- Set where the joined computer's token comes from.
-- @tparam function provider Returns the token or nil.
function rpc.set_computer_token_provider(provider)
  computer_token_provider = provider
end

--- Set how user tokens are checked (normally: ask the domain controller).
-- @tparam function validator validator(token) -> { name, groups } or nil, err
function rpc.set_user_validator(validator)
  user_validator = validator
end

--- Set how computer tokens are checked (normally: ask the domain controller).
-- @tparam function validator validator(computer_token) -> { hostname } or nil, err
function rpc.set_computer_validator(validator)
  computer_validator = validator
end

local function new_request_id()
  request_counter = request_counter + 1
  return string.format("%d-%d-%d", os.getComputerID(), request_counter, math.random(0, 999999))
end

local function current_user_token()
  return blockos and blockos.user and blockos.user.token
end

--- @param message
-- @treturn boolean True if `message` is a request this version understands.
function rpc.is_request(message)
  return type(message) == "table"
    and message.v == rpc.WIRE_VERSION
    and type(message.id) == "string"
    and type(message.op) == "string"
    and message.reply_to == nil
end

--- @param message
-- @treturn boolean True if `message` is a response this version understands.
function rpc.is_response(message)
  return type(message) == "table"
    and message.v == rpc.WIRE_VERSION
    and type(message.reply_to) == "string"
    and type(message.ok) == "boolean"
end

local function wait_for_reply(request_id, protocol, timeout)
  local timer = os.startTimer(timeout)
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
      return nil
    end
    local is_reply = event == "rednet_message" and c == protocol
      and rpc.is_response(b) and b.reply_to == request_id
    if is_reply then
      os.cancelTimer(timer)
      return b
    end
  end
end

--- Call an operation on another computer and wait for the answer.
-- @tparam number server_id Computer ID.
-- @tparam string protocol e.g. "blockos.domain"
-- @tparam string op
-- @param[opt] args Any serialisable value.
-- @tparam[opt] table options { timeout, retries, token, computer_token }
-- @return[1] The result.
-- @treturn[2] nil
-- @treturn[2] string error message
function rpc.call(server_id, protocol, op, args, options)
  options = options or {}
  local timeout = options.timeout or rpc.DEFAULT_TIMEOUT
  local attempts = 1 + (options.retries or rpc.DEFAULT_RETRIES)
  local request = {
    v = rpc.WIRE_VERSION,
    id = new_request_id(),
    op = op,
    args = args,
    token = options.token or current_user_token(),
    computer_token = options.computer_token or computer_token_provider(),
  }

  for _ = 1, attempts do
    transport.send(server_id, request, protocol)
    local response = wait_for_reply(request.id, protocol, timeout)
    if response then
      if not response.ok then
        return nil, tostring(response.error)
      end
      if response.result == nil then
        return true
      end
      return response.result
    end
  end
  return nil, "no answer from computer #" .. tostring(server_id)
end

--- Find a server by protocol (and optionally name) with rednet.lookup.
-- Only used to find the domain controller, and when there is no domain.
-- @tparam string protocol
-- @tparam[opt] string name
-- @treturn number|nil Computer ID.
function rpc.find(protocol, name)
  if not rednet.isOpen() then
    return nil
  end
  if name then
    return rednet.lookup(protocol, name)
  end
  return (rednet.lookup(protocol))
end

--- Run one request through a handler table and build the response.
-- @tparam table handlers { [op] = function(request_ctx, args) }
-- @tparam number sender
-- @tparam table request
-- @treturn table The response.
function rpc.handle(handlers, sender, request)
  local function respond(ok, value)
    local response = { v = rpc.WIRE_VERSION, reply_to = request.id, ok = ok }
    if ok then
      response.result = value
    else
      response.error = value
    end
    return response
  end

  local handler = handlers[request.op]
  if type(handler) ~= "function" then
    return respond(false, "unknown operation: " .. request.op)
  end
  local request_ctx = {
    sender = sender,
    token = request.token,
    computer_token = request.computer_token,
  }
  local ran, result, err = pcall(handler, request_ctx, request.args)
  if not ran then
    return respond(false, tostring(result))
  end
  if result == nil then
    return respond(false, err or "failed")
  end
  return respond(true, result)
end

--- Serve requests forever.
--
-- Every request runs in its own coroutine, so a handler that waits (for example
-- to check a token with the domain controller) does not block other requests.
-- @tparam string protocol
-- @tparam table handlers { [op] = function(request_ctx, args) }
function rpc.serve(protocol, handlers)
  local workers = {}

  local function resume(worker, ...)
    local ok, filter = coroutine.resume(worker.coroutine, ...)
    if not ok or coroutine.status(worker.coroutine) == "dead" then
      return false
    end
    worker.filter = filter
    return true
  end

  local function start_worker(sender, request)
    if #workers >= MAX_WORKERS then
      local busy = {
        v = rpc.WIRE_VERSION, reply_to = request.id, ok = false, error = "server busy",
      }
      transport.send(sender, busy, protocol)
      return
    end
    local worker = {
      coroutine = coroutine.create(function()
        transport.send(sender, rpc.handle(handlers, sender, request), protocol)
      end),
    }
    if resume(worker) then
      workers[#workers + 1] = worker
    end
  end

  while true do
    local event = table.pack(os.pullEventRaw())
    if event[1] == "terminate" then
      error("Terminated", 0)
    end

    local still_running = {}
    for _, worker in ipairs(workers) do
      local wants_event = worker.filter == nil or worker.filter == event[1]
      if not wants_event or resume(worker, table.unpack(event, 1, event.n)) then
        still_running[#still_running + 1] = worker
      end
    end
    workers = still_running

    local is_request = event[1] == "rednet_message" and event[4] == protocol
      and rpc.is_request(event[3])
    if is_request then
      start_worker(event[2], event[3])
    end
  end
end

--- Check that a request comes from a logged-in user, optionally in some groups.
--
-- The token is checked with the domain controller on every request: there is no
-- cache, so logouts and group changes take effect immediately.
-- @tparam table request_ctx
-- @tparam[opt] {string...} groups The user must be in at least one of these.
-- @treturn[1] table The user { name, groups }.
-- @treturn[2] nil
-- @treturn[2] string rpc.LOGIN_REQUIRED or rpc.PERMISSION_DENIED
function rpc.require_user(request_ctx, groups)
  if type(request_ctx.token) ~= "string" then
    return nil, rpc.LOGIN_REQUIRED
  end
  local user = user_validator(request_ctx.token)
  if not user then
    return nil, rpc.LOGIN_REQUIRED
  end
  if not groups or #groups == 0 then
    return user
  end
  for _, wanted in ipairs(groups) do
    for _, group in ipairs(user.groups or {}) do
      if group == wanted then
        return user
      end
    end
  end
  return nil, rpc.PERMISSION_DENIED
end

--- Check that a request comes from a computer joined to the domain.
--
-- For headless system-to-system calls (e.g. a crafting computer asking a
-- storage computer for stock): the caller's computer token is checked with the
-- domain controller on every request.
-- @tparam table request_ctx
-- @treturn[1] table { hostname }
-- @treturn[2] nil
-- @treturn[2] string error message
function rpc.require_computer(request_ctx)
  if type(request_ctx.computer_token) ~= "string" then
    return nil, "the calling computer is not in a domain"
  end
  local computer = computer_validator(request_ctx.computer_token)
  if not computer then
    return nil, "unknown computer"
  end
  return computer
end

return rpc
