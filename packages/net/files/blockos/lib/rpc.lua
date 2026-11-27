--- Request/response calls between computers, built on rednet.
--
-- rednet.send / rednet_message events carry the messages. Rednet itself has no
-- request/response, so this module only adds what is missing: matching a reply
-- to its request, timeouts and retries, and a server loop that can handle
-- several requests at once. Messages use the shared envelope from wire.lua.
--
-- A handler is a function(request_ctx, args); wrap it with rpc.with_args(schema,
-- handler) to have its arguments checked against a wire schema before it runs.
-- Handlers return a result, or nil and an error message. A handler that has
-- nothing to return should return true.
--
-- Retries are safe: a retry resends the same request id. A repeat that arrives while
-- the first copy still runs is dropped (its answer is on the way). Operations marked
-- with rpc.once (moving items, sending mail, driving a turtle) also keep their answer
-- for a while, so a repeat of a finished one gets that answer instead of running
-- again: a lost answer never makes them happen twice. Reads simply run again.
-- @module rpc

local wire = import("wire")

local rpc = {}

rpc.DEFAULT_TIMEOUT = 3
rpc.DEFAULT_RETRIES = 1
rpc.LOGIN_REQUIRED = "login required"
rpc.PERMISSION_DENIED = "permission denied"

local MAX_WORKERS = 16
-- How long a server remembers a request it ran (for repeats), and how many.
local REMEMBER_SECONDS = 120
local MAX_REMEMBERED = 200

-- Handlers marked with rpc.once (weak keys: handler tables can be rebuilt).
local once_handlers = setmetatable({}, { __mode = "k" })

--- Mark a handler whose operation must never run twice for one request (it moves
-- items, sends mail, drives a turtle): its answer is kept for repeats.
-- @tparam function handler
-- @treturn function The same handler.
function rpc.once(handler)
  once_handlers[handler] = true
  return handler
end

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
local relogin_handler = function() return nil end

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

--- Set how an expired login is renewed (the domain package asks the user for
-- their password). Returns the new token or nil.
-- @tparam function handler
function rpc.set_relogin_handler(handler)
  relogin_handler = handler
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

-- Programs act as the logged-in user; services never do (they serve the computer,
-- whoever sits at it), so a service's calls carry only the computer token.
local function current_user_token()
  if import("scheduler").current() then
    return nil
  end
  return blockos and blockos.user and blockos.user.token
end

--- @param message
-- @treturn boolean True if `message` is a request this version understands.
function rpc.is_request(message)
  return wire.parse(message, "request") ~= nil
end

--- @param message
-- @treturn boolean True if `message` is a response this version understands.
function rpc.is_response(message)
  return wire.parse(message, "response") ~= nil
end

-- Everything else that arrives meanwhile is kept for the caller's loop (see events):
-- a service's own timer or an alert must not get lost while it waits for an answer.
local function wait_for_reply(request_id, protocol, timeout)
  local events = import("events")
  local timer = os.startTimer(timeout)
  while true do
    local event = table.pack(os.pullEvent())
    local name, a, b, c = event[1], event[2], event[3], event[4]
    if name == "timer" and a == timer then
      return nil
    end
    local is_reply = name == "rednet_message" and c == protocol
      and rpc.is_response(b) and b.reply_to == request_id
    if is_reply then
      os.cancelTimer(timer)
      return b
    end
    events.keep(table.unpack(event, 1, event.n))
  end
end

local function send_and_wait(server_id, protocol, request, timeout, attempts)
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

--- Call an operation on another computer and wait for the answer.
-- @tparam number server_id Computer ID.
-- @tparam string protocol e.g. "blockos.domain"
-- @tparam string op
-- @param[opt] args Any serialisable value.
-- @tparam[opt] table options { timeout, retries, token, computer_token, relogin }.
--   With `relogin`, an expired login asks the user for their password once and
--   retries (only for programs the user is running, never for services).
-- @return[1] The result.
-- @treturn[2] nil
-- @treturn[2] string error message
function rpc.call(server_id, protocol, op, args, options)
  options = options or {}
  local timeout = options.timeout or rpc.DEFAULT_TIMEOUT
  local attempts = 1 + (options.retries or rpc.DEFAULT_RETRIES)
  local token = options.token or current_user_token()
  local request = wire.request(new_request_id(), op, args, token,
    options.computer_token or computer_token_provider())

  local result, err = send_and_wait(server_id, protocol, request, timeout, attempts)
  if result or err ~= rpc.LOGIN_REQUIRED or not (options.relogin and token) then
    return result, err
  end
  local new_token = relogin_handler()
  if not new_token then
    return nil, err
  end
  request = wire.request(new_request_id(), op, args, new_token, request.computer_token)
  return send_and_wait(server_id, protocol, request, timeout, attempts)
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

--- Wrap a handler so its arguments are checked against a wire schema first.
--
--   handlers.resolve = rpc.with_args({ hostname = "string" }, function(ctx, args)
--     ...  -- args.hostname is a string here
--   end)
-- @tparam table schema See wire.validate.
-- @tparam function handler function(request_ctx, args)
-- @treturn function
function rpc.with_args(schema, handler)
  return function(request_ctx, args)
    local ok, problem = wire.validate(args or {}, schema)
    if not ok then
      return nil, "bad request: " .. problem
    end
    return handler(request_ctx, args)
  end
end

--- Run one request through a handler table and build the response.
-- @tparam table handlers { [op] = function(request_ctx, args) }
-- @tparam number sender
-- @tparam table request
-- @treturn table The response.
function rpc.handle(handlers, sender, request)
  local function respond(ok, value)
    return wire.response(request.id, ok, value)
  end

  local handler = handlers[request.op]
  if type(handler) ~= "function" then
    return respond(false, "unknown operation: " .. tostring(request.op))
  end

  local request_ctx = {
    sender = sender,
    token = request.token,
    computer_token = request.computer_token,
  }
  local ran, result, err = pcall(handler, request_ctx, request.args or {})
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
  local remembered, remembered_count = {}, 0 -- [sender/id] = { at, response? }

  local function forget(key)
    if remembered[key] then
      remembered[key] = nil
      remembered_count = remembered_count - 1
    end
  end

  -- Drop answers older than REMEMBER_SECONDS; over the limit, the oldest finished ones
  -- go first, but never one a client may still retry (the limit is soft).
  local function forget_old()
    local now = os.clock()
    local finished = {}
    for key, entry in pairs(remembered) do
      if entry.response and now - entry.at > REMEMBER_SECONDS then
        forget(key)
      elseif entry.response then
        finished[#finished + 1] = { key = key, at = entry.at }
      end
    end
    if remembered_count <= MAX_REMEMBERED then
      return
    end
    table.sort(finished, function(a, b) return a.at < b.at end)
    local retry_window = 2 * rpc.DEFAULT_TIMEOUT * (1 + rpc.DEFAULT_RETRIES)
    for _, old in ipairs(finished) do
      if remembered_count <= MAX_REMEMBERED or now - old.at < retry_window then
        break
      end
      forget(old.key)
    end
  end

  local function resume(worker, ...)
    local ok, filter = coroutine.resume(worker.coroutine, ...)
    if not ok or coroutine.status(worker.coroutine) == "dead" then
      return false
    end
    worker.filter = filter
    return true
  end

  local function start_worker(sender, request)
    local key = tostring(sender) .. "/" .. tostring(request.id)
    local seen = remembered[key]
    if seen then
      if seen.response then
        transport.send(sender, seen.response, protocol)
      end
      return
    end
    if #workers >= MAX_WORKERS then
      transport.send(sender, wire.response(request.id, false, "server busy"), protocol)
      return
    end
    forget_old()
    local entry = { at = os.clock() }
    remembered[key] = entry
    remembered_count = remembered_count + 1
    local is_once = once_handlers[handlers[request.op]] == true
    local worker = {
      coroutine = coroutine.create(function()
        local response = rpc.handle(handlers, sender, request)
        if is_once then
          entry.response, entry.at = response, os.clock()
        else
          forget(key) -- a read: a repeat may simply run again
        end
        transport.send(sender, response, protocol)
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
  -- Checked with the controller once per request, however many checks it runs
  -- (no caching beyond the request: logouts and group changes still apply at once).
  local user = request_ctx.checked_user
  if user == nil then
    user = user_validator(request_ctx.token) or false
    request_ctx.checked_user = user
  end
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
