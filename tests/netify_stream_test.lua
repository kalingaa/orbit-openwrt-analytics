local json = require "cjson"

local state_path = os.tmpname()
os.remove(state_path)

local metadata = {
  type = "flow",
  interface = "test-wan",
  flow = {
    digest = "stream-test",
    local_ip = "192.0.2.20",
    local_mac = "02:00:00:00:00:20",
    local_port = 50000,
    other_ip = "198.51.100.20",
    other_port = 443,
    ip_protocol = 6,
    detected_application_name = "netify.youtube",
    detected_protocol_name = "HTTP/S"
  }
}
local stats = {
  type = "flow_stats",
  flow = {
    digest = "stream-test", last_seen_at = 1000,
    local_bytes = 100, other_bytes = 1000, total_bytes = 1100
  }
}
local purge = {
  type = "flow_purge",
  flow = {
    digest = "stream-test", last_seen_at = 2000,
    local_bytes = 50, other_bytes = 500, total_bytes = 1650
  }
}
local lines = {
  json.encode(metadata), json.encode(stats), json.encode(stats), json.encode(purge)
}

local original_lines = io.lines
io.lines = function()
  local index = 0
  return function()
    index = index + 1
    return lines[index]
  end
end
arg = {"monitoring/netify.lua", state_path}
dofile("monitoring/netify-stream.lua")
io.lines = original_lines

local file = assert(io.open(state_path, "r"))
local state = json.decode(file:read("*a"))
file:close()

local found
for _, total in pairs(state.totals) do
  if total.labels.application == "youtube" then found = total; break end
end
assert(found, "stream total was not created")
assert(found.upload == 150, "upload intervals were not summed")
assert(found.download == 1500, "download intervals were not summed")
assert(found.flows == 1, "flow was counted more than once")
assert(state.duplicate_events_total == 1, "duplicate event was not rejected")

local samples = {}
function metric(name, kind)
  samples[name] = samples[name] or {kind = kind, values = {}}
  return function(labels, value)
    samples[name].values[#samples[name].values + 1] = {labels = labels, value = value}
  end
end
NETIFY_STREAM_STATE_PATH = state_path
NETIFY_SNAPSHOT_PATH = state_path .. ".missing"
NETIFY_STATE_PATH = state_path .. ".fallback"
dofile("monitoring/netify.lua").scrape()
assert(samples.openwrt_netify_stream_up.values[1].value == 1)
assert(samples.openwrt_netify_application_bytes_total.values[1])

os.remove(state_path)
os.remove(state_path .. ".fallback")
print("Netify stream accounting tests passed.")
