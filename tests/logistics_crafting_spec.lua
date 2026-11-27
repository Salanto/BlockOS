-- Crafting on a node: recipes, teaching, the job runner with retries on scrap and
-- timeouts, ingredients from other nodes, and keep-stocked from the hub.
return function(t)
  local COPPER, ZINC, BRASS = "minecraft:copper_ingot", "create:zinc_ingot", "create:brass_ingot"
  local SCRAP = "create:scrap"
  local ANDESITE, NUGGET = "minecraft:andesite", "minecraft:iron_nugget"
  local ALLOY = "create:andesite_alloy"
  local ALLOY_RECIPE = {
    item = ALLOY,
    steps = {
      { kind = "supply", item = ANDESITE, count = 1, to = "depot" },
      { kind = "supply", item = NUGGET, count = 1, to = "depot" },
      { kind = "wait", item = ALLOY, count = 1, at = "depot", timeout = 10 },
      { kind = "retrieve", from = "depot" },
    },
  }

  local BRASS_RECIPE = {
    item = BRASS,
    makes = 1,
    retries = 2,
    scrap = { SCRAP },
    steps = {
      { kind = "supply", item = COPPER, count = 1, to = "basin" },
      { kind = "supply", item = ZINC, count = 1, to = "basin" },
      { kind = "wait", item = BRASS, count = 1, at = "basin", timeout = 10 },
      { kind = "retrieve", from = "basin" },
    },
  }

  t.it("recipes are checked; only listed scrap fails an attempt", function()
    local recipes = t.fresh_import()("logistics_recipes")
    local recipe = assert(recipes.clean(BRASS_RECIPE))
    t.ok(recipe.is_ready)
    t.eq(recipes.ingredients(recipe)[COPPER], 1)
    t.eq(table.concat(recipes.blocks(recipe), ","), "basin")
    t.eq(recipes.failed_item(recipe, { [SCRAP] = 1 }), SCRAP)
    t.eq(recipes.failed_item(recipe, { ["create:incomplete_thing"] = 1 }), nil,
      "machines hold in-between items while they work")
    t.eq(recipes.runs_for({ makes = 4 }, 10), 3)
    t.ok(not recipes.clean({ item = "not an id" }))
    t.ok(not recipes.clean({ item = BRASS, steps = { { kind = "melt" } } }))
    t.ok(not recipes.clean(recipes.new(BRASS)).is_ready, "no wait step yet")
    local timeout = recipes.clean_step({ kind = "wait", item = BRASS, count = 1, at = "b",
      timeout = 1 }).timeout
    t.eq(timeout, recipes.MIN_TIMEOUT)
  end)

  t.it("a draft recipe comes from what the player did", function()
    local recipes = t.fresh_import()("logistics_recipes")
    local draft = assert(recipes.draft(BRASS, {
      supplies = { basin = { [COPPER] = 2, [ZINC] = 2 } },
      result = { block = "basin", count = 2, seconds = 4 },
    }))
    t.eq(draft.makes, 2)
    t.eq(#draft.steps, 4)
    t.eq(draft.steps[1].item, ZINC, "ingredients in id order")
    t.eq(draft.steps[3].kind, "wait")
    t.eq(draft.steps[3].timeout, 12, "three times as long as it took")
    t.eq(draft.steps[4].from, "basin")
    t.ok(not recipes.draft(BRASS, { supplies = {} }), "no result, nothing learned")
  end)

  -- A node with a basin that mixes copper and zinc into brass (or scrap) when ticked.
  local function new_world(store)
    local machines = { basin = {}, basin2 = {}, depot = {} }
    local node = {}
    function node.stored(item)
      return store[item] or 0
    end
    function node.supply(item, count, to)
      local moved = math.min(count, store[item] or 0)
      store[item] = (store[item] or 0) - moved
      machines[to][item] = (machines[to][item] or 0) + moved
      return { moved = moved }
    end
    function node.contents(handle)
      local items = {}
      for item, count in pairs(machines[handle]) do
        if count > 0 then
          items[item] = count
        end
      end
      return items
    end
    function node.retrieve(handle)
      for item, count in pairs(machines[handle]) do
        store[item] = (store[item] or 0) + count
      end
      machines[handle] = {}
      return 0
    end
    function node.machines()
      return { "basin", "basin2", "depot" }
    end
    machines.recycler = {}
    function node.has_recycler()
      return world.has_recycler == true
    end
    function node.recycle(item, count, from)
      local source = from and machines[from] or store
      local moved = math.min(count, source[item] or 0)
      source[item] = (source[item] or 0) - moved
      machines.recycler[item] = (machines.recycler[item] or 0) + moved
      return moved
    end
    local world = { node = node, machines = machines, store = store, now = 0, result = BRASS }
    -- Both basins mix copper and zinc; the depot presses andesite and a nugget.
    function world.mix()
      for _, name in ipairs({ "basin", "basin2" }) do
        local basin = machines[name]
        if (basin[COPPER] or 0) >= 1 and (basin[ZINC] or 0) >= 1 then
          basin[COPPER], basin[ZINC] = basin[COPPER] - 1, basin[ZINC] - 1
          basin[world.result] = (basin[world.result] or 0) + 1
        end
      end
      local depot = machines.depot
      if (depot[ANDESITE] or 0) >= 1 and (depot[NUGGET] or 0) >= 1 then
        depot[ANDESITE], depot[NUGGET] = depot[ANDESITE] - 1, depot[NUGGET] - 1
        depot[ALLOY] = (depot[ALLOY] or 0) + 1
      end
    end
    return world
  end

  local function new_crafter(world, fetch, groups)
    local import = t.fresh_import()
    local crafter_module = import("logistics_crafter")
    local recipes = {}
    local crafter = crafter_module.new({
      node = world.node,
      recipes = recipes,
      groups = groups,
      save = function() return true end,
      fetch = fetch,
      clock = function() return world.now end,
    })
    assert(crafter.set_recipe(BRASS_RECIPE))
    return crafter, crafter_module
  end

  local function run(world, crafter, ticks)
    for _ = 1, ticks do
      crafter.tick()
      world.mix()
      world.now = world.now + 1
    end
  end

  t.it("a job supplies the machine, waits for the result and stores it", function()
    local world = new_world({ [COPPER] = 5, [ZINC] = 5 })
    local crafter = new_crafter(world)
    t.ok(crafter.start(BRASS, 3))
    t.eq(crafter.summary().jobs[1].state, "queued")
    run(world, crafter, 20)
    t.eq(world.store[BRASS], 3)
    t.eq(world.store[COPPER], 2)
    t.eq(#crafter.jobs, 0)
    t.eq(crafter.summary().jobs[1].state, "done", "listed among the finished jobs")
    t.eq(crafter.summary().recipes[1], BRASS)
  end)

  t.it("scrap empties the machine and the run starts again, up to the retries", function()
    local world = new_world({ [COPPER] = 9, [ZINC] = 9 })
    world.result = SCRAP
    local crafter = new_crafter(world)
    crafter.start(BRASS, 1)
    run(world, crafter, 30)
    local job = crafter.summary().jobs[1]
    t.eq(job.state, "failed")
    t.ok(job.note:find("scrap"), job.note)
    t.eq(world.store[SCRAP], 3, "three attempts (two retries), the scrap went to storage")
    t.eq(next(world.machines.basin), nil, "the basin was emptied")
  end)

  t.it("a machine that never finishes times out and is retried", function()
    local world = new_world({ [COPPER] = 9, [ZINC] = 9 })
    world.mix = function() end -- the mixer has no power
    local crafter = new_crafter(world)
    crafter.start(BRASS, 1)
    run(world, crafter, 13) -- two supplies, then 10 s without brass
    t.eq(crafter.jobs[1].runs[1].attempt, 1)
    t.ok(crafter.jobs[1].note:find("timed out"))
    t.eq(world.store[COPPER], 9, "the ingredients came back from the basin")
  end)

  t.it("a missing ingredient is fetched from other nodes once, straight into the machine",
    function()
      local world = new_world({ [COPPER] = 1 })
      local asked = {}
      local crafter = new_crafter(world, function(item, count, machine)
        asked[#asked + 1] = { item = item, count = count, machine = machine }
        world.machines[machine][item] = (world.machines[machine][item] or 0) + count
        return { moved = count }
      end)
      crafter.start(BRASS, 1)
      run(world, crafter, 10)
      t.eq(#asked, 1)
      t.eq(asked[1].item, ZINC)
      t.eq(asked[1].machine, "basin")
      t.eq(world.store[BRASS], 1)
    end)

  t.it("without the ingredient anywhere the job waits, then gives up", function()
    local world = new_world({ [COPPER] = 1 })
    local crafter, crafter_module = new_crafter(world)
    crafter.start(BRASS, 1)
    run(world, crafter, 5)
    t.eq(crafter.jobs[1].state, "waiting")
    t.ok(crafter.jobs[1].note:find(ZINC))
    run(world, crafter, crafter_module.INGREDIENT_WAIT + 2)
    t.eq(crafter.summary().jobs[1].state, "failed")
    t.eq(world.store[COPPER], 1, "the copper came back")
  end)

  t.it("teaching watches the machines while the player crafts once", function()
    local world = new_world({})
    local crafter = new_crafter(world)
    t.ok(crafter.teach_start("create:andesite_alloy"))
    world.machines.depot["minecraft:andesite"] = 1
    world.now = 1
    crafter.teach_poll()
    world.machines.depot["minecraft:andesite"] = 0
    world.machines.depot["minecraft:iron_nugget"] = 1
    crafter.teach_poll()
    world.now = 3
    world.machines.depot = { ["create:andesite_alloy"] = 1 }
    local recipe = assert(crafter.teach_finish())
    t.eq(recipe.item, "create:andesite_alloy")
    t.eq(#recipe.steps, 4, "two supplies, a wait and a retrieve")
    t.eq(recipe.steps[3].at, "depot")
    t.ok(crafter.recipe("create:andesite_alloy"), "saved")
  end)

  -- A hub with one crafting node whose report lists a brass recipe.
  local function crafting_hub(jobs)
    local import = t.fresh_import()
    import("roles").env.is_joined = function() return false end
    import("logistics_alarms").env.broadcast = function() end
    local hub_module = import("logistics_hub")
    local now = 0
    hub_module.env.clock = function() return now end
    local asked = {}
    local hub = hub_module.new({
      config = { watches = { [BRASS] = { label = "Brass", limit = 10, refill_to = 50,
        outputs = {} } } },
      save = function() return true end,
    })
    local proxy = {
      craft = function(item, count)
        asked[#asked + 1] = { item = item, count = count }
        return { item = item, count = count, state = "queued" }
      end,
    }
    hub.update("smeltery", {
      totals = {
        [BRASS] = { count = 4, label = "Brass" },
        [COPPER] = { count = 99, label = "Copper" },
        [ZINC] = { count = 99, label = "Zinc" },
      },
      blocks = {},
      poll_seconds = 1000, -- never stale while the test clock moves on
      crafting = { recipes = { BRASS }, jobs = jobs or {},
        needs = { [BRASS] = { [COPPER] = 1, [ZINC] = 1 } } },
    }, proxy)
    return hub, asked, function(seconds) now = now + seconds end, import
  end

  t.it("keep stocked: a low item with a recipe is crafted up to its refill target", function()
    local hub, asked, advance = crafting_hub()
    t.eq(#asked, 1)
    t.eq(asked[1].count, 46, "50 - 4")
    hub.check_levels()
    t.eq(#asked, 1, "not asked again right away")
    advance(61)
    hub.check_levels()
    t.eq(#asked, 2, "asked again when no job showed up")
  end)

  t.it("no second craft while the node reports an open job", function()
    local _, asked = crafting_hub({ { item = BRASS, count = 46, made = 3, state = "running" } })
    t.eq(#asked, 0)
  end)

  t.it("players start crafts and see jobs through the hub", function()
    local hub, asked, _, import = crafting_hub({ { item = BRASS, count = 46, made = 3,
      state = "running" } })
    local handlers = import("logistics_handlers").new(hub)
    local ctx = { local_admin = true }
    local result = assert(handlers.craft(ctx, { item = "brass", count = 5 }))
    t.eq(result.node, "smeltery")
    t.eq(asked[#asked].count, 5)
    t.eq(handlers.recipes(ctx, {})[1].node, "smeltery")
    t.eq(handlers.jobs(ctx, {})[1].made, 3)
    t.eq(handlers.catalog(ctx, {})[1].can_craft, true)
    t.ok(not handlers.craft(ctx, { item = "diamond", count = 1 }))
  end)

  t.it("keep stocked waits for ingredients and backs off after a failed job", function()
    local hub, asked, advance = crafting_hub({ { item = BRASS, count = 46, made = 0,
      state = "failed", note = "missing zinc" } })
    t.eq(#asked, 1, "a failed job does not stop the first ask")
    advance(61)
    hub.check_levels()
    t.eq(#asked, 1, "after a failure it waits longer than a minute")
    advance(300)
    hub.check_levels()
    t.eq(#asked, 2)
    hub.nodes.smeltery.report.totals[ZINC].count = 0
    advance(301)
    hub.check_levels()
    t.eq(#asked, 2, "no zinc anywhere: not asked")
  end)

  t.it("a node's crafting never takes ingredients from a private node", function()
    local import = t.fresh_import()
    local roles = import("roles")
    roles.env.is_joined = function() return true end
    roles.env.group_get = function(name)
      if name == "logistics-node-vault" then
        return { name = name }
      end
      return nil, "no such group"
    end
    import("logistics_alarms").env.broadcast = function() end
    local carried = {}
    local hub = import("logistics_hub").new({
      config = {},
      save = function() return true end,
      transfer = function(from, _, _, count)
        carried[#carried + 1] = from.name
        return { moved = count }
      end,
    })
    local function node(name, zinc)
      hub.update(name, { totals = { [ZINC] = { count = zinc, label = "Zinc" } }, blocks = {} },
        {})
    end
    node("vault", 50)
    node("shared", 5)
    node("smeltery", 0)
    local handlers = import("logistics_handlers").new(hub)
    t.ok(handlers.supply({ sender = 4, local_admin = true },
      { node = "smeltery", item = ZINC, count = 1, target = "basin" }))
    t.eq(carried[1], "shared", "the vault has more, but it is private")
  end)

  t.it("jobs on different machines run side by side", function()
    local world = new_world({ [COPPER] = 5, [ZINC] = 5, [ANDESITE] = 5, [NUGGET] = 5 })
    local crafter = new_crafter(world)
    assert(crafter.set_recipe(ALLOY_RECIPE))
    crafter.start(BRASS, 1)
    crafter.start(ALLOY, 1)
    run(world, crafter, 5)
    t.eq(world.store[BRASS], 1)
    t.eq(world.store[ALLOY], 1, "the depot did not wait for the basin")
  end)

  t.it("two recipes for the same machine take turns", function()
    local world = new_world({ [COPPER] = 5, [ZINC] = 5 })
    local crafter = new_crafter(world)
    local other = {}
    for key, value in pairs(BRASS_RECIPE) do
      other[key] = value
    end
    other.item = "create:other_ingot"
    assert(crafter.set_recipe(other))
    crafter.start(BRASS, 1)
    crafter.start("create:other_ingot", 1)
    crafter.tick()
    t.eq(crafter.jobs[2].state, "queued", "the basin is busy")
    t.eq(#crafter.jobs[2].runs, 0)
  end)

  t.it("a machine group runs several batches at once", function()
    local world = new_world({ [COPPER] = 5, [ZINC] = 5 })
    local crafter = new_crafter(world, nil, { mixers = { { "basin" }, { "basin2" } } })
    local grouped = { item = BRASS, retries = 2, steps = {
      { kind = "supply", item = COPPER, count = 1, to = "@mixers" },
      { kind = "supply", item = ZINC, count = 1, to = "@mixers" },
      { kind = "wait", item = BRASS, count = 1, at = "@mixers", timeout = 10 },
      { kind = "retrieve", from = "@mixers" },
    } }
    assert(crafter.set_recipe(grouped))
    crafter.start(BRASS, 2)
    crafter.tick()
    t.eq(#crafter.jobs[1].runs, 2, "one run per free station")
    run(world, crafter, 5)
    t.eq(world.store[BRASS], 2, "both batches done in the time of one")
  end)

  t.it("leftovers are cleared before a run, and a run counts what came out", function()
    local world = new_world({ [COPPER] = 5, [ZINC] = 5 })
    world.machines.basin[BRASS] = 7 -- left behind by a restart
    local crafter = new_crafter(world)
    crafter.start(BRASS, 1)
    run(world, crafter, 6)
    t.eq(world.store[BRASS], 8, "the leftovers went to storage first")
    t.eq(crafter.summary().jobs[1].made, 1, "only the new ingot counts")
  end)

  t.it("forgotten teaching ends by itself, so jobs go on", function()
    local world = new_world({ [COPPER] = 5, [ZINC] = 5 })
    local crafter, crafter_module = new_crafter(world)
    crafter.teach_start(BRASS)
    crafter.start(BRASS, 1)
    world.now = crafter_module.TEACH_SECONDS + 1
    crafter.tick()
    t.eq(crafter.teaching, nil)
    run(world, crafter, 6)
    t.eq(world.store[BRASS], 1)
  end)

  t.it("taught recipes keep the order the player supplied things in", function()
    local recipes = t.fresh_import()("logistics_recipes")
    local draft = assert(recipes.draft("minecraft:iron_ingot", {
      supplies = { furnace = { ["minecraft:raw_iron"] = 1, ["minecraft:coal"] = 1 } },
      order = { { block = "furnace", item = "minecraft:raw_iron" },
        { block = "furnace", item = "minecraft:coal" } },
      result = { block = "furnace", count = 1, seconds = 10 },
    }))
    t.eq(draft.steps[1].item, "minecraft:raw_iron", "input before fuel")
    local step = recipes.clean_step({ kind = "supply", item = "minecraft:coal", count = 1,
      to = "furnace", slot = 2 })
    t.eq(step.slot, 2, "a step can name the slot")
  end)

  t.it("scrap goes to the recycler instead of storage, also old scrap", function()
    local world = new_world({ [COPPER] = 9, [ZINC] = 9, [SCRAP] = 4 })
    world.has_recycler = true
    world.result = SCRAP
    local crafter = new_crafter(world)
    crafter.start(BRASS, 1)
    run(world, crafter, 30)
    t.eq(world.machines.recycler[SCRAP], 7, "3 failed attempts plus the 4 from before")
    t.eq(world.store[SCRAP], 0, "nothing left in storage")
  end)

end
