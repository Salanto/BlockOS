--- Alert channel: any web service that takes a webhook. Each alert is POSTed as JSON,
-- exactly as raised: { source, level, title, text?, key?, host, time }.
-- @module alert_channels.webhook

local webhook = {}

webhook.kind = "webhook"
webhook.help = "an http(s) URL that receives each alert as JSON"

--- @tparam string target
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function webhook.check(target)
  if not target:match("^https?://[^%s/]+") then
    return nil, "expected a URL starting with http:// or https://"
  end
  return true
end

--- Short text for lists: the address without its path (which may hold a secret).
-- @tparam string target
-- @treturn string
function webhook.describe(target)
  return "webhook " .. (target:match("^https?://([^/]+)") or "?")
end

--- Post an alert.
-- @tparam string target
-- @tparam table alert
-- @tparam table env { post = function(url, body) -> true | nil, err }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function webhook.deliver(target, alert, env)
  return env.post(target, {
    source = alert.source,
    level = alert.level,
    title = alert.title,
    text = alert.text,
    key = alert.key,
    host = alert.host,
    time = alert.time,
  })
end

return webhook
