local sys = require "luci.sys"

local f = SimpleForm("wiremesh_status", translate("Wired Mesh Status"),
	translate("Real-time mesh network topology and connected devices"))

f.reset = false
f.submit = false

-- ========== Mesh Overview ==========
local overview = f:section(SimpleSection, nil, translate("Mesh Overview"))

local ov = f:field(DummyValue, "_overview", "")
ov.rawhtml = true
ov.cfgvalue = function()
	local version = luci.util.trim(sys.exec("cat /sys/module/batman_adv/version 2>/dev/null") or "")
	local algo = luci.util.trim(sys.exec("cat /sys/class/net/bat0/mesh/routing_algo 2>/dev/null") or "")
	local bat0_up = luci.util.trim(sys.exec("cat /sys/class/net/bat0/operstate 2>/dev/null") or "")
	local local_mac = luci.util.trim(sys.exec("cat /sys/class/net/bat0/address 2>/dev/null") or "")

	if version == "" then
		return '<div style="padding:15px;background:#fff3cd;border-radius:6px;color:#856404">'
			.. '<strong>&#9888; ' .. translate("batman-adv module is not loaded or bat0 interface does not exist.") .. '</strong><br/>'
			.. translate("Please ensure mesh is enabled and configuration is applied.") .. '</div>'
	end

	return string.format(
		'<table class="table" style="max-width:500px">'
		.. '<tr><td style="width:40%%"><strong>%s</strong></td><td>%s</td></tr>'
		.. '<tr><td><strong>%s</strong></td><td>%s</td></tr>'
		.. '<tr><td><strong>%s</strong></td><td><span style="color:%s;font-weight:bold">%s</span></td></tr>'
		.. '<tr><td><strong>%s</strong></td><td><code>%s</code></td></tr>'
		.. '</table>',
		translate("batman-adv Version"), version,
		translate("Routing Algorithm"), algo,
		translate("Interface Status"),
		(bat0_up == "up") and "#28a745" or "#dc3545",
		(bat0_up == "up") and translate("Online") or translate("Offline"),
		translate("Local MAC"), local_mac
	)
end

-- ========== Mesh Topology (Nodes & Clients) ==========
local topo_section = f:section(SimpleSection, nil, translate("Mesh Network Topology"))

local topo = f:field(DummyValue, "_topology", "")
topo.rawhtml = true
topo.cfgvalue = function()
	local json = require "luci.jsonc"

	-- Fetch mesh client data inline
	local tg_raw = sys.exec("batctl meshif bat0 transglobal -n 2>/dev/null") or ""
	local client_node_map = {}
	for line in tg_raw:gmatch("[^\n]+") do
		local client_mac, via_mac = line:match("([0-9a-f:]+).-via ([0-9a-f:]+)")
		if client_mac and via_mac then
			client_node_map[client_mac:lower()] = via_mac:lower()
		end
	end

	-- DHCP leases
	local leases = {}
	local lf = io.open("/tmp/dhcp.leases", "r")
	if lf then
		for line in lf:lines() do
			local ts, mac, ip, name = line:match("(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)%s+(%S+)")
			if mac then
				leases[mac:lower()] = { ip = ip, hostname = (name ~= "*" and name or "") }
			end
		end
		lf:close()
	end

	-- Wireless clients
	local wifi_clients = {}
	local wifi_devs = sys.exec("ls /sys/class/net/ 2>/dev/null | grep -E '^wlan|^ra|^rai'") or ""
	for dev in wifi_devs:gmatch("%S+") do
		local assoc = sys.exec("iwinfo " .. dev .. " assoclist 2>/dev/null") or ""
		for mac, signal in assoc:gmatch("([0-9A-Fa-f:]+).-Signal:%s*(-?%d+)") do
			wifi_clients[mac:lower()] = { device = dev, signal = tonumber(signal) }
		end
	end

	-- Local node
	local local_mac = luci.util.trim(sys.exec("cat /sys/class/net/bat0/address 2>/dev/null") or ""):lower()

	-- Build node list from originators
	local nodes = {}
	local node_order = {}
	local orig_raw = sys.exec("batctl meshif bat0 originators -n 2>/dev/null") or ""
	for line in orig_raw:gmatch("[^\n]+") do
		local orig_mac = line:match("%*?%s*([0-9a-f:]+)")
		if orig_mac then
			orig_mac = orig_mac:lower()
			if not nodes[orig_mac] then
				nodes[orig_mac] = { mac = orig_mac, clients = {}, is_local = false }
				table.insert(node_order, orig_mac)
			end
		end
	end
	if local_mac ~= "" then
		if not nodes[local_mac] then
			nodes[local_mac] = { mac = local_mac, clients = {}, is_local = true }
			table.insert(node_order, 1, local_mac)
		else
			nodes[local_mac].is_local = true
		end
	end

	-- Assign clients to nodes
	for client_mac, node_mac in pairs(client_node_map) do
		if not nodes[client_mac] then
			local node = nodes[node_mac]
			if not node then
				nodes[node_mac] = { mac = node_mac, clients = {}, is_local = false }
				node = nodes[node_mac]
				table.insert(node_order, node_mac)
			end
			local lease = leases[client_mac] or {}
			local wifi = wifi_clients[client_mac]
			table.insert(node.clients, {
				mac = client_mac,
				ip = lease.ip or "-",
				hostname = lease.hostname or "-",
				connection = wifi and "wifi" or "wired",
				signal = wifi and wifi.signal or nil,
				wifi_device = wifi and wifi.device or nil
			})
		end
	end

	if #node_order == 0 then
		return '<div style="padding:15px;background:#f8f9fa;border-radius:6px;color:#6c757d;text-align:center">'
			.. translate("No mesh nodes detected. Please check mesh configuration and cable connections.") .. '</div>'
	end

	local html = {}
	for _, nmac in ipairs(node_order) do
		local node = nodes[nmac]
		local lease = leases[nmac] or {}
		local node_label = node.is_local
			and string.format('<span style="color:#007bff;font-weight:bold">&#127968; %s</span>', translate("This Node (Local)"))
			or string.format('&#128225; %s', translate("Remote Node"))

		table.insert(html, string.format(
			'<div style="margin-bottom:20px;border:1px solid #dee2e6;border-radius:8px;overflow:hidden">'
			.. '<div style="background:%s;padding:10px 15px;color:#fff">'
			.. '<strong>%s</strong> &mdash; <code>%s</code>',
			node.is_local and "#007bff" or "#6c757d",
			node_label, nmac
		))

		if lease.ip then
			table.insert(html, string.format(' &mdash; IP: <code>%s</code>', lease.ip))
		end
		if lease.hostname and lease.hostname ~= "" then
			table.insert(html, string.format(' &mdash; %s', lease.hostname))
		end

		table.insert(html, '</div>')

		-- Client table
		if #node.clients > 0 then
			table.insert(html,
				'<table class="table" style="margin:0">'
				.. '<tr style="background:#f8f9fa">'
				.. '<th style="width:20%">' .. translate("MAC Address") .. '</th>'
				.. '<th style="width:15%">' .. translate("IP Address") .. '</th>'
				.. '<th style="width:20%">' .. translate("Hostname") .. '</th>'
				.. '<th style="width:15%">' .. translate("Connection") .. '</th>'
				.. '<th style="width:15%">' .. translate("Signal (dBm)") .. '</th>'
				.. '<th style="width:15%">' .. translate("WiFi Device") .. '</th>'
				.. '</tr>'
			)
			for _, c in ipairs(node.clients) do
				local conn_icon, conn_color
				if c.connection == "wifi" then
					conn_icon = "&#128246; " .. translate("WiFi")
					conn_color = "#17a2b8"
				else
					conn_icon = "&#128268; " .. translate("Wired")
					conn_color = "#28a745"
				end
				table.insert(html, string.format(
					'<tr>'
					.. '<td><code>%s</code></td>'
					.. '<td>%s</td>'
					.. '<td>%s</td>'
					.. '<td><span style="color:%s;font-weight:bold">%s</span></td>'
					.. '<td>%s</td>'
					.. '<td>%s</td>'
					.. '</tr>',
					c.mac,
					c.ip,
					c.hostname,
					conn_color, conn_icon,
					c.signal and tostring(c.signal) or "-",
					c.wifi_device or "-"
				))
			end
			table.insert(html, '</table>')
		else
			table.insert(html,
				'<div style="padding:10px 15px;color:#6c757d;font-style:italic">'
				.. translate("No connected devices") .. '</div>')
		end

		table.insert(html, '</div>')
	end

	return table.concat(html)
end

-- ========== Neighbor Table ==========
local nb_section = f:section(SimpleSection, nil, translate("Neighbors"))

local nb = f:field(DummyValue, "_neighbors", "")
nb.rawhtml = true
nb.cfgvalue = function()
	local raw = sys.exec("batctl meshif bat0 neighbors -n 2>/dev/null") or ""
	if raw == "" then
		return '<em style="color:#6c757d">' .. translate("No neighbor data available") .. '</em>'
	end

	local html = {
		'<table class="table">',
		'<tr style="background:#f8f9fa">',
		'<th>' .. translate("Interface") .. '</th>',
		'<th>' .. translate("Neighbor MAC") .. '</th>',
		'<th>' .. translate("Last Seen (ms)") .. '</th>',
		'</tr>'
	}

	local has_data = false
	for line in raw:gmatch("[^\n]+") do
		-- Skip header lines
		if not line:match("^%s*IF") and not line:match("^%s*$") then
			local iface, neighbor, lastseen = line:match("(%S+)%s+([0-9a-f:]+)%s+([%d%.]+)")
			if iface and neighbor then
				has_data = true
				table.insert(html, string.format(
					'<tr><td>%s</td><td><code>%s</code></td><td>%s</td></tr>',
					iface, neighbor, lastseen or "-"
				))
			end
		end
	end

	if not has_data then
		return '<em style="color:#6c757d">' .. translate("No neighbors found") .. '</em>'
	end

	table.insert(html, '</table>')
	return table.concat(html)
end

-- ========== Originator Table ==========
local orig_section = f:section(SimpleSection, nil, translate("Originators"))

local orig = f:field(DummyValue, "_originators", "")
orig.rawhtml = true
orig.cfgvalue = function()
	local raw = sys.exec("batctl meshif bat0 originators -n 2>/dev/null") or ""
	if raw == "" then
		return '<em style="color:#6c757d">' .. translate("No originator data available") .. '</em>'
	end

	local html = {
		'<table class="table">',
		'<tr style="background:#f8f9fa">',
		'<th>' .. translate("Originator") .. '</th>',
		'<th>' .. translate("Last Seen (ms)") .. '</th>',
		'<th>' .. translate("Next Hop") .. '</th>',
		'<th>' .. translate("Outgoing IF") .. '</th>',
		'<th>' .. translate("Link Quality") .. '</th>',
		'</tr>'
	}

	local has_data = false
	for line in raw:gmatch("[^\n]+") do
		if not line:match("^%[") and not line:match("^%s*Originator") and not line:match("^%s*$") then
			-- BATMAN_IV format: * xx:xx:... 0.123s (xxx) xx:xx:... [ iface]
			-- BATMAN_V format: * xx:xx:... 0.123s ( throughput) xx:xx:... [ iface]
			local selected = line:match("^%s*%*") and true or false
			local orig_mac, lastseen, quality, nexthop, outif =
				line:match("([0-9a-f:]+)%s+([%d%.]+)s%s+%((%s*%S+)%)%s+([0-9a-f:]+)%s+%[%s*(%S+)")

			if orig_mac then
				has_data = true
				local row_style = selected and ' style="background:#e8f5e9;font-weight:bold"' or ''
				table.insert(html, string.format(
					'<tr%s><td><code>%s</code>%s</td><td>%s s</td><td><code>%s</code></td><td>%s</td><td>%s</td></tr>',
					row_style,
					orig_mac,
					selected and " &#9733;" or "",
					lastseen,
					nexthop, outif,
					luci.util.trim(quality)
				))
			end
		end
	end

	if not has_data then
		return '<em style="color:#6c757d">' .. translate("No originators found") .. '</em>'
	end

	table.insert(html, '</table>')
	return table.concat(html)
end

-- ========== Gateway Table ==========
local gw_section = f:section(SimpleSection, nil, translate("Gateway List"))

local gw = f:field(DummyValue, "_gateways", "")
gw.rawhtml = true
gw.cfgvalue = function()
	local uci = require "luci.model.uci".cursor()
	local gw_mode = uci:get("wiremesh", "general", "gw_mode") or "off"

	if gw_mode == "off" then
		return '<em style="color:#6c757d">' .. translate("Gateway mode is off. Set gateway mode to client or server to see gateway information.") .. '</em>'
	end

	local raw = sys.exec("batctl meshif bat0 gwl -n 2>/dev/null") or ""
	if raw == "" then
		return '<em style="color:#6c757d">' .. translate("No gateway data available") .. '</em>'
	end

	local html = {
		'<table class="table">',
		'<tr style="background:#f8f9fa">',
		'<th>' .. translate("Gateway") .. '</th>',
		'<th>' .. translate("Bandwidth") .. '</th>',
		'<th>' .. translate("Selected") .. '</th>',
		'</tr>'
	}

	local has_data = false
	for line in raw:gmatch("[^\n]+") do
		if not line:match("^%s*Gateway") and not line:match("^%s*$") then
			local selected = line:match("^%s*=>") and true or false
			local gw_mac, bw = line:match("([0-9a-f:]+).-%((%S+)%)")
			if gw_mac then
				has_data = true
				table.insert(html, string.format(
					'<tr%s><td><code>%s</code></td><td>%s</td><td>%s</td></tr>',
					selected and ' style="background:#e8f5e9;font-weight:bold"' or '',
					gw_mac, bw or "-",
					selected and "&#10004; " .. translate("Yes") or translate("No")
				))
			end
		end
	end

	if not has_data then
		return '<em style="color:#6c757d">' .. translate("No gateways found in the mesh") .. '</em>'
	end

	table.insert(html, '</table>')
	return table.concat(html)
end

-- ========== Auto Refresh Script ==========
local script_section = f:section(SimpleSection)
local js = f:field(DummyValue, "_js", "")
js.rawhtml = true
js.cfgvalue = function()
	return [[
<script type="text/javascript">
(function() {
	var pollInterval = 5000;
	function refreshStatus() {
		XHR.poll(pollInterval, ']] .. luci.dispatcher.build_url("admin", "network", "wiremesh", "mesh_status") .. [[', null,
			function(x, data) {
				// Status data received - page will auto-refresh via LuCI's built-in mechanisms
			}
		);
	}
	window.setTimeout(refreshStatus, 1000);
})();
</script>
]]
end

return f
