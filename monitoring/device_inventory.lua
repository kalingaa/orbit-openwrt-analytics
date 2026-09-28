local json = require "cjson"

local runtime_state_path = "/tmp/prometheus-device-inventory-state.json"
local persistent_state_path = "/var/lib/prometheus-device-inventory-state.json"
local online_window_seconds = 300

local function safe(value)
  if value == nil or value == json.null then return "" end
  return tostring(value):gsub('["\\\r\n\t]', '_')
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(json.decode, raw or "")
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

local function valid_mac(mac)
  return mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
    and mac ~= "ff:ff:ff:ff:ff:ff"
    and mac ~= "00:00:00:00:00:00"
end

local function load_names()
  local names = {}
  local sources = {}

  local cache = io.open("/tmp/prometheus-device-names.cache", "r")
  if cache then
    cache:read("*l")
    for line in cache:lines() do
      local mac, name = line:match("^([^\t]+)\t(.*)$")
      if mac and name and name ~= "" then
        mac = string.lower(mac)
        names[mac] = safe(name)
        sources[mac] = "discovered"
      end
    end
    cache:close()
  end

  local aliases = io.open("/etc/prometheus-device-names", "r")
  if aliases then
    for line in aliases:lines() do
      local mac, name = line:match("^%s*([%x:]+)%s+(.+)%s*$")
      if mac and name and line:sub(1, 1) ~= "#" then
        mac = string.lower(mac)
        names[mac] = safe(name)
        sources[mac] = "manual"
      end
    end
    aliases:close()
  end

  return names, sources
end

local function load_state()
  local state = read_json(runtime_state_path) or read_json(persistent_state_path)
  if type(state) ~= "table" then state = {version = 1, devices = {}} end
  state.version = 1
  state.devices = state.devices or {}
  return state
end

local function add_device(state, mac, ip, now, active)
  mac = string.lower(safe(mac))
  ip = safe(ip)
  if not valid_mac(mac) or ip == "" then return end
  local key = mac .. "|" .. ip
  local device = state.devices[key]
  if not device then
    device = {mac = mac, ip = ip, first_seen = now, last_seen = 0}
    state.devices[key] = device
  end
  if active then device.last_seen = now end
end

local function collect_accounted_devices(state, now)
  local pipe = io.popen("nlbw -c json 2>/dev/null")
  if not pipe then return end
  local raw = pipe:read("*a")
  pipe:close()
  local ok, report = pcall(json.decode, raw or "")
  if not ok or not report or not report.data then return end
  for _, row in ipairs(report.data) do
    add_device(state, row[4], row[5], now, false)
  end
end

local function collect_active_neighbours(state, now)
  local pipe = io.popen("ip neigh show 2>/dev/null")
  if not pipe then return end
  for line in pipe:lines() do
    local ip = line:match("^(%S+)")
    local mac = line:match("lladdr%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
    local status = line:match("(%u+)%s*$") or ""
    local active = status == "REACHABLE" or status == "DELAY"
      or status == "PROBE" or status == "PERMANENT"
    if active and mac and ip then add_device(state, mac, ip, now, true) end
  end
  pipe:close()
end

local function collect_active_flows(state, now)
  local snapshot = read_json("/var/run/netifyd/sink-request.json")
  if not snapshot or type(snapshot.flows) ~= "table" then return end
  local seen = {}
  for _, flows in pairs(snapshot.flows) do
    if type(flows) == "table" then
      for _, flow in ipairs(flows) do
        local key = safe(flow.local_mac) .. "|" .. safe(flow.local_ip)
        if not seen[key] then
          add_device(state, flow.local_mac, flow.local_ip, now, true)
          seen[key] = true
        end
      end
    end
  end
end

local function scrape()
  local now = os.time()
  local state = load_state()
  collect_accounted_devices(state, now)
  collect_active_neighbours(state, now)
  collect_active_flows(state, now)

  local names, sources = load_names()
  local info = metric("openwrt_device_inventory_info", "gauge")
  local first_seen = metric("openwrt_device_first_seen_seconds", "gauge")
  local last_seen = metric("openwrt_device_last_seen_seconds", "gauge")
  local online = metric("openwrt_device_online", "gauge")
  local mac_online_metric = metric("openwrt_device_mac_online", "gauge")
  local ip_count_metric = metric("openwrt_device_ip_count", "gauge")
  local updated = metric("openwrt_device_inventory_updated_seconds", "gauge")
  local mac_ips = {}
  local mac_online = {}

  for key, device in pairs(state.devices) do
    local mac = safe(device.mac)
    local ip = safe(device.ip)
    local name = names[mac] or "unknown"
    local source = sources[mac] or "unknown"
    local family = ip:find(":", 1, true) and "IPv6" or "IPv4"
    local labels = {
      device_id = safe(key), mac = mac, ip = ip, device_name = name,
      name_source = source, family = family
    }
    info(labels, 1)
    first_seen(labels, tonumber(device.first_seen) or now)
    if (tonumber(device.last_seen) or 0) > 0 then
      last_seen({device_id = safe(key)}, tonumber(device.last_seen))
    end
    local is_online = (tonumber(device.last_seen) or 0) > 0
      and now - tonumber(device.last_seen) <= online_window_seconds
    online({device_id = safe(key)}, is_online and 1 or 0)
    if is_online then mac_online[mac] = true end
    mac_ips[mac] = mac_ips[mac] or {}
    mac_ips[mac][ip] = true
  end

  for mac, ips in pairs(mac_ips) do
    local count = 0
    for _ in pairs(ips) do count = count + 1 end
    ip_count_metric({mac = mac, device_name = names[mac] or "unknown"}, count)
    mac_online_metric({mac = mac, device_name = names[mac] or "unknown"}, mac_online[mac] and 1 or 0)
  end

  updated({}, now)
  write_json(runtime_state_path, state)
end

return { scrape = scrape }
