local cjson = require "cjson"

local device_name_cache_path = "/tmp/prometheus-device-names.cache"

local function as_string(value)
    if value == nil or value == cjson.null then
        return ""
    end
    return tostring(value)
end

local function safe_label(value)
    return as_string(value):gsub('["\\\r\n\t]', '_')
end

local function load_device_names()
    local cached = io.open(device_name_cache_path, "r")
    if cached ~= nil then
        cached:read("*l")
        local names = {}
        for line in cached:lines() do
            local mac, name = line:match("^([^\t]+)\t(.*)$")
            if mac ~= nil and name ~= nil then
                names[mac] = name
            end
        end
        cached:close()
        return names
    end

    local names = {}

    local hints_pipe = io.popen("ubus call luci-rpc getHostHints 2>/dev/null")
    if hints_pipe ~= nil then
        local raw = hints_pipe:read("*a")
        hints_pipe:close()
        if raw ~= nil and raw ~= "" then
            local ok, hints = pcall(cjson.decode, raw)
            if ok and type(hints) == "table" then
                for mac, hint in pairs(hints) do
                    if type(hint) == "table" and hint.name ~= nil then
                        names[string.upper(mac)] = safe_label(hint.name)
                    end
                end
            end
        end
    end

    local aliases = io.open("/etc/prometheus-device-names", "r")
    if aliases ~= nil then
        for line in aliases:lines() do
            local mac, name = line:match("^%s*([%x:]+)%s+(.+)%s*$")
            if mac ~= nil and name ~= nil and line:sub(1, 1) ~= "#" then
                names[string.upper(mac)] = safe_label(name)
            end
        end
        aliases:close()
    end

    local cache = io.open(device_name_cache_path, "w")
    if cache ~= nil then
        cache:write(tostring(os.time()), "\n")
        for mac, name in pairs(names) do
            cache:write(mac, "\t", name, "\n")
        end
        cache:close()
    end

    return names
end

local function scrape()
    local pipe = io.popen("nlbw -c json 2>/dev/null")
    if pipe == nil then
        error("Could not execute nlbw")
    end

    local raw = pipe:read("*a")
    local ok = pipe:close()
    if not ok or raw == nil or raw == "" then
        error("nlbw returned no data")
    end

    local report = cjson.decode(raw)
    if report == nil or report.data == nil then
        error("nlbw returned invalid JSON")
    end

    local connections = metric("nlbwmon_connections", "counter")
    local rx_bytes = metric("nlbwmon_rx_bytes", "counter")
    local rx_packets = metric("nlbwmon_rx_packets", "counter")
    local tx_bytes = metric("nlbwmon_tx_bytes", "counter")
    local tx_packets = metric("nlbwmon_tx_packets", "counter")
    local device_info = metric("nlbwmon_device_info", "gauge")
    local device_names = load_device_names()
    local seen_devices = {}

    for _, row in ipairs(report.data) do
        local mac = safe_label(row[4])
        local ip = safe_label(row[5])
        local device_name = device_names[string.upper(mac)] or "unknown"
        local labels = {
            family = tonumber(row[1]) == 6 and "IPv6" or "IPv4",
            proto = safe_label(row[2]),
            port = safe_label(row[3]),
            mac = mac,
            ip = ip,
            layer7 = safe_label(row[11])
        }

        local device_key = mac .. "|" .. ip
        if not seen_devices[device_key] then
            device_info({mac = mac, ip = ip, device_name = device_name}, 1)
            seen_devices[device_key] = true
        end

        connections(labels, tonumber(row[6]) or 0)
        rx_bytes(labels, tonumber(row[7]) or 0)
        rx_packets(labels, tonumber(row[8]) or 0)
        tx_bytes(labels, tonumber(row[9]) or 0)
        tx_packets(labels, tonumber(row[10]) or 0)
    end
end

return { scrape = scrape }
