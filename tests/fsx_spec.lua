-- Atomic file writes and recovery.
return function(t)
  t.it("fsx.write then fsx.read round-trips", function()
    local fsx = t.fresh_import()("fsx")
    local path = t.sandbox .. "/a/b.txt"
    fsx.write(path, "hello")
    t.eq(fsx.read(path), "hello")
    t.ok(not fs.exists(path .. ".tmp"), "temp file left behind")
  end)

  t.it("fsx.read recovers from a crash between delete and move", function()
    local fsx = t.fresh_import()("fsx")
    local path = t.sandbox .. "/state"
    t.write(path .. ".tmp", "new contents")
    t.eq(fsx.read(path), "new contents")
  end)

  t.it("fsx.read prefers the real file over a half-written temp file", function()
    local fsx = t.fresh_import()("fsx")
    local path = t.sandbox .. "/state"
    t.write(path, "complete")
    t.write(path .. ".tmp", "partial")
    t.eq(fsx.read(path), "complete")
  end)

  t.it("fsx.read_table returns nil for corrupt data", function()
    local fsx = t.fresh_import()("fsx")
    local path = t.sandbox .. "/table"
    t.write(path, "{ this is not lua")
    t.eq(fsx.read_table(path), nil)
  end)

  t.it("fsx.walk lists nested files", function()
    local fsx = t.fresh_import()("fsx")
    t.write(t.sandbox .. "/w/x.lua", "1")
    t.write(t.sandbox .. "/w/sub/y.lua", "22")
    local files = fsx.walk(t.sandbox .. "/w")
    t.eq(#files, 2)
    t.eq(files[1], "sub/y.lua")
    t.eq(files[2], "x.lua")
    t.eq(fsx.tree_size(t.sandbox .. "/w"), 3)
  end)

  t.it("interrupted writes are finished or cleaned up", function()
    local fsx = t.fresh_import()("fsx")
    local dir = t.sandbox .. "/etc"
    t.write(dir .. "/complete", "real")
    t.write(dir .. "/complete.tmp", "leftover")
    t.write(dir .. "/moved.tmp", "newest copy")
    t.eq(fsx.finish_interrupted_writes(dir), 2)
    t.eq(t.read(dir .. "/complete"), "real")
    t.ok(not fs.exists(dir .. "/complete.tmp"), "leftover temp file kept")
    t.eq(t.read(dir .. "/moved"), "newest copy")
  end)
end
