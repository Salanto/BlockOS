--- Music playback: streams DFPWM audio from a file or a link to every
-- attached speaker, chunk by chunk (a song never has to fit in memory).
--
-- DFPWM is CC:Tweaked's audio format; the rom's `cc.audio.dfpwm` decodes it.
-- @module music

local music = {}

music.CHUNK_BYTES = 16 * 1024
music.MAX_VOLUME = 3

--- Hardware and network access (tests replace these with stubs).
music.env = {
  peripheral = peripheral,
  http = http,
}

-- CC's DFPWM decoder lives in the rom as a `require` module; modules loaded
-- with `import` have no `require` of their own, so build one.
-- The loaded modules call `require` themselves (cc.audio.dfpwm needs
-- cc.expect), so it must live in the environment they run in.
local function new_decoder()
  local make_require = dofile("/rom/modules/main/cc/require.lua").make
  local env = setmetatable({}, { __index = _ENV })
  env.require = make_require(env, "/")
  return env.require("cc.audio.dfpwm").make_decoder()
end

--- Every attached speaker.
-- @treturn {table...} Wrapped speakers.
function music.find_speakers()
  local speakers = {}
  for _, name in ipairs(music.env.peripheral.getNames()) do
    if music.env.peripheral.hasType(name, "speaker") then
      speakers[#speakers + 1] = music.env.peripheral.wrap(name)
    end
  end
  return speakers
end

--- Open a song: a local file or an http(s) link.
-- @tparam string where A path (already resolved) or a URL.
-- @treturn[1] table { read(count), close(), size } (size nil when unknown)
-- @treturn[2] nil
-- @treturn[2] string error message
function music.open(where)
  if where:match("^https?://") then
    if not music.env.http then
      return nil, "http is disabled on this server"
    end
    local response, err = music.env.http.get(where, nil, true)
    if not response then
      return nil, "cannot download: " .. tostring(err)
    end
    local headers = response.getResponseHeaders and response.getResponseHeaders() or {}
    local length = tonumber(headers["Content-Length"] or headers["content-length"])
    return { read = response.read, close = response.close, size = length }
  end
  if not fs.exists(where) or fs.isDir(where) then
    return nil, "no such file: " .. where
  end
  local size = fs.getSize(where)
  if size == 0 then
    -- What made CraftOS's `speaker play` fail on line 112.
    return nil, where .. " is empty (0 bytes): copy it again"
  end
  local handle = fs.open(where, "rb")
  if not handle then
    return nil, "cannot open " .. where
  end
  return { read = handle.read, close = handle.close, size = size }
end

-- Queue samples on every speaker, waiting while a speaker's buffer is full.
local function play_samples(speakers, samples, volume)
  for _, speaker in ipairs(speakers) do
    while not speaker.playAudio(samples, volume) do
      os.pullEvent("speaker_audio_empty")
    end
  end
end

--- Play a song to the end, or until `options.should_stop()` returns true.
-- @tparam table song From music.open.
-- @tparam {table...} speakers
-- @tparam[opt] table options
--   volume()         current volume, 0 to 3 (read for every chunk; default 1)
--   progress(bytes)  called after each chunk with the bytes played so far
--   should_stop()    return true to stop early
-- @treturn number Bytes played.
function music.play(song, speakers, options)
  options = options or {}
  local decoder = new_decoder()
  local played = 0
  while not (options.should_stop and options.should_stop()) do
    local chunk = song.read(music.CHUNK_BYTES)
    if not chunk or #chunk == 0 then
      break
    end
    local volume = options.volume and options.volume() or 1
    play_samples(speakers, decoder(chunk), volume)
    played = played + #chunk
    if options.progress then
      options.progress(played)
    end
  end
  song.close()
  if options.should_stop and options.should_stop() then
    for _, speaker in ipairs(speakers) do
      speaker.stop()
    end
  end
  return played
end

return music
