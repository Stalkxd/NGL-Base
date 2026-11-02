-- NGL air layer: where flying NPCs (the dropship) can fly, and where they can
-- land. Built from the ground nav grid, not a full 3D grid: every AIR_STRIDE-th
-- ground point that has open sky above it gets one air node, high over the
-- ground, linked to its neighbours when a ship-sized box fits between them.
-- Built once per loaded grid in the background (a few hundred traces), so
-- nothing needs to be saved. Maps with no open sky simply get no air nodes.

NGL.Air = NGL.Air or {}
local Air = NGL.Air

local floor, abs, huge, min = math.floor, math.abs, math.huge, math.min

local AIR_STRIDE = 4          -- every 4th ground point (384 units at 96 spacing)
local SKY_TRACE = 6000        -- how far up we look for the sky
local CEILING_GAP = 250       -- air nodes stay this far under the sky or ceiling
local ALTITUDE = 1200         -- ...and at most this high above the ground
local MIN_CLEARANCE = 600     -- at least this much air between ground and node
local SHIP_MINS, SHIP_MAXS = Vector(-160, -160, -80), Vector(160, 160, 80)
local BUILD_BUDGET = 0.002    -- s per tick while building

local upTrace = { mask = MASK_SOLID_BRUSHONLY }
local upResult = {}
upTrace.output = upResult
local hullTrace = { mask = MASK_SOLID_BRUSHONLY, mins = SHIP_MINS, maxs = SHIP_MAXS }
local hullResult = {}
hullTrace.output = hullResult

local function reset()
	Air.X, Air.Y, Air.Z, Air.G = {}, {}, {}, {} -- position, ground height below
	Air.NB = {}        -- [i] = { j, cost, ... }
	Air.Cell = {}      -- [ax * 65536 + ay] = i
	Air.Edge = {}      -- nodes at the edge of the open sky: where ships come and go
	Air.Count = 0
	Air.Ready = false
	Air.ForGrid = nil
end
if not Air.X then reset() end

local function cellKey(ax, ay) return (ax + 32768) * 65536 + (ay + 32768) end

local function build()
	reset()
	local Nav = NGL.Nav
	local S = Nav.S
	local stamp = SysTime()
	local function breathe()
		if SysTime() - stamp > BUILD_BUDGET then
			coroutine.yield()
			stamp = SysTime()
		end
	end

	-- Nodes: one per open-sky column on the stride grid (highest ground wins).
	for i = 1, Nav.Count do
		local ix, iy = Nav.NX[i], Nav.NY[i]
		if ix % AIR_STRIDE == 0 and iy % AIR_STRIDE == 0 then
			local gz = Nav.NZ[i]
			upTrace.start = Vector(ix * S, iy * S, gz + 64)
			upTrace.endpos = Vector(ix * S, iy * S, gz + SKY_TRACE)
			util.TraceLine(upTrace)
			local open = upResult.HitSky or not upResult.Hit
			if open then
				local top = upResult.Hit and upResult.HitPos.z or gz + SKY_TRACE
				local z = min(top - CEILING_GAP, gz + ALTITUDE)
				if z - gz >= MIN_CLEARANCE then
					local ax, ay = ix / AIR_STRIDE, iy / AIR_STRIDE
					local k = cellKey(ax, ay)
					local old = Air.Cell[k]
					if not old or Air.G[old] < gz then
						local n = old or Air.Count + 1
						if not old then Air.Count = n end
						Air.X[n], Air.Y[n], Air.Z[n], Air.G[n] = ix * S, iy * S, z, gz
						Air.Cell[k] = n
					end
				end
			end
			breathe()
		end
	end

	-- Links: 8 neighbours, if a ship fits along the way.
	local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }
	for k, n in pairs(Air.Cell) do
		local ax, ay = Air.X[n] / (S * AIR_STRIDE), Air.Y[n] / (S * AIR_STRIDE)
		local nb = Air.NB[n] or {}
		Air.NB[n] = nb
		local links = 0
		for _, d in ipairs(DIRS) do
			local j = Air.Cell[cellKey(ax + d[1], ay + d[2])]
			if j then
				hullTrace.start = Vector(Air.X[n], Air.Y[n], Air.Z[n])
				hullTrace.endpos = Vector(Air.X[j], Air.Y[j], Air.Z[j])
				util.TraceHull(hullTrace)
				if not (hullResult.Hit or hullResult.StartSolid) then
					nb[#nb + 1] = j
					nb[#nb + 1] = hullTrace.start:Distance(hullTrace.endpos)
					links = links + 1
				end
				breathe()
			end
		end
		if links > 0 and links < 8 then Air.Edge[#Air.Edge + 1] = n end
	end
	Air.Ready = true
	Air.ForGrid = Nav.Count .. ":" .. S
	print(string.format("[NGL] Air layer: %d nodes, %d at the edge of the sky.", Air.Count, #Air.Edge))
end

local buildCo
hook.Add("Tick", "NGL.Air", function()
	local Nav = NGL.Nav
	if not (Nav and Nav.Loaded) then return end
	if not buildCo then
		if Air.ForGrid == Nav.Count .. ":" .. Nav.S then return end
		buildCo = coroutine.create(build)
	end
	local ok, err = coroutine.resume(buildCo)
	if not ok then
		print("[NGL] Air layer build failed: " .. tostring(err))
		Air.ForGrid = Nav.Count .. ":" .. Nav.S -- don't retry every tick
		buildCo = nil
	elseif coroutine.status(buildCo) == "dead" then
		buildCo = nil
	end
end)
Air.Build = build -- tests and ngl_air_rebuild

function Air.Pos(n) return Vector(Air.X[n], Air.Y[n], Air.Z[n]) end

function Air.Nearest(pos)
	local best, bestD = nil, huge
	for n = 1, Air.Count do
		local dx, dy = Air.X[n] - pos.x, Air.Y[n] - pos.y
		local d = dx * dx + dy * dy
		if d < bestD then best, bestD = n, d end
	end
	return best, bestD
end

-- A* over the air nodes (a few hundred at most, so a plain open list is
-- fine; there is about one search per dropship trip). Returns positions.
function Air.Path(from, to)
	if not Air.Ready then return nil end
	local s, t = Air.Nearest(from), Air.Nearest(to)
	if not s or not t then return nil end
	local X, Y = Air.X, Air.Y
	local function h(n)
		local dx, dy = X[n] - X[t], Y[n] - Y[t]
		return math.sqrt(dx * dx + dy * dy)
	end
	local open, g, f, came, closed = { s }, { [s] = 0 }, { [s] = h(s) }, {}, {}
	while #open > 0 do
		local bi, best = 1, open[1]
		for i = 2, #open do
			if f[open[i]] < f[best] then bi, best = i, open[i] end
		end
		if best == t then
			local chain = { Air.Pos(t) }
			while came[best] do
				best = came[best]
				table.insert(chain, 1, Air.Pos(best))
			end
			return chain
		end
		table.remove(open, bi)
		closed[best] = true
		local nb = Air.NB[best] or {}
		for k = 1, #nb, 2 do
			local j = nb[k]
			if not closed[j] then
				local ng = g[best] + nb[k + 1]
				if not g[j] or ng < g[j] then
					if not g[j] then open[#open + 1] = j end
					g[j], f[j], came[j] = ng, ng + h(j), best
				end
			end
		end
	end
	return nil
end

-- An edge-of-sky point for a ship that lands at (or leaves from) `pos`:
-- out of sight but not across the map, so it changes with where the ship
-- is going (near the elite who called it). Prefers ENTRY_DIST away, on the
-- side away from `avoid` (the enemy), with a little chance in it so ships
-- don't all come the same way.
local ENTRY_MIN, ENTRY_DIST = 1500, 3000
function Air.EntryPoint(pos, avoid)
	local ax, ay
	if avoid then
		ax, ay = pos.x - avoid.x, pos.y - avoid.y
		local l = math.sqrt(ax * ax + ay * ay)
		if l > 1 then ax, ay = ax / l, ay / l else ax = nil end
	end
	local best, bestScore
	for _, n in ipairs(Air.Edge) do
		local p = Air.Pos(n)
		local dx, dy = p.x - pos.x, p.y - pos.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d > ENTRY_MIN then
			local score = -abs(d - ENTRY_DIST) / ENTRY_DIST + math.random() * 0.4
			if ax then score = score + 0.6 * (dx * ax + dy * ay) / d end
			if not bestScore or score > bestScore then best, bestScore = n, score end
		end
	end
	return best and Air.Pos(best)
end

-- A spot near `near` where a ship (half width `radius`) can come straight
-- down from the air layer and land: flat ground, nothing in the way, on the
-- side away from `avoid`. Returns ground position and the air node above.
local downTrace = { mask = MASK_SOLID }
local downResult = {}
downTrace.output = downResult
function Air.FindLanding(near, avoid, radius)
	local Nav = NGL.Nav
	if not (Air.Ready and Air.Count > 0 and Nav and Nav.Loaded) then return nil end
	radius = radius or 160
	local base = 0
	if avoid then
		local d = near - avoid
		base = math.atan2(d.y, d.x) -- away from the enemy
	end
	for try = 0, 7 do
		local a = base + ((try % 2 == 0) and 1 or -1) * floor((try + 1) / 2) * 0.45
		local dist = 500 + 150 * (try % 3)
		local p = Vector(near.x + math.cos(a) * dist, near.y + math.sin(a) * dist, near.z)
		local g = Nav.Nearest(p)
		if g then
			local gp = Nav.NodePos(g)
			-- Flat: the neighbours are all close to the same height.
			local flat = true
			local nb = Nav.NB[g] or {}
			for k = 1, #nb, 2 do
				if abs(Nav.NZ[nb[k]] - gp.z) > 20 then flat = false break end
			end
			local an = flat and Air.Nearest(gp)
			if an then
				local top = Vector(gp.x, gp.y, Air.Z[an])
				downTrace.start = top
				downTrace.endpos = Vector(gp.x, gp.y, gp.z + 24)
				downTrace.mins = Vector(-radius, -radius, 0)
				downTrace.maxs = Vector(radius, radius, 100)
				util.TraceHull(downTrace)
				if not (downResult.Hit or downResult.StartSolid) then
					return gp, top
				end
			end
		end
	end
	return nil
end

concommand.Add("ngl_air_info", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local msg = string.format("[NGL] Air layer: %s, %d nodes, %d edge nodes.",
		Air.Ready and "ready" or "not built", Air.Count, #Air.Edge)
	print(msg)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
end)
