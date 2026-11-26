-- The loader's crash recovery and boot-failure handling (run against the sandbox).
return function(t)
  local LOADER = "packages/core/files/blockos/loader.lua"

  local function loader(mode)
    local chunk = assert(loadfile(fs.combine(t.repo, LOADER), nil, _ENV))
    return chunk(mode, t.sandbox)
  end

  local function make_tree(dir, version)
    t.write(t.sandbox .. dir .. "/boot.lua", "-- " .. version)
  end

  local function version_of(dir)
    return t.read(t.sandbox .. dir .. "/boot.lua")
  end

  local function set_state(state)
    t.write(t.sandbox .. "/etc/blockos/upgrade.state", state)
  end

  t.it("rolls forward a swap interrupted before anything moved", function()
    make_tree("/blockos", "old")
    make_tree("/blockos.new", "new")
    set_state("swap")
    loader("--recover")
    t.eq(version_of("/blockos"), "-- new")
    t.eq(version_of("/blockos.old"), "-- old")
    t.ok(not fs.exists(t.sandbox .. "/blockos.new"))
    t.ok(not fs.exists(t.sandbox .. "/etc/blockos/upgrade.state"))
  end)

  t.it("rolls forward a swap interrupted after the old tree moved", function()
    make_tree("/blockos.old", "old")
    make_tree("/blockos.new", "new")
    set_state("swap")
    loader("--recover")
    t.eq(version_of("/blockos"), "-- new")
    t.eq(version_of("/blockos.old"), "-- old")
  end)

  t.it("finishes an interrupted rollback", function()
    -- Interrupted after ROOT -> STAGING: only staging (newer) and old exist.
    make_tree("/blockos.new", "newer")
    make_tree("/blockos.old", "older")
    set_state("rollback")
    loader("--recover")
    t.eq(version_of("/blockos"), "-- older")
    t.eq(version_of("/blockos.old"), "-- newer")
  end)

  t.it("deletes abandoned staging when no swap was in progress", function()
    make_tree("/blockos", "current")
    make_tree("/blockos.new", "half staged")
    loader("--recover")
    t.eq(version_of("/blockos"), "-- current")
    t.ok(not fs.exists(t.sandbox .. "/blockos.new"))
  end)

  t.it("rolls back after 3 failed boots, gives up after 6", function()
    make_tree("/blockos", "broken")
    make_tree("/blockos.old", "good")
    for _ = 1, 3 do
      t.eq(loader("--select-root"), t.sandbox .. "/blockos")
    end
    local root, note = loader("--select-root")
    t.eq(root, t.sandbox .. "/blockos")
    t.ok(note and note:find("rolled back"), "expected a rollback note")
    t.eq(version_of("/blockos"), "-- good")
    t.eq(loader("--select-root"), t.sandbox .. "/blockos")
    t.eq(loader("--select-root"), t.sandbox .. "/blockos")
    t.eq(loader("--select-root"), nil)
  end)

  t.it("gives up at the 4th failure when there is nothing to roll back to", function()
    make_tree("/blockos", "broken")
    for _ = 1, 3 do
      loader("--select-root")
    end
    local root, note = loader("--select-root")
    t.eq(root, nil)
    t.ok(note:find("recovery"))
  end)
end
