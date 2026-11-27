--- The crafter of a logistics node: runs crafting jobs against the node's machines,
-- several at once, and learns recipes from a player doing a craft once.
--
-- It sits on the node's own computer and calls the node directly (supply, contents,
-- retrieve): checking machines every second costs no network traffic. Only two
-- things cross the network: the controller's "craft" when a watched item runs low,
-- and a "supply" request to the controller when an ingredient is not on this node
-- (it arrives through the ports straight into the machine).
--
-- Jobs and runs: a job wants N items; it does runs of the recipe until it has them.
-- Each run claims the blocks it uses for as long as it runs, so jobs on different
-- machines run side by side and two recipes for the same basin take turns. A recipe
-- may name a machine group ("@mixers", or "@presses:2" for the second block of a
-- station) instead of one block: each run then takes a free station of the group, so
-- three mixers make three batches at once. Before a run its blocks are emptied into
-- storage (leftovers would fake a result); a run counts what really came out.
--
-- A failed attempt (timeout, listed scrap, nothing came out) empties the run's blocks
-- and starts that run again, up to the recipe's retries; then the job fails. Listed
-- scrap goes to the node's recycle block when it has one (what the recycler recovers
-- comes back through an input chest), everything else into storage. Scrap already in
-- storage is sent to the recycler now and then too.
-- @module logistics_crafter

local logistics_recipes = import("logistics_recipes")

local logistics_crafter = {}

--- How long a run waits for a missing ingredient before the job gives up.
logistics_crafter.INGREDIENT_WAIT = 120
--- Most runs one job does (a refill of thousands is split over several jobs).
logistics_crafter.MAX_RUNS = 64
logistics_crafter.MAX_JOBS = 8
logistics_crafter.HISTORY = 5
--- Teaching ends by itself after this long (a forgotten teach would stop all jobs).
logistics_crafter.TEACH_SECONDS = 600
--- Seconds between sending scrap found in storage to the recycler.
logistics_crafter.RECYCLE_SECONDS = 30

--- Split a block reference: "@group:2" -> "group", 2; "@group" -> "group", 1.
-- @treturn string|nil group name (nil for a plain block)
-- @treturn number position in the station
function logistics_crafter.group_ref(ref)
  local group, position = tostring(ref):match("^@([%w_%-]+):?(%d*)$")
  if not group then
    return nil
  end
  return group, tonumber(position) or 1
end

--- Create a crafter.
-- @tparam table options
--   node     the logistics node (supply, contents, retrieve, stored, machines)
--   recipes  [item] = recipe, changed in place
--   groups   optional [name] = { station = { block... }... }, changed in place
--   save     function() -> true | nil, err (recipes and groups)
--   fetch    optional function(item, count, machine) -> { moved } | nil, err: bring an
--            ingredient from other nodes (through the controller)
--   clock    optional function() -> seconds
--   log      optional { info, warn }
-- @treturn table crafter
function logistics_crafter.new(options)
  local node = options.node
  local recipes = options.recipes
  local groups = options.groups or {}
  local clock = options.clock or function() return os.clock() end
  local log = options.log
  local crafter = { jobs = {}, history = {}, teaching = nil, claims = {}, groups = groups,
    recycled_at = nil }

  local function note(level, format, ...)
    if log and log[level] then
      log[level](format, ...)
    end
  end

  ---------------------------------------------------------------------------
  -- Recipes and groups
  ---------------------------------------------------------------------------

  function crafter.recipe(item)
    return recipes[item]
  end

  --- Add or replace a recipe (checked first).
  function crafter.set_recipe(recipe)
    local clean, err = logistics_recipes.clean(recipe)
    if not clean then
      return nil, err
    end
    recipes[clean.item] = clean
    local saved, save_error = options.save()
    if not saved then
      return nil, save_error
    end
    return clean
  end

  function crafter.forget(item)
    if not recipes[item] then
      return nil, "no recipe for " .. tostring(item)
    end
    recipes[item] = nil
    return options.save()
  end

  --- Define a machine group: interchangeable stations, each a list of blocks in the
  -- same order (e.g. { { "depot_1", "out_1" }, { "depot_2", "out_2" } }).
  -- @tparam string name
  -- @tparam[opt] {table...} stations nil removes the group
  function crafter.set_group(name, stations)
    if not tostring(name):match("^[%w_%-]+$") then
      return nil, "group names use letters, digits, - and _"
    end
    if stations then
      local size = nil
      for _, station in ipairs(stations) do
        size = size or #station
        if #station == 0 or #station ~= size then
          return nil, "every station of a group needs the same number of blocks"
        end
      end
      if not size then
        return nil, "a group needs at least one station"
      end
    end
    groups[name] = stations
    return options.save()
  end

  --- What the controller learns from each report.
  function crafter.summary()
    local list, needs = {}, {}
    for item, recipe in pairs(recipes) do
      if recipe.is_ready then
        list[#list + 1] = item
        needs[item] = logistics_recipes.ingredients(recipe)
      end
    end
    table.sort(list)
    local jobs = {}
    for _, job in ipairs(crafter.jobs) do
      jobs[#jobs + 1] = { item = job.item, count = job.count, made = job.made,
        state = job.state, running = #job.runs, note = job.note }
    end
    for _, job in ipairs(crafter.history) do
      jobs[#jobs + 1] = job
    end
    -- needs: what one run takes, so the controller only asks when it can be made.
    return { recipes = list, needs = needs, jobs = jobs }
  end

  ---------------------------------------------------------------------------
  -- Claims: which blocks a run holds
  ---------------------------------------------------------------------------

  local function release(run)
    for _, block in ipairs(run.blocks) do
      if crafter.claims[block] == run then
        crafter.claims[block] = nil
      end
    end
  end

  -- Pick blocks for a new run of a recipe: plain blocks must be free; each group
  -- reference gets a free station. Returns the binding and the block list, or nil.
  local function bind(recipe)
    local binding, blocks, taken = {}, {}, {}
    local function take(block)
      if crafter.claims[block] or taken[block] then
        return false
      end
      taken[block] = true
      blocks[#blocks + 1] = block
      return true
    end
    for _, ref in ipairs(logistics_recipes.blocks(recipe)) do
      local group = logistics_crafter.group_ref(ref)
      if not group and not take(ref) then
        return nil
      elseif group and not binding[group] then
        local chosen = nil
        for _, station in ipairs(groups[group] or {}) do
          local is_free = true
          for _, block in ipairs(station) do
            if crafter.claims[block] or taken[block] then
              is_free = false
            end
          end
          if is_free then
            chosen = station
            break
          end
        end
        if not chosen then
          return nil
        end
        binding[group] = chosen
        for _, block in ipairs(chosen) do
          take(block)
        end
      end
    end
    return binding, blocks
  end

  -- The block a step's reference means in this run.
  local function resolve(run, ref)
    local group, position = logistics_crafter.group_ref(ref)
    if not group then
      return ref
    end
    local station = run.binding[group]
    return station and station[position]
  end

  local function empty_run(run)
    for _, block in ipairs(run.blocks) do
      node.retrieve(block)
    end
  end

  ---------------------------------------------------------------------------
  -- Jobs and runs
  ---------------------------------------------------------------------------

  local function find_job(item)
    for index, job in ipairs(crafter.jobs) do
      if job.item == item then
        return job, index
      end
    end
    return nil
  end

  --- Start (or extend) a job.
  -- @tparam string item
  -- @tparam number count How many to make.
  -- @treturn[1] table { item, count, state }
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function crafter.start(item, count)
    local recipe = recipes[item]
    if not (recipe and recipe.is_ready) then
      return nil, "no recipe for " .. tostring(item) .. " on this node"
    end
    local most = logistics_crafter.MAX_RUNS * recipe.makes
    count = math.min(math.max(1, math.floor(count)), most)
    local job = find_job(item)
    if job then
      job.count = math.max(job.count, job.made + count)
      return { item = item, count = job.count, state = job.state }
    end
    if #crafter.jobs >= logistics_crafter.MAX_JOBS then
      return nil, "too many crafting jobs waiting"
    end
    job = { item = item, count = count, made = 0, state = "queued", runs = {} }
    crafter.jobs[#crafter.jobs + 1] = job
    return { item = item, count = count, state = job.state }
  end

  local function finish(job, state, why)
    for _, run in ipairs(job.runs) do
      empty_run(run)
      release(run)
    end
    job.runs = {}
    local _, index = find_job(job.item)
    if index then
      table.remove(crafter.jobs, index)
    end
    table.insert(crafter.history, 1, { item = job.item, count = job.count, made = job.made,
      state = state, note = why })
    while #crafter.history > logistics_crafter.HISTORY do
      table.remove(crafter.history)
    end
    note(state == "done" and "info" or "warn", "crafting %s: %s (%d of %d)%s", job.item,
      state, job.made, job.count, why and (": " .. why) or "")
  end

  --- Stop a job; what is in its machines goes back to storage.
  function crafter.cancel(item)
    local job = find_job(item)
    if not job then
      return nil, "no job for " .. tostring(item)
    end
    finish(job, "cancelled")
    return true
  end

  local function new_run(job, recipe)
    local binding, blocks = bind(recipe)
    if not binding then
      return nil
    end
    local run = { binding = binding, blocks = blocks, step = 1, supplied = 0, attempt = 0,
      produced = 0, step_started = clock() }
    for _, block in ipairs(blocks) do
      crafter.claims[block] = run
    end
    -- Leftovers from before (a restart, a player) would fake a result.
    empty_run(run)
    job.runs[#job.runs + 1] = run
    return run
  end

  local function end_run(job, run)
    release(run)
    for index, other in ipairs(job.runs) do
      if other == run then
        table.remove(job.runs, index)
        break
      end
    end
  end

  local function restart_step(run)
    run.step, run.supplied, run.fetched, run.produced = 1, 0, nil, 0
    run.step_started = clock()
  end

  local function next_step(job, recipe, run)
    run.step = run.step + 1
    run.supplied, run.fetched = 0, nil
    run.step_started = clock()
    job.note = nil
    if run.step <= #recipe.steps then
      return
    end
    -- The run is over: count what really came out.
    job.made = job.made + run.produced
    end_run(job, run)
  end

  -- Listed scrap in the run's blocks goes to the recycler (when there is one).
  local function recycle_scrap(recipe, run)
    if #recipe.scrap == 0 or not (node.has_recycler and node.has_recycler()) then
      return
    end
    for _, block in ipairs(run.blocks) do
      local contents = node.contents(block) or {}
      for _, item in ipairs(recipe.scrap) do
        if (contents[item] or 0) > 0 then
          node.recycle(item, contents[item], block)
        end
      end
    end
  end

  -- Every listed scrap item of any recipe.
  local function scrap_items()
    local items, seen = {}, {}
    for _, recipe in pairs(recipes) do
      for _, item in ipairs(recipe.scrap or {}) do
        if not seen[item] then
          seen[item] = true
          items[#items + 1] = item
        end
      end
    end
    return items
  end

  -- Scrap that ended up in storage anyway (from before there was a recycler, or from a
  -- player) goes to the recycler as well.
  local function recycle_stored()
    local now = clock()
    if crafter.recycled_at and now - crafter.recycled_at < logistics_crafter.RECYCLE_SECONDS then
      return
    end
    crafter.recycled_at = now
    if not (node.has_recycler and node.has_recycler()) then
      return
    end
    for _, item in ipairs(scrap_items()) do
      local stored = node.stored(item)
      if stored > 0 then
        node.recycle(item, stored)
      end
    end
  end

  -- A failed attempt: scrap to the recycler, the rest of the run's blocks back to
  -- storage, then the run starts again or the job gives up.
  local function attempt_failed(job, recipe, run, why)
    recycle_scrap(recipe, run)
    empty_run(run)
    run.attempt = run.attempt + 1
    if run.attempt > recipe.retries then
      finish(job, "failed", why)
      return
    end
    note("warn", "crafting %s: %s; trying again (%d of %d)", job.item, why, run.attempt,
      recipe.retries)
    restart_step(run)
    job.note = why
  end

  local function run_supply(job, recipe, run, step)
    local machine = resolve(run, step.to)
    local missing = step.count - run.supplied
    if missing > 0 and node.stored(step.item) > 0 then
      local result = node.supply(step.item, missing, machine, step.slot)
      run.supplied = run.supplied + (result and result.moved or 0)
      missing = step.count - run.supplied
    end
    if missing > 0 and not run.fetched and options.fetch then
      -- Once per step: the controller brings it from other nodes into the machine.
      run.fetched = true
      local result = options.fetch(step.item, missing, machine)
      run.supplied = run.supplied + (result and result.moved or 0)
      missing = step.count - run.supplied
    end
    if missing <= 0 then
      next_step(job, recipe, run)
      return
    end
    job.state, job.note = "waiting", "needs " .. missing .. " " .. step.item
    if clock() - run.step_started > logistics_crafter.INGREDIENT_WAIT then
      finish(job, "failed", "missing " .. step.item)
    end
  end

  local function run_wait(job, recipe, run, step)
    local contents = node.contents(resolve(run, step.at)) or {}
    local scrap = logistics_recipes.failed_item(recipe, contents)
    if scrap then
      attempt_failed(job, recipe, run, "made " .. scrap)
    elseif (contents[step.item] or 0) >= step.count then
      next_step(job, recipe, run)
    elseif clock() - run.step_started > step.timeout then
      attempt_failed(job, recipe, run, "timed out waiting for " .. step.item)
    end
  end

  local function run_retrieve(job, recipe, run, step)
    local block = resolve(run, step.from)
    local before = (node.contents(block) or {})[recipe.item] or 0
    node.retrieve(block)
    run.produced = run.produced + before
    local is_last = run.step == #recipe.steps
    if is_last and run.produced == 0 then
      attempt_failed(job, recipe, run, "nothing came out")
      return
    end
    next_step(job, recipe, run)
  end

  local function advance(job, recipe, run)
    local step = recipe.steps[run.step]
    if step.kind == "supply" then
      run_supply(job, recipe, run, step)
    elseif step.kind == "wait" then
      run_wait(job, recipe, run, step)
    else
      run_retrieve(job, recipe, run, step)
    end
  end

  -- Start as many runs as the job still needs and free machines allow.
  local function start_runs(job, recipe)
    while job.made + #job.runs * recipe.makes < job.count do
      if not new_run(job, recipe) then
        break
      end
    end
  end

  local function tick_job(job)
    local recipe = recipes[job.item]
    if not (recipe and recipe.is_ready) then
      finish(job, "failed", "the recipe is gone")
      return
    end
    start_runs(job, recipe)
    if #job.runs == 0 then
      if job.made >= job.count then
        finish(job, "done")
      else
        job.state = "queued" -- its machines are busy with other jobs
      end
      return
    end
    job.state = "running"
    local runs = {}
    for index, run in ipairs(job.runs) do
      runs[index] = run
    end
    for _, run in ipairs(runs) do
      if find_job(job.item) ~= job then
        return -- the job finished (failed) meanwhile
      end
      advance(job, recipe, run)
    end
    if find_job(job.item) == job and #job.runs == 0 and job.made >= job.count then
      finish(job, "done")
    end
  end

  --- Advance every job by at most one step per run (called every second).
  function crafter.tick()
    if crafter.teaching then
      if clock() - crafter.teaching.started > logistics_crafter.TEACH_SECONDS then
        note("warn", "teaching %s ran out of time", crafter.teaching.item)
        crafter.teaching = nil
      end
      return
    end
    local jobs = {}
    for index, job in ipairs(crafter.jobs) do
      jobs[index] = job
    end
    for _, job in ipairs(jobs) do
      if find_job(job.item) == job then
        tick_job(job)
      end
    end
    recycle_stored()
  end

  ---------------------------------------------------------------------------
  -- Teaching: watch a player craft once
  ---------------------------------------------------------------------------

  --- Start watching the machines. Jobs pause meanwhile (at most TEACH_SECONDS).
  function crafter.teach_start(item)
    local machines = node.machines()
    if #machines == 0 then
      return nil, "no machines yet: give the machine blocks the 'machine' role first"
    end
    local before = {}
    for _, block in ipairs(machines) do
      before[block] = node.contents(block) or {}
    end
    crafter.teaching = { item = item, before = before, supplies = {}, order = {},
      started = clock() }
    return machines
  end

  --- Look at the machines once; returns what was seen so far.
  -- @treturn table { supplies = { [block] = { [item] = count } }, order, result? }
  function crafter.teach_poll()
    local teaching = crafter.teaching
    if not teaching then
      return nil, "not teaching"
    end
    for block, before in pairs(teaching.before) do
      for item, count in pairs(node.contents(block) or {}) do
        local added = count - (before[item] or 0)
        if added > 0 and item == teaching.item then
          if not teaching.result then
            teaching.result = { block = block, count = added,
              seconds = clock() - teaching.started }
          end
        elseif added > 0 then
          local seen = teaching.supplies[block] or {}
          if not seen[item] then
            -- The order the player put things in (a furnace wants its input first).
            teaching.order[#teaching.order + 1] = { block = block, item = item }
          end
          seen[item] = math.max(seen[item] or 0, added)
          teaching.supplies[block] = seen
        end
      end
    end
    return teaching
  end

  --- Stop watching and save the draft recipe.
  function crafter.teach_finish()
    local teaching = crafter.teach_poll()
    crafter.teaching = nil
    if not teaching then
      return nil, "not teaching"
    end
    local draft, err = logistics_recipes.draft(teaching.item, teaching)
    if not draft then
      return nil, err
    end
    local old = recipes[teaching.item]
    if old then
      -- Keep what was tuned by hand.
      draft.retries, draft.scrap = old.retries, old.scrap
    end
    return crafter.set_recipe(draft)
  end

  function crafter.teach_cancel()
    crafter.teaching = nil
    return true
  end

  return crafter
end

return logistics_crafter
