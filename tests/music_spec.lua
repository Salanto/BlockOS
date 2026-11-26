-- Music player: streaming a song to fake speakers.
return function(t)
  local function fake_speaker()
    local speaker = { chunks = 0, volumes = {}, is_stopped = false }
    function speaker.playAudio(samples, volume)
      speaker.chunks = speaker.chunks + 1
      speaker.volumes[#speaker.volumes + 1] = volume
      speaker.sample_count = #samples
      return true
    end
    function speaker.stop()
      speaker.is_stopped = true
    end
    return speaker
  end

  local function write_song(name, bytes)
    local path = t.sandbox .. "/" .. name
    t.write(path, string.rep("U", bytes))
    return path
  end

  t.it("a song is streamed in chunks to every speaker", function()
    local music = t.fresh_import()("music")
    local path = write_song("song.dfpwm", music.CHUNK_BYTES * 2 + 100)
    local song = assert(music.open(path))
    t.eq(song.size, music.CHUNK_BYTES * 2 + 100)
    local left, right = fake_speaker(), fake_speaker()
    local progress = {}
    local played = music.play(song, { left, right }, {
      volume = function() return 2 end,
      progress = function(bytes) progress[#progress + 1] = bytes end,
    })
    t.eq(played, music.CHUNK_BYTES * 2 + 100)
    t.eq(left.chunks, 3)
    t.eq(right.chunks, 3, "every speaker gets every chunk")
    t.eq(left.volumes[1], 2)
    t.eq(left.sample_count, 100 * 8, "DFPWM: one byte decodes to 8 samples")
    t.eq(progress[#progress], played)
  end)

  t.it("playback stops early when asked", function()
    local music = t.fresh_import()("music")
    local path = write_song("long.dfpwm", music.CHUNK_BYTES * 5)
    local speaker = fake_speaker()
    local is_stopping = false
    local played = music.play(assert(music.open(path)), { speaker }, {
      progress = function() is_stopping = true end,
      should_stop = function() return is_stopping end,
    })
    t.eq(played, music.CHUNK_BYTES, "stopped after the first chunk")
    t.ok(speaker.is_stopped, "queued audio is silenced")
  end)

  t.it("empty and missing files explain what is wrong", function()
    local music = t.fresh_import()("music")
    local empty = write_song("empty.dfpwm", 0)
    local song, err = music.open(empty)
    t.ok(not song)
    t.ok(err:find("empty"), err)
    local missing, missing_error = music.open(t.sandbox .. "/nope.dfpwm")
    t.ok(not missing)
    t.ok(missing_error:find("no such file"), missing_error)
  end)
end
