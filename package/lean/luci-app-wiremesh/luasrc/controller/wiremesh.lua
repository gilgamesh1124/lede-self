module("luci.controller.wiremesh", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/wiremesh") then
		return
	end

	local e = entry({"admin", "network", "wiremesh"}, firstchild(), _("Wired Mesh"), 75)
	e.dependent = false
	e.acl_depends = { "luci-app-wiremesh" }

	entry({"admin", "network", "wiremesh", "settings"}, cbi("wiremesh/settings"), _("Settings"), 10).leaf = true
	entry({"admin", "network", "wiremesh", "status"}, cbi("wiremesh/status"), _("Status"), 20).leaf = true

	entry({"admin", "network", "wiremesh", "mesh_status"}, call("action_mesh_status")).leaf = true
	entry({"admin", "network", "wiremesh", "mesh_clients"}, call("action_mesh_clients")).leaf = true
end

function action_mesh_status()
	local sys = require "luci.sys"
	local json = require "luci.jsonc"
	local data = {}

	data.originators = sys.exec("batctl meshif bat0 originators -n 2>/dev/null") or ""
	data.neighbors = sys.exec("batctl meshif bat0 neighbors -n 2>/dev/null") or ""
	data.gateways = sys.exec("batctl meshif bat0 gwl -n 2>/dev/null") or ""
	data.interfaces = sys.exec("batctl meshif bat0 interface 2>/dev/null") or ""
	data.routing_algo = luci.util.trim(sys.exec("cat /sys/class/net/bat0/mesh/routing_algo 2>/dev/null") or "")
	data.version = luci.util.trim(sys.exec("cat /sys/module/batman_adv/version 2>/dev/null") or "")

	luci.http.prepare_content("application/json")
	luci.http.write(json.stringify(data))
end

function action_mesh_clients()
	local sys = require "luci.sys"
	local json = require "luci.jsonc"
	local uci = require "luci.model.uci".cursor()
	local data = {}

	-- Get mesh nodes from transglobal table
	local tg_raw = sys.exec("batctl meshif bat0 transglobal -n 2>/dev/null") or ""

	-- Parse transglobal: maps client MAC -> originator MAC (which mesh node it's behind)
	local client_node_map = {}
	for line in tg_raw:gmatch("[^\n]+") do
		-- Format: " * xx:xx:xx:xx:xx:xx ... via xx:xx:xx:xx:xx:xx ..."
		local client_mac, via_mac = line:match("([0-9a-f:]+).-via ([0-9a-f:]+)")
		if client_mac and via_mac then
			client_node_map[client_mac:lower()] = via_mac:lower()
		end
	end

	-- Get DHCP leases for IP/hostname mapping
	local leases = {}
	local lease_file = io.open("/tmp/dhcp.leases", "r")
	if lease_file then
		for line in lease_file:lines() do
			local ts, mac, ip, name = line:match("(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)%s+(%S+)")
			if mac then
				leases[mac:lower()] = { ip = ip, hostname = (name ~= "*" and name or "") }
			end
		end
		lease_file:close()
	end

	-- Get wireless association list (to distinguish wifi vs wired + signal strength)
	local wifi_clients = {}
	local wifi_devs = sys.exec("ls /sys/class/net/ 2>/dev/null | grep -E '^wlan|^ra|^rai'") or ""
	for dev in wifi_devs:gmatch("%S+") do
		local assoc = sys.exec("iwinfo " .. dev .. " assoclist 2>/dev/null") or ""
		for mac, signal in assoc:gmatch("([0-9A-Fa-f:]+).-Signal:%s*(-?%d+)") do
			wifi_clients[mac:lower()] = {
				device = dev,
				signal = tonumber(signal)
			}
		end
	end

	-- Get local node MAC (bat0 MAC)
	local local_mac = luci.util.trim(sys.exec("cat /sys/class/net/bat0/address 2>/dev/null") or ""):lower()

	-- Get originator list to build node list
	local nodes = {}
	local orig_raw = sys.exec("batctl meshif bat0 originators -n 2>/dev/null") or ""
	-- Add all known originators as nodes
	for line in orig_raw:gmatch("[^\n]+") do
		local orig_mac = line:match("%*?%s*([0-9a-f:]+)")
		if orig_mac then
			orig_mac = orig_mac:lower()
			if not nodes[orig_mac] then
				nodes[orig_mac] = { mac = orig_mac, clients = {} }
			end
		end
	end
	-- Add local node
	if local_mac ~= "" then
		if not nodes[local_mac] then
			nodes[local_mac] = { mac = local_mac, clients = {} }
		end
		nodes[local_mac].is_local = true
	end

	-- Assign clients to their originator nodes
	for client_mac, node_mac in pairs(client_node_map) do
		-- Skip mesh node MACs themselves
		if not nodes[client_mac] then
			local node = nodes[node_mac]
			if not node then
				nodes[node_mac] = { mac = node_mac, clients = {} }
				node = nodes[node_mac]
			end

			local lease = leases[client_mac] or {}
			local wifi = wifi_clients[client_mac]

			local client_info = {
				mac = client_mac,
				ip = lease.ip or "",
				hostname = lease.hostname or "",
				connection = wifi and "wifi" or "wired",
				signal = wifi and wifi.signal or nil,
				wifi_device = wifi and wifi.device or nil
			}
			table.insert(node.clients, client_info)
		end
	end

	-- Convert to indexed array
	local result = {}
	for _, node in pairs(nodes) do
		local lease = leases[node.mac] or {}
		node.ip = lease.ip or ""
		node.hostname = lease.hostname or ""
		table.insert(result, node)
	end

	data.nodes = result
	data.local_mac = local_mac

	luci.http.prepare_content("application/json")
	luci.http.write(json.stringify(data))
end
