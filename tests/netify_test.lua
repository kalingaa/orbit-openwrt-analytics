local json = require "cjson"

local snapshot_path = os.tmpname()
local state_path = os.tmpname()
os.remove(state_path)
NETIFY_SNAPSHOT_PATH = snapshot_path
NETIFY_STATE_PATH = state_path

local samples = {}
function metric(name, kind)
  samples[name] = samples[name] or {kind = kind, values = {}}
  return function(labels, value)
    samples[name].values[#samples[name].values + 1] = {labels = labels, value = value}
  end
end

local flows = {
  {
    digest = "youtube-quic", local_ip = "192.0.2.10", local_mac = "02:00:00:00:00:01",
    local_port = 50001, other_ip = "198.51.100.10", other_port = 443,
    local_bytes = 100, other_bytes = 1000, ip_protocol = 17,
    detected_application_name = "Unknown", detected_protocol_name = "QUIC",
    host_server_name = "rr1.example.googlevideo.com"
  },
  {
    digest = "google-doh", local_ip = "192.0.2.10", local_mac = "02:00:00:00:00:01",
    local_port = 50002, other_ip = "198.51.100.11", other_port = 443,
    local_bytes = 50, other_bytes = 200, ip_protocol = 17,
    detected_application_name = "Unknown", detected_protocol_name = "QUIC",
    dns_host_name = "dns.google"
  },
  {
    digest = "wireguard", local_ip = "192.0.2.11", local_mac = "02:00:00:00:00:02",
    local_port = 51820, other_ip = "198.51.100.12", other_port = 51820,
    local_bytes = 500, other_bytes = 700, ip_protocol = 17,
    detected_application_name = "Unknown", detected_protocol_name = "WireGuard"
  }
}

local duplicate = {
  digest = "youtube-quic", local_ip = "192.0.2.10", local_mac = "02:00:00:00:00:01",
  local_port = 50001, other_ip = "198.51.100.10", other_port = 443,
  local_bytes = 10, other_bytes = 20, ip_protocol = 17,
  detected_application_name = "Unknown", detected_protocol_name = "QUIC",
  host_server_name = "rr1.example.googlevideo.com"
}

local file = assert(io.open(snapshot_path, "w"))
file:write(json.encode({flows = {lan_capture = flows, wan_capture = {duplicate}}}))
file:close()

local collector = dofile("monitoring/netify.lua")
collector.scrape()

local function has_sample(expected)
  for _, sample in ipairs(samples.openwrt_netify_application_bytes_total.values) do
    local matches = true
    for key, value in pairs(expected) do
      if sample.labels[key] ~= value then matches = false; break end
    end
    if matches then return true end
  end
  return false
end

assert(has_sample({application = "Unknown", protocol = "QUIC", service = "YouTube",
  domain = "googlevideo.com", traffic_class = "unresolved_quic"}))
assert(has_sample({application = "Unknown", protocol = "QUIC", service = "Google DNS",
  domain = "dns.google", traffic_class = "encrypted_dns"}))
assert(has_sample({application = "Unknown", protocol = "WireGuard", service = "Unknown",
  traffic_class = "vpn"}))

assert(samples.openwrt_netify_service_classified_ratio.values[1].value >
  samples.openwrt_netify_classified_ratio.values[1].value)
assert(samples.openwrt_netify_active_flows.values[1].value == 3)

os.remove(snapshot_path)
os.remove(state_path)
print("Netify classification tests passed.")
