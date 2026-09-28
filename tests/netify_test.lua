local json = require "cjson"

local snapshot_path = os.tmpname()
local state_path = os.tmpname()
os.remove(state_path)
NETIFY_SNAPSHOT_PATH = snapshot_path
NETIFY_STATE_PATH = state_path
NETIFY_LOCAL_CIDR = "192.0.2.0/24"

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
  },
  {
    digest = "wan-side", local_ip = "198.51.100.1", local_mac = "02:00:00:00:00:ff",
    local_port = 443, other_ip = "192.0.2.10", other_port = 50003,
    local_bytes = 900, other_bytes = 800, ip_protocol = 6,
    detected_application_name = "netify.http", detected_protocol_name = "HTTP/S"
  }
}

local duplicate = {
  digest = "youtube-quic", local_ip = "198.51.100.10", local_mac = "02:00:00:00:00:ff",
  local_port = 443, other_ip = "192.0.2.10", other_port = 50001,
  local_bytes = 10000, other_bytes = 20000, ip_protocol = 17,
  detected_application_name = "Unknown", detected_protocol_name = "QUIC",
  host_server_name = "rr1.example.googlevideo.com"
}

local file = assert(io.open(snapshot_path, "w"))
file:write(json.encode({flows = {lan_capture = flows, wan_capture = {duplicate}}}))
file:close()

local old_state = assert(io.open(state_path, "w"))
old_state:write(json.encode({version = 2, seen = {}, totals = {legacy = {
  labels = {application = "spotify", protocol = "QUIC", service = "spotify",
    domain = "spotify.com", traffic_class = "application", detection = "dpi",
    intelligence = "none", wan = "unknown", ip = "192.0.2.12",
    mac = "02:00:00:00:00:03", device_name = "test-device"},
  upload = 10, download = 20, flows = 1
}}}))
old_state:close()

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

assert(has_sample({application = "YouTube", dpi_application = "Unknown", protocol = "QUIC", service = "YouTube",
  domain = "googlevideo.com", traffic_class = "unresolved_quic"}))
assert(has_sample({application = "Google DNS", dpi_application = "Unknown", protocol = "QUIC", service = "Google DNS",
  domain = "dns.google", traffic_class = "encrypted_dns"}))
assert(has_sample({application = "Unknown", dpi_application = "Unknown", protocol = "WireGuard", service = "Unknown",
  traffic_class = "vpn"}))
assert(has_sample({application = "spotify", dpi_application = "spotify", service = "spotify",
  detection = "dpi"}))

assert(samples.openwrt_netify_service_classified_ratio.values[1].value >
  samples.openwrt_netify_classified_ratio.values[1].value)
assert(samples.openwrt_netify_active_flows.values[1].value == 3)
assert(not has_sample({ip = "198.51.100.1"}), "WAN-side address was exported as a device")
assert(not has_sample({ip = "198.51.100.10"}), "WAN shadow replaced LAN flow metadata")

os.remove(snapshot_path)
os.remove(state_path)
print("Netify classification tests passed.")
