-- The package compressor: round trips, size, and damaged input.
return function(t)
  local function round_trip(lz, data)
    local packed = lz.compress(data)
    local unpacked, err = lz.decompress(packed)
    t.eq(err, nil)
    t.eq(unpacked, data, "round trip changed the data")
    return packed
  end

  t.it("round-trips empty, short and binary data", function()
    local lz = t.fresh_import()("lz")
    round_trip(lz, "")
    round_trip(lz, "a")
    round_trip(lz, "abc")
    local bytes = {}
    for i = 0, 255 do
      bytes[#bytes + 1] = string.char(i)
    end
    round_trip(lz, table.concat(bytes) .. table.concat(bytes))
  end)

  t.it("handles matches that overlap their own output", function()
    local lz = t.fresh_import()("lz")
    local packed = round_trip(lz, string.rep("ab", 5000))
    t.ok(#packed < 200, "a repeated pattern should shrink a lot, got " .. #packed)
  end)

  t.it("roughly halves real Lua source", function()
    local lz = t.fresh_import()("lz")
    local source = t.read(fs.combine(t.repo, "packages/core/files/blockos/kernel/pkg.lua"))
    local packed = round_trip(lz, source)
    t.ok(#packed < #source * 0.6,
      string.format("compressed %d of %d bytes", #packed, #source))
  end)

  t.it("rejects damaged data instead of crashing", function()
    local lz = t.fresh_import()("lz")
    local packed = lz.compress(string.rep("hello world ", 100))
    t.ok(not lz.decompress(packed:sub(1, #packed - 5)), "a cut-off stream")
    t.ok(not lz.decompress("not compressed at all"))
    local wrong_length = packed:sub(1, 4) .. "\255\0\0\0" .. packed:sub(9)
    t.ok(not lz.decompress(wrong_length), "a wrong length header")
  end)

  t.it("unpack passes plain data through", function()
    local lz = t.fresh_import()("lz")
    t.eq(lz.unpack("plain text"), "plain text")
    t.eq(lz.unpack(lz.compress("packed text")), "packed text")
  end)

  t.it("packages are compressed and old plain packages still decode", function()
    local pkg = t.fresh_import()("pkg")
    local files = { ["blockos/x.lua"] = "return 1" }
    local bundle = { manifest = { name = "x", version = "1" }, files = files }
    local raw = pkg.encode(bundle)
    t.ok(raw:sub(1, 4) == "BLZ1", "pkg.encode should compress")
    t.eq(pkg.decode(raw).manifest.name, "x")
    t.eq(pkg.decode(textutils.serialise(bundle)).manifest.name, "x", "plain packages")
  end)
end
