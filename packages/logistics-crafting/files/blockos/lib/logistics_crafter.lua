--- The crafter of a logistics node: runs crafting jobs step by step against the
-- node's machines, and learns recipes from a player doing a craft once.
--
-- It sits on the node's own computer and calls the node directly (supply, contents,
-- retrieve): checking machines every second costs no network traffic. Only two
-- things cross the network: the controller's "craft" when a watched item runs low,
-- and a "supply" request to the controller when an ingredient is not on this node
-- (it arrives through the ports straight into the machine).
--
-- One job runs at a time (machines are shared); others wait in line. A job repeats
-- the recipe until it made enough. A failed attempt (timeout or scrap) empties the
-- recipe's blocks into storage and starts the run again, up to the recipe's retries.
-- @module logistics_crafter

local logistics_recipes = import("logistics_recipes")

local logistics_crafter = {}

--- How long a job waits for a missing ingredient before giving up.
logistics_crafter.INGREDIENT_WAIT = 120
--- Most runs one job does (a refill of thousands is split over several jobs).
logistics_crafter.MAX_RUNS = 64
logistics_crafter.MAX_JOBS = 8
logistics_crafter.HISTORY = 5

--- Create a crafter.
-- @tparam table options
--   node     the logistics node (supply, contents, retrieve, stored, machines)
--   recipes  [item] = recipe, changed in place
--   save     function() -> true | nil, err (the recipes)
--   fetch    optional function(item, count, machine) -> { moved } | nil, err: bring an
--            ingredient from other nodes (through the controller)
--   clock    optional function() -> seconds
--   log      optional { info, warn }
-- @treturn table crafter
function logistics_crafter.new(options)
  local node = options.node
  local recipes = options.recipes
  local clock = options.clock or function() return os.clock() end
  local log = options.log
  local crafter = { jobs = {}, history = {}, teaching = nil }

  local function note(level, format, ...)
    if log and log[level] then
      log[level](format, ...)
    end
  end

  ---------------------------------------------------------------------------
  -- Recipes
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
        state = job.state, attempt = job.attempt, note = job.note }
    end
    for _, job in ipairs(crafter.history) do
      jobs[#jobs + 1] = job
    end
    -- needs: what one run takes, so the controller only asks when it can be made.
    return { recipes = list, needs = needs, jobs = jobs }
  end

  ---------------------------------------------------------------------------
  -- Jobs
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
    job = { item = item, count = count, made = 0, attempt = 0, step = 1, supplied = 0,
      state = "queued", step_started = clock() }
    crafter.jobs[#crafter.jobs + 1] = job
    return { item = item, count = count, state = job.state }
  end

  local function finish(job, state, why)
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
    for _, block in ipairs(logistics_recipes.blocks(recipes[item] or { steps = {} })) do
      node.retrieve(block)
    end
    finish(job, "cancelled")
    return true
  end

  local function next_step(job, recipe)
    job.step = job.step + 1
    job.supplied, job.fetched = 0, nil
    job.step_started = clock()
    job.state, job.note = "running", nil
    if job.step > #recipe.steps then
      job.made = job.made + recipe.makes
      job.attempt, job.step = 0, 1
      if job.made >= job.count then
        finish(job, "done")
      end
    end
  end

  -- A failed attempt: everything in the recipe's blocks goes back to storage (scrap
  -- included), then the run starts again or the job gives up.
  local function attempt_failed(job, recipe, why)
    for _, block in ipairs(logistics_recipes.blocks(recipe)) do
      node.retrieve(block)
    end
    job.attempt = job.attempt + 1
    if job.attempt > recipe.retries then
      finish(job, "failed", why)
      return
    end
    note("warn", "crafting %s: %s; trying again (%d of %d)", job.item, why, job.attempt,
      recipe.retries)
    job.step, job.supplied, job.fetched = 1, 0, nil
    job.step_started = clock()
    job.note = why
  end

  local function run_supply(job, recipe, step)
    local missing = step.count - job.supplied
    if missing > 0 and node.stored(step.item) > 0 then
      local result = node.supply(step.item, missing, step.to)
      job.supplied = job.supplied + (result and result.moved or 0)
      missing = step.count - job.supplied
    end
    if missing > 0 and not job.fetched and options.fetch then
      -- Once per step: the controller brings it from other nodes into the machine.
      job.fetched = true
      local result = options.fetch(step.item, missing, step.to)
      job.supplied = job.supplied + (result and result.moved or 0)
      missing = step.count - job.supplied
    end
    if missing <= 0 then
      next_step(job, recipe)
      return
    end
    job.state, job.note = "waiting", "needs " .. missing .. " " .. step.item
    if clock() - job.step_started > logistics_crafter.INGREDIENT_WAIT then
      for _, block in ipairs(logistics_recipes.blocks(recipe)) do
        node.retrieve(block)
      end
      finish(job, "failed", "missing " .. step.item)
    end
  end

  local function run_wait(job, recipe, step)
    local contents = node.contents(step.at) or {}
    local scrap = logistics_recipes.failed_item(recipe, contents)
    if scrap then
      attempt_failed(job, recipe, "made " .. scrap)
    elseif (contents[step.item] or 0) >= step.count then
      next_step(job, recipe)
    elseif clock() - job.step_started > step.timeout then
      attempt_failed(job, recipe, "timed out waiting for " .. step.item)
    end
  end

  --- Advance the current job by at most one step (called every second).
  function crafter.tick()
    local job = crafter.jobs[1]
    if not job or crafter.teaching then
      return
    end
    local recipe = recipes[job.item]
    if not (recipe and recipe.is_ready) then
      finish(job, "failed", "the recipe is gone")
      return
    end
    if job.state == "queued" then
      job.state, job.step_started = "running", clock()
    end
    local step = recipe.steps[job.step]
    if step.kind == "supply" then
      run_supply(job, recipe, step)
    elseif step.kind == "wait" then
      run_wait(job, recipe, step)
    else
      node.retrieve(step.from)
      next_step(job, recipe)
    end
  end

  ---------------------------------------------------------------------------
  -- Teaching: watch a player craft once
  ---------------------------------------------------------------------------

  --- Start watching the machines. Jobs pause meanwhile.
  function crafter.teach_start(item)
    local machines = node.machines()
    if #machines == 0 then
      return nil, "no machines yet: give the machine blocks the 'machine' role first"
    end
    local before = {}
    for _, block in ipairs(machines) do
      before[block] = node.contents(block) or {}
    end
    crafter.teaching = { item = item, before = before, supplies = {}, started = clock() }
    return machines
  end

  --- Look at the machines once; returns what was seen so far.
  -- @treturn table { supplies = { [block] = { [item] = count } }, result? }
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
