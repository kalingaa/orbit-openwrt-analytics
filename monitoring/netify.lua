local json = require "cjson"

local snapshot_path = "/var/run/netifyd/sink-request.json"
local state_path = "/tmp/prometheus-netify-state.json"

local function safe(value)
  if value == nil or value == json.null then return "" end
  return tostring(value):gsub('["\\\r\n\t]', '_')
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(json.decode, raw)
  if ok and type(value) == "table" then return value end
  return nil
end

local function write_json(path, value)
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then return false end
  local ok, encoded = pcall(json.encode, value)
  if not ok then file:close(); os.remove(tmp); return false end
  file:write(encoded)
  file:close()
  return os.rename(tmp, path)
end

local function load_names()
  local names = {}
  local cache = io.open("/tmp/prometheus-device-names.cache", "r")
  if cache then
    cache:read("*l")
    for line in cache:lines() do
      local mac, name = line:match("^([^\t]+)\t(.*)$")
      if mac and name then names[string.upper(mac)] = safe(name) end
    end
    cache:close()
  end

  local aliases = io.open("/etc/prometheus-device-names", "r")
  if aliases then
    for line in aliases:lines() do
      local mac, name = line:match("^%s*([%x:]+)%s+(.+)%s*$")
      if mac and name and line:sub(1, 1) ~= "#" then
        names[string.upper(mac)] = safe(name)
      end
    end
    aliases:close()
  end
  return names
end

local function tuple_key(proto, src, sport, dst, dport)
  return table.concat({proto or "", src or "", sport or "", dst or "", dport or ""}, "|")
end

local function load_wan_map()
  local tuples = {}
  local pipe = io.popen("conntrack -L -o extended 2>/dev/null")
  if not pipe then return tuples end
  for line in pipe:lines() do
    local proto = line:match("^%S+%s+%d+%s+(%S+)") or ""
    local mark = tonumber(line:match("mark=(%d+)")) or 0
    local index = math.floor(mark / 256) % 256
    local wan = (index >= 1 and index <= 3) and ("WAN" .. index) or "unknown"
    for src, dst, sport, dport in line:gmatch("src=(%S+)%s+dst=(%S+)%s+sport=(%d+)%s+dport=(%d+)") do
      tuples[tuple_key(proto, src, sport, dst, dport)] = wan
    end
  end
  pipe:close()
  return tuples
end

local function display_application(flow)
  local app = safe(flow.detected_application_name)
  local protocol = safe(flow.detected_protocol_name)
  if app == "" or app == "Unknown" then app = protocol end
  if app == "" or app == "Unknown" then app = "Other" end
  app = app:gsub("^netify%.", "")
  return app, (protocol ~= "" and protocol or "Unknown")
end

local function scrape()
  local bytes_metric = metric("openwrt_netify_application_bytes_total", "counter")
  local flows_metric = metric("openwrt_netify_application_flows_total", "counter")
  local active_metric = metric("openwrt_netify_active_flows", "gauge")
  local classified_metric = metric("openwrt_netify_classified_ratio", "gauge")

  local snapshot = read_json(snapshot_path)
  if not snapshot or not snapshot.flows or not snapshot.flows["__LAN_DEVICE__"] then
    active_metric({}, 0)
    classified_metric({}, 0)
    return
  end

  local state = read_json(state_path) or {version = 1, seen = {}, totals = {}}
  state.seen = state.seen or {}
  state.totals = state.totals or {}

  local names = load_names()
  local wan_map = load_wan_map()
  local now = os.time()
  local active = 0
  local classified = 0

  for _, flow in ipairs(snapshot.flows["__LAN_DEVICE__"]) do
    local ip = safe(flow.local_ip)
    local mac = string.lower(safe(flow.local_mac))
    local digest = safe(flow.digest)
    local proto_number = tonumber(flow.ip_protocol) or 0
    if ip ~= "" and mac ~= "" and digest ~= "" and (proto_number == 6 or proto_number == 17) then
      active = active + 1
      local app, protocol = display_application(flow)
      if safe(flow.detected_application_name) ~= "" and safe(flow.detected_application_name) ~= "Unknown" then
        classified = classified + 1
      end

      local transport = proto_number == 6 and "tcp" or "udp"
      local wan = wan_map[tuple_key(transport, ip, flow.local_port, safe(flow.other_ip), flow.other_port)] or "unknown"
      local name = names[string.upper(mac)] or "unknown"
      local labels = {
        application = app,
        protocol = protocol,
        wan = wan,
        ip = ip,
        mac = mac,
        device_name = name
      }
      local label_key = table.concat({app, protocol, wan, ip, mac, name}, "\t")
      local previous = state.seen[digest]
      local up = tonumber(flow.local_bytes) or 0
      local down = tonumber(flow.other_bytes) or 0
      local up_delta = up
      local down_delta = down
      local is_new = 1
      if previous then
        up_delta = up >= (previous.up or 0) and (up - (previous.up or 0)) or up
        down_delta = down >= (previous.down or 0) and (down - (previous.down or 0)) or down
        is_new = 0
      end

      local total = state.totals[label_key] or {labels = labels, upload = 0, download = 0, flows = 0}
      total.labels = labels
      total.upload = (total.upload or 0) + up_delta
      total.download = (total.download or 0) + down_delta
      total.flows = (total.flows or 0) + is_new
      state.totals[label_key] = total
      state.seen[digest] = {up = up, down = down, touched = now}
    end
  end

  for digest, previous in pairs(state.seen) do
    if now - (previous.touched or 0) > 3600 then state.seen[digest] = nil end
  end

  for _, total in pairs(state.totals) do
    local base = total.labels
    local upload_labels = {
      application = base.application, protocol = base.protocol, wan = base.wan,
      ip = base.ip, mac = base.mac, device_name = base.device_name, direction = "upload"
    }
    local download_labels = {
      application = base.application, protocol = base.protocol, wan = base.wan,
      ip = base.ip, mac = base.mac, device_name = base.device_name, direction = "download"
    }
    bytes_metric(upload_labels, total.upload or 0)
    bytes_metric(download_labels, total.download or 0)
    flows_metric(base, total.flows or 0)
  end

  active_metric({}, active)
  classified_metric({}, active > 0 and classified / active or 0)
  write_json(state_path, state)
end

return { scrape = scrape }
