-- NGL navigation: our own walk grid, generated per map with traces.
--
-- No navmesh, no AI nodes. `ngl_nav_generate` flood-fills the walkable area
-- from the map's spawn points (and players), one grid point every
-- `ngl_nav_spacing` units, linking neighbours an NPC hull can walk between.
-- The grid is saved to data/ngl_nav/<map>.dat and loaded on map start.
--
-- Paths are found with A* in coroutines that share one CPU budget per tick
-- (`ngl_nav_budget`), so a burst of path requests never causes a lag spike.
-- Requests from roughly the same spot to roughly the same goal share one
-- search, results are cached briefly, the queue is capped, and searches nobody
-- is waiting for any more are dropped, so a squad pays for one path and a
-- flood of requests can't build an endless backlog.
--
-- With no grid for the map it is generated on its own (ngl_nav_auto). The
-- generator walks through doors (NPCs open or kick them) and links ledges to
-- the ground below: NPCs jump down small drops (ENT.JumpDown) and Combine
-- rappel down big ones (ENT.Rappel). Players can fix the grid in game with
-- the NGL Nav Editor tool (sv_nav_edit.lua): add or remove walkable area and
-- place jump links. Edits are kept apart from the generated grid
-- (data/ngl_nav/<map>_edits.txt), so they survive regenerating it.

NGL.Nav = NGL.Nav or {}
local Nav = NGL.Nav

local floor, sqrt, abs, huge = math.floor, math.sqrt, math.abs, math.huge
local SysTime, CurTime = SysTime, CurTime

local cvSpacing = CreateConVar("ngl_nav_spacing", "96", FCVAR_ARCHIVE, "Grid spacing used by ngl_nav_generate (units).", 48, 256)
local cvMaxNodes = CreateConVar("ngl_nav_max_nodes", "150000", FCVAR_ARCHIVE, "Stop ngl_nav_generate after this many grid points.", 1000, 1000000)
local cvGenBudget = CreateConVar("ngl_nav_gen_budget", "20", FCVAR_ARCHIVE, "Milliseconds per tick ngl_nav_generate may use.", 1, 500)
local cvBudget = CreateConVar("ngl_nav_budget", "2", FCVAR_ARCHIVE, "Milliseconds per tick for NPC path-finding.", 0.1, 50)
local cvMaxExpand = CreateConVar("ngl_nav_max_expand", "8000", FCVAR_ARCHIVE, "Give up a path search after expanding this many grid points.", 100, 1000000)
local cvMaxQueue = CreateConVar("ngl_nav_max_queue", "64", FCVAR_ARCHIVE, "Path requests beyond this many queued searches fail at once (the NPC walks straight).", 1, 10000)
local cvAuto = CreateConVar("ngl_nav_auto", "1", FCVAR_ARCHIVE, "Generate the NGL nav grid on its own when a map has none (0 = only with ngl_nav_generate).", 0, 1)
local cvDrops = CreateConVar("ngl_nav_drops", "1", FCVAR_ARCHIVE, "ngl_nav_generate links ledges to the ground below, so NPCs can jump or rappel down.", 0, 1)
local cvMaxDrop = CreateConVar("ngl_nav_max_drop", "1000", FCVAR_ARCHIVE, "Highest ledge (units) ngl_nav_generate links to the ground below.", 64, 4000)

-- Hull the generator checks against: a standing NPC above step height.
local STEP = 18
local HULL_MINS = Vector(-15, -15, 0)
local HULL_MAXS = Vector(15, 15, 72 - STEP)
local MIN_NORMAL_Z = 0.7 -- steeper than ~45 degrees is not walkable

local DIRS = {
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 },
}
local OPP = { 2, 1, 4, 3, 6, 5, 8, 7 }
local DIR_COST = { 1, 1, 1, 1, 1.4142, 1.4142, 1.4142, 1.4142 }

----------------------------------------------------------------------------
-- Storage
----------------------------------------------------------------------------
-- Node i: grid coords NX[i], NY[i], height NZ[i], edge bitmask NM[i].
-- Neighbours are resolved after load into NB[i] = { j1, c1, j2, c2, ... }.

local function cellKey(ix, iy)
	return (ix + 32768) * 65536 + (iy + 32768)
end

local searches = {}   -- running path searches (coroutines), oldest first
Nav.Stats = Nav.Stats or { ok = 0, fail = 0, dropped = 0, rejected = 0, cached = 0 }

local function reset()
	Nav.S = cvSpacing:GetInt()
	Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.NB = {}, {}, {}, {}, {}
	Nav.Cells = {}
	Nav.Count = 0
	Nav.Dead = {}  -- removed by an edit, until the next compact()
	Nav.Links = {} -- one-way jumps: { a = node, b = node, kind = "drop" | "jump", h = drop height }
	Nav.LB = {}    -- [node] = { link index, ... } leaving it
	Nav.Loaded = false
	Nav.Cache = {}
	Nav.Pending = {}
	Nav.Wide = {} -- [half width] = { [node] = true/false }, filled lazily by wide searches
	-- Searches over the old grid are meaningless now. Their callers time out
	-- on their own (see chase in sv_core.lua).
	for k in pairs(searches) do searches[k] = nil end
end

if not Nav.NX then reset() end

local function addNode(ix, iy, z)
	local n = Nav.Count + 1
	Nav.Count = n
	Nav.NX[n], Nav.NY[n], Nav.NZ[n], Nav.NM[n] = ix, iy, z, 0
	local k = cellKey(ix, iy)
	local c = Nav.Cells[k]
	if not c then
		c = {}
		Nav.Cells[k] = c
	end
	c[#c + 1] = n
	return n
end

-- Node at grid cell (ix, iy) whose height is closest to z, within tol.
local function nodeAt(ix, iy, z, tol)
	local c = Nav.Cells[cellKey(ix, iy)]
	if not c then return nil end
	local best, bestD = nil, tol
	local dead = Nav.Dead
	for i = 1, #c do
		local d = abs(Nav.NZ[c[i]] - z)
		if d <= bestD and not (dead and dead[c[i]]) then best, bestD = c[i], d end
	end
	return best
end

local function nodePos(i)
	local S = Nav.S
	return Vector(Nav.NX[i] * S, Nav.NY[i] * S, Nav.NZ[i])
end
Nav.NodePos = nodePos

local function buildNeighbours()
	local S = Nav.S
	local tol = S * 0.75 + 8
	for i = 1, Nav.Count do
		local nb = {}
		local m, ix, iy, z = Nav.NM[i], Nav.NX[i], Nav.NY[i], Nav.NZ[i]
		for d = 1, 8 do
			if bit.band(m, bit.lshift(1, d - 1)) ~= 0 then
				local j = nodeAt(ix + DIRS[d][1], iy + DIRS[d][2], z, tol)
				if j then
					nb[#nb + 1] = j
					nb[#nb + 1] = DIR_COST[d]
				end
			end
		end
		Nav.NB[i] = nb
	end
end

-- Links leaving each node, for the search.
local function buildLinks()
	local LB = {}
	for k, L in ipairs(Nav.Links) do
		local t = LB[L.a]
		if not t then t = {}; LB[L.a] = t end
		t[#t + 1] = k
	end
	Nav.LB = LB
end
Nav.BuildLinks = buildLinks

local function addLink(a, b, kind, h)
	for _, L in ipairs(Nav.Links) do
		if L.a == a and L.b == b then return L end
	end
	local L = { a = a, b = b, kind = kind, h = h }
	Nav.Links[#Nav.Links + 1] = L
	return L
end

-- Nearest node to a world position (searches up to 2 cells around).
function Nav.Nearest(pos)
	if not Nav.Loaded then return nil end
	local S = Nav.S
	local cx, cy = floor(pos.x / S + 0.5), floor(pos.y / S + 0.5)
	local best, bestD = nil, huge
	for r = 0, 2 do
		for x = cx - r, cx + r do
			for y = cy - r, cy + r do
				if r == 0 or abs(x - cx) == r or abs(y - cy) == r then
					local c = Nav.Cells[cellKey(x, y)]
					if c then
						for k = 1, #c do
							local i = c[k]
							local dz = Nav.NZ[i] - pos.z
							if dz < 80 and dz > -120 and not Nav.Dead[i] then
								local dx, dy = x * S - pos.x, y * S - pos.y
								local d = dx * dx + dy * dy + dz * dz * 4
								if d < bestD then best, bestD = i, d end
							end
						end
					end
				end
			end
		end
		if best then return best end
	end
	return nil
end

-- A short stroll along the grid for idle NPCs: walk up to `cells` points in
-- a random direction, turning (at most twice) at walls or where the walk
-- would leave `radius` around `home`. Costs a few table reads, no search.
-- Returns a list of waypoints, or nil off the grid.
function Nav.RandomWalk(pos, home, radius, cells)
	local cur = Nav.Nearest(pos)
	if not cur then return nil end
	local NX, NY, NB, S = Nav.NX, Nav.NY, Nav.NB, Nav.S
	local hx, hy = home.x / S, home.y / S
	local r2 = (radius / S) ^ 2
	local d = DIRS[math.random(8)]
	local pts = {}
	local turns, corner = 0, nil
	for _ = 1, cells do
		local nxt
		local nb = NB[cur]
		local x, y = NX[cur], NY[cur]
		for k = 1, #nb, 2 do
			local j = nb[k]
			if NX[j] - x == d[1] and NY[j] - y == d[2] then
				local ex, ey = NX[j] - hx, NY[j] - hy
				if ex * ex + ey * ey <= r2 then nxt = j end
				break
			end
		end
		if nxt then
			cur = nxt
		else
			if turns >= 2 then break end
			turns = turns + 1
			if cur ~= corner then
				pts[#pts + 1] = nodePos(cur)
				corner = cur
			end
			d = DIRS[math.random(8)]
		end
	end
	if cur ~= corner then pts[#pts + 1] = nodePos(cur) end
	return pts
end

----------------------------------------------------------------------------
-- Save / load
----------------------------------------------------------------------------

local function navPath()
	return "ngl_nav/" .. game.GetMap() .. ".dat"
end

-- The generated grid (edits are kept apart, see sv_nav_edit.lua).
-- Format: header, one line per point, then "LINKS" and one line per link.
local KIND_CODE, CODE_KIND = { drop = 1, jump = 2 }, { "drop", "jump" }

function Nav.Save()
	local parts = { string.format("NGLNAV2 %d %d", Nav.S, Nav.Count) }
	for i = 1, Nav.Count do
		parts[#parts + 1] = string.format("%d %d %.1f %d", Nav.NX[i], Nav.NY[i], Nav.NZ[i], Nav.NM[i])
	end
	parts[#parts + 1] = "LINKS"
	for _, L in ipairs(Nav.Links) do
		parts[#parts + 1] = string.format("%d %d %d %.1f", L.a, L.b, KIND_CODE[L.kind] or 1, L.h or 0)
	end
	file.CreateDir("ngl_nav")
	file.Write(navPath(), util.Compress(table.concat(parts, "\n")))
end

-- Loads the generated grid, then puts the edits back on (Nav.ApplyEdits).
function Nav.Load()
	local raw = file.Read(navPath(), "DATA")
	if not raw then return false end
	local text = util.Decompress(raw)
	if not text then return false end

	local header, rest = text:match("^([^\n]*)\n?(.*)$")
	local S = header and tonumber(header:match("^NGLNAV[12] (%d+)"))
	if not S then return false end

	reset()
	Nav.S = S
	local nodes, links = rest, nil
	local cut = rest:find("LINKS", 1, true)
	if cut then nodes, links = rest:sub(1, cut - 1), rest:sub(cut + 5) end
	for ix, iy, z, m in nodes:gmatch("(-?%d+) (-?%d+) (-?[%d%.]+) (%d+)") do
		local i = addNode(tonumber(ix), tonumber(iy), tonumber(z))
		Nav.NM[i] = tonumber(m)
	end
	if links then
		local n = Nav.Count
		for a, b, k, h in links:gmatch("(%d+) (%d+) (%d+) (-?[%d%.]+)") do
			a, b = tonumber(a), tonumber(b)
			if a <= n and b <= n then addLink(a, b, CODE_KIND[tonumber(k)] or "drop", tonumber(h)) end
		end
	end
	buildNeighbours()
	buildLinks()
	Nav.Loaded = Nav.Count > 0
	if Nav.ApplyEdits then Nav.ApplyEdits() end
	return Nav.Loaded
end

----------------------------------------------------------------------------
-- Generation
----------------------------------------------------------------------------

local groundTrace = { mask = MASK_NPCSOLID_BRUSHONLY }
local groundResult = {}
groundTrace.output = groundResult

local hullTrace = { mask = MASK_NPCSOLID_BRUSHONLY, mins = HULL_MINS, maxs = HULL_MAXS }
local hullResult = {}
hullTrace.output = hullResult

-- Doors don't block the grid: NPCs open them or kick them in (sv_doors.lua).
local DOOR_CLASSES = { "prop_door_rotating", "func_door", "func_door_rotating" }
local function doorFilter()
    local list = {}
    for _, cls in ipairs(DOOR_CLASSES) do
        for _, e in ipairs(ents.FindByClass(cls)) do list[#list + 1] = e end
    end
    groundTrace.filter, hullTrace.filter = list, list
end

-- Ground height at (x, y) searching from zTop down to zBottom, or nil.
local function groundAt(x, y, zTop, zBottom)
    groundTrace.start = Vector(x, y, zTop)
    groundTrace.endpos = Vector(x, y, zBottom)
    util.TraceLine(groundTrace)
    if groundResult.StartSolid or not groundResult.Hit or groundResult.HitNormal.z < MIN_NORMAL_Z then
        return nil
    end
    return groundResult.HitPos.z
end

local function walkable(ax, ay, az, bx, by, bz)
    hullTrace.start = Vector(ax, ay, az + STEP)
    hullTrace.endpos = Vector(bx, by, bz + STEP)
    util.TraceHull(hullTrace)
    return not hullResult.Hit and not hullResult.StartSolid
end

local function seedPositions()
    local seeds = {}
    for _, cls in ipairs({ "info_player_start", "info_player_deathmatch", "info_player_combine",
        "info_player_rebel", "info_player_terrorist", "info_player_counterterrorist", "gmod_player_start" }) do
        for _, e in ipairs(ents.FindByClass(cls)) do seeds[#seeds + 1] = e:GetPos() end
    end
    for _, ply in ipairs(player.GetAll()) do seeds[#seeds + 1] = ply:GetPos() end
    return seeds
end

-- Links node i to its 8 neighbours where a person can walk, adding new
-- points to `queue`. `canAdd(ix, iy, z)`, if given, says where new points
-- may go (the editor's add tool keeps to its circle). With drops on, a
-- straight step off a ledge with ground further down (up to
-- ngl_nav_max_drop) gets a one-way drop link to a point down there.
local function expandNode(i, queue, maxNodes, canAdd, drops)
    local S = Nav.S
    local maxUp = math.min(S * 0.75, 64)
    local maxDown = 64
    local ix, iy, z = Nav.NX[i], Nav.NY[i], Nav.NZ[i]
    local ax, ay = ix * S, iy * S
    for d = 1, 8 do
        local bit_d = bit.lshift(1, d - 1)
        if bit.band(Nav.NM[i], bit_d) == 0 then
            local nx, ny = ix + DIRS[d][1], iy + DIRS[d][2]
            local bx, by = nx * S, ny * S
            local gz = groundAt(bx, by, z + maxUp + 8, z - maxDown)
            if gz then
                if walkable(ax, ay, z, bx, by, gz) then
                    local j = nodeAt(nx, ny, gz, 32)
                    if not j and Nav.Count < maxNodes and (not canAdd or canAdd(nx, ny, gz)) then
                        j = addNode(nx, ny, gz)
                        queue[#queue + 1] = j
                    end
                    if j then
                        Nav.NM[i] = bit.bor(Nav.NM[i], bit_d)
                        Nav.NM[j] = bit.bor(Nav.NM[j], bit.lshift(1, OPP[d] - 1))
                    end
                end
            elseif drops and d <= 4 then
                -- Nothing within a step down: a ledge. Room to walk off it and
                -- to fall straight down to ground further below?
                local low = groundAt(bx, by, z + 8, z - drops)
                if low and z - low > maxDown and walkable(ax, ay, z, bx, by, z) and walkable(bx, by, z, bx, by, low) then
                    local j = nodeAt(nx, ny, low, 32)
                    if not j and Nav.Count < maxNodes and (not canAdd or canAdd(nx, ny, low)) then
                        j = addNode(nx, ny, low)
                        queue[#queue + 1] = j
                    end
                    if j then addLink(i, j, "drop", z - low) end
                end
            end
        end
    end
end

-- Flood-fills from the queue (all of it, or `budget` seconds at a time when
-- run in a coroutine, with `report` now and then).
local function flood(queue, maxNodes, canAdd, drops, budget, report)
    local head = 1
    local t0, lastReport = SysTime(), SysTime()
    while head <= #queue do
        expandNode(queue[head], queue, maxNodes, canAdd, drops)
        head = head + 1
        if budget and SysTime() - t0 > budget then
            if report and SysTime() - lastReport > 2 then
                lastReport = SysTime()
                report(string.format("Generating... %d points, %d queued", Nav.Count, #queue - head + 1))
            end
            coroutine.yield()
            t0 = SysTime()
        end
    end
end

local genRoutine = nil

local function generate(report)
    reset()
    local S = Nav.S
    local maxNodes = cvMaxNodes:GetInt()
    local queue = {}
    doorFilter()

    for _, p in ipairs(seedPositions()) do
        local ix, iy = floor(p.x / S + 0.5), floor(p.y / S + 0.5)
        local z = groundAt(ix * S, iy * S, p.z + 32, p.z - 256)
        if z and not nodeAt(ix, iy, z, 32) then
            queue[#queue + 1] = addNode(ix, iy, z)
        end
    end
    if #queue == 0 then
        report("No spawn points or players to start from. Stand on the map and try again.")
        return
    end

    flood(queue, maxNodes, nil, cvDrops:GetBool() and cvMaxDrop:GetFloat() or nil, cvGenBudget:GetFloat() / 1000, report)

    buildNeighbours()
    buildLinks()
    Nav.Loaded = Nav.Count > 0
    Nav.Save()
    local base = Nav.Count
    if Nav.ApplyEdits then Nav.ApplyEdits() end
    report(string.format("Done: %d points, %d ledge links at %d-unit spacing%s. Saved to garrysmod/data/%s%s",
        base, #Nav.Links, S, base >= maxNodes and " (hit ngl_nav_max_nodes, map may be partly covered)" or "", navPath(),
        (Nav.Edits and #Nav.Edits > 0) and string.format(" (+ %d edits)", #Nav.Edits) or ""))
end

-- For the editor (sv_nav_edit.lua).
Nav._I = {
    addNode = addNode, nodeAt = nodeAt, addLink = addLink, cellKey = cellKey,
    groundAt = groundAt, walkable = walkable, flood = flood, doorFilter = doorFilter,
    buildNeighbours = buildNeighbours, buildLinks = buildLinks, reset = reset,
    clearSearches = function() for k in pairs(searches) do searches[k] = nil end end,
    maxNodes = function() return cvMaxNodes:GetInt() end,
    maxDrop = function() return cvDrops:GetBool() and cvMaxDrop:GetFloat() or nil end,
}

----------------------------------------------------------------------------
-- Path-finding (A* in budgeted coroutines)
----------------------------------------------------------------------------

local CACHE_TIME = 4
local REGION = 3        -- start points within REGION x REGION cells share a search
local GOAL_REGION = 2   -- same for goal points
local Z_BAND = 128      -- ...as long as they are on the same floor

-- Binary min-heap on f-score, stored in two parallel arrays.
local function heapPush(hn, hf, size, node, f)
	size = size + 1
	local i = size
	while i > 1 do
		local p = floor(i / 2)
		if hf[p] <= f then break end
		hn[i], hf[i] = hn[p], hf[p]
		i = p
	end
	hn[i], hf[i] = node, f
	return size
end

local function heapPop(hn, hf, size)
	local top = hn[1]
	local ln, lf = hn[size], hf[size]
	hn[size], hf[size] = nil, nil
	size = size - 1
	local i = 1
	while true do
		local l = i * 2
		if l > size then break end
		local r = l + 1
		local c = (r <= size and hf[r] < hf[l]) and r or l
		if hf[c] >= lf then break end
		hn[i], hf[i] = hn[c], hf[c]
		i = c
	end
	if size > 0 then hn[i], hf[i] = ln, lf end
	return top, size
end

local function heuristic(a, b)
	local dx, dy = abs(Nav.NX[a] - Nav.NX[b]), abs(Nav.NY[a] - Nav.NY[b])
	return (dx > dy) and (dx + 0.4142 * dy) or (dy + 0.4142 * dx)
end

-- How an NPC with these capabilities (ENT.JumpDown, ENT.Rappel...) gets
-- along a link: "jump" (jump down, or across a gap), "rappel", or nil.
local function linkMove(L, caps)
	if not caps then return nil end
	if L.kind == "jump" then return caps.gap and "jump" or nil end
	local h = L.h or 0
	if h <= (caps.drop or 0) then return "jump" end
	if h <= (caps.rappel or 0) then return "rappel" end
	return nil
end
Nav.LinkMove = linkMove

-- Turns a node chain into waypoints, dropping points on straight runs.
-- linkIn[k]: the link taken from chain[k - 1] to chain[k]. Both ends of a
-- link are kept, and pts.links[w] = { move = "jump" | "rappel", h = height }
-- marks waypoint w as the take-off point (w + 1 is where it lands).
local function toWaypoints(chain, linkIn, caps)
	local pts = {}
	local n = #chain
	for k = 1, n do
		local keep = (k == 1 or k == n)
		if not keep then
			local a, b, c = chain[k - 1], chain[k], chain[k + 1]
			local d1x, d1y = Nav.NX[b] - Nav.NX[a], Nav.NY[b] - Nav.NY[a]
			local d2x, d2y = Nav.NX[c] - Nav.NX[b], Nav.NY[c] - Nav.NY[b]
			keep = d1x ~= d2x or d1y ~= d2y or abs(Nav.NZ[c] - Nav.NZ[b]) > 24
				or (linkIn and (linkIn[k] or linkIn[k + 1])) or false
		end
		if keep then pts[#pts + 1] = nodePos(chain[k]) end
		local L = linkIn and linkIn[k + 1]
		if L then
			pts.links = pts.links or {}
			pts.links[#pts] = { move = linkMove(L, caps), h = L.h or 0 }
		end
	end
	return pts
end

-- Wide NPCs (vehicles, big monsters): the grid is checked for a person-sized
-- hull, so a wide search also tests each node it reaches with a box of the
-- NPC's half width, once, and remembers the answer for every later search.
local wideTrace = { mask = MASK_NPCSOLID_BRUSHONLY }
local wideResult = {}
wideTrace.output = wideResult
local WIDE_HEIGHT = 64

local function wideOk(n, width, known)
	local ok = known[n]
	if ok == nil then
		local p = nodePos(n)
		p.z = p.z + STEP + 4
		wideTrace.start, wideTrace.endpos = p, p
		wideTrace.mins = Vector(-width, -width, 0)
		wideTrace.maxs = Vector(width, width, WIDE_HEIGHT)
		util.TraceHull(wideTrace)
		ok = not (wideResult.Hit or wideResult.StartSolid)
		known[n] = ok
	end
	return ok
end
Nav.WideOk = function(n, width)
	Nav.Wide[width] = Nav.Wide[width] or {}
	return wideOk(n, width, Nav.Wide[width])
end

local function search(start, goal, width, caps)
	local known
	if width then
		Nav.Wide[width] = Nav.Wide[width] or {}
		known = Nav.Wide[width]
	end
	local traced = 0
	local hn, hf, size = {}, {}, 0
	local g, came, closed = { [start] = 0 }, {}, {}
	local LB, Links = caps and Nav.LB, Nav.Links
	local viaLink = LB and {}
	size = heapPush(hn, hf, size, start, heuristic(start, goal))
	local maxExpand = cvMaxExpand:GetInt()
	local expanded = 0

	while size > 0 do
		local cur
		cur, size = heapPop(hn, hf, size)
		if cur == goal then
			local chain, linkIn = { cur }, viaLink and {}
			local rev = { viaLink and viaLink[cur] or false }
			while came[cur] do
				cur = came[cur]
				table.insert(chain, 1, cur)
				table.insert(rev, 1, viaLink and viaLink[cur] or false)
			end
			if linkIn then
				for k = 1, #chain do if rev[k] then linkIn[k] = rev[k] end end
				if next(linkIn) == nil then linkIn = nil end
			end
			return toWaypoints(chain, linkIn, caps)
		end
		if not closed[cur] then
			closed[cur] = true
			expanded = expanded + 1
			if expanded > maxExpand then return nil end

			local nb = Nav.NB[cur]
			local gc = g[cur]
			for k = 1, #nb, 2 do
				local j = nb[k]
				local pass = true
				if known and j ~= goal then
					if known[j] == nil then traced = traced + 1 end
					pass = wideOk(j, width, known)
				end
				if pass and not closed[j] then
					local ng = gc + nb[k + 1]
					local old = g[j]
					if not old or ng < old then
						g[j] = ng
						came[j] = cur
						if viaLink then viaLink[j] = nil end
						size = heapPush(hn, hf, size, j, ng + heuristic(j, goal))
					end
				end
			end

			-- Jumps and drops this NPC can take.
			local out = LB and LB[cur]
			if out then
				for k = 1, #out do
					local L = Links[out[k]]
					local j = L.b
					if not closed[j] and linkMove(L, caps) then
						local dx, dy = Nav.NX[j] - Nav.NX[cur], Nav.NY[j] - Nav.NY[cur]
						local ng = gc + sqrt(dx * dx + dy * dy) + 3 -- a bit dearer than walking
						local old = g[j]
						if not old or ng < old then
							g[j] = ng
							came[j] = cur
							viaLink[j] = L
							size = heapPush(hn, hf, size, j, ng + heuristic(j, goal))
						end
					end
				end
			end

			if expanded % 64 == 0 or traced >= 16 then
				traced = 0
				coroutine.yield()
			end
		end
	end
	return nil
end

-- What an NPC class can do on links, from its ENT fields; one shared
-- table per combination (its key is part of the path cache key).
local capsCache = {}
function Nav.Caps(ent)
	local drop = ent.JumpDown or 0
	local rappel = ent.Rappel and (ent.RappelMax or 1000) or 0
	local gap = ent.JumpGap and true or false
	if drop <= 0 and rappel <= 0 and not gap then return nil end
	local key = string.format("c%d:%d:%s", drop, rappel, gap and 1 or 0)
	local c = capsCache[key]
	if not c then
		c = { key = key, drop = drop, rappel = rappel, gap = gap }
		capsCache[key] = c
	end
	return c
end

local function regionKey(s, t)
	local NX, NY, NZ = Nav.NX, Nav.NY, Nav.NZ
	return string.format("%d:%d:%d|%d:%d:%d",
		floor(NX[s] / REGION), floor(NY[s] / REGION), floor(NZ[s] / Z_BAND),
		floor(NX[t] / GOAL_REGION), floor(NY[t] / GOAL_REGION), floor(NZ[t] / Z_BAND))
end

-- Asks for a path from `from` to `to`. `callback(waypoints or nil)` is called
-- later, or right away for a cached path, an unreachable spot or a full queue.
-- Returns false if there is no nav grid.
--
-- The path may start a few cells away from `from` (requests from the same
-- area share one search), so callers should pick the nearest early waypoint.
-- `wanted`, if given, is called before each slice of work; when it returns
-- false for every waiter the search is dropped. Never modify the returned
-- table: it is shared with other NPCs and the cache.
-- `width` (half width in units, optional) asks for a path a wide NPC fits
-- through; anything up to 24 counts as person-sized.
-- `caps` (optional, see Nav.Caps) lets the path jump down ledges, across
-- gaps or rappel; such paths have `path.links` (see toWaypoints).
function Nav.RequestPath(from, to, callback, wanted, width, caps)
	if width and width <= 24 then width = nil end
	if caps and #Nav.Links == 0 then caps = nil end
	if width then width = math.ceil(width / 8) * 8 end -- few width classes, more shared work
	if not Nav.Loaded then return false end
	local st = Nav.Stats
	local s, t = Nav.Nearest(from), Nav.Nearest(to)
	if not s or not t then
		st.fail = st.fail + 1
		callback(nil)
		return true
	end

	local key = regionKey(s, t)
	if width then key = "w" .. width .. "|" .. key end
	if caps then key = caps.key .. "|" .. key end
	local hit = Nav.Cache[key]
	if hit and CurTime() - hit.t < CACHE_TIME then
		st.cached = st.cached + 1
		callback(hit.path)
		return true
	end

	local waiter = { cb = callback, wanted = wanted }
	local waiting = Nav.Pending[key]
	if waiting then
		waiting[#waiting + 1] = waiter
		return true
	end

	if #searches >= cvMaxQueue:GetInt() then
		st.rejected = st.rejected + 1
		callback(nil)
		return true
	end

	Nav.Pending[key] = { waiter }
	searches[#searches + 1] = {
		key = key,
		co = coroutine.create(function() return search(s, t, width, caps) end),
	}
	return true
end

-- True while at least one waiter of this search still wants the result.
local function stillWanted(key)
	local ws = Nav.Pending[key]
	if not ws then return false end
	for i = 1, #ws do
		local f = ws[i].wanted
		if not f or f() then return true end
	end
	return false
end

hook.Add("Tick", "NGL.Nav", function()
	-- Map generation, if running.
	if genRoutine then
		local ok, err = coroutine.resume(genRoutine)
		if not ok then
			print("[NGL] Nav generation failed: " .. tostring(err))
			genRoutine = nil
		elseif coroutine.status(genRoutine) == "dead" then
			genRoutine = nil
		end
	end

	if #searches == 0 then return end
	local start = SysTime()
	local budget = cvBudget:GetFloat() / 1000

	local st = Nav.Stats
	local checked = nil
	while #searches > 0 and SysTime() - start < budget do
		local job = searches[1]
		if checked ~= job and not stillWanted(job.key) then
			-- Everyone who asked gave up (timed out, died, changed target).
			table.remove(searches, 1)
			Nav.Pending[job.key] = nil
			st.dropped = st.dropped + 1
		else
			checked = job
			local ok, res = coroutine.resume(job.co)
			if not ok or coroutine.status(job.co) == "dead" then
				table.remove(searches, 1)
				local path = ok and res or nil
				if not ok then print("[NGL] Path search error: " .. tostring(res)) end
				if path then st.ok = st.ok + 1 else st.fail = st.fail + 1 end
				Nav.Cache[job.key] = { path = path, t = CurTime() }
				local ws = Nav.Pending[job.key]
				Nav.Pending[job.key] = nil
				if ws then
					for i = 1, #ws do ws[i].cb(path) end
				end
			end
		end
	end

	local B = NGL.Bench
	if B then B.LuaTime = B.LuaTime + (SysTime() - start) end
end)

-- Drop stale cache entries now and then.
timer.Create("NGL.Nav.CacheGC", 10, 0, function()
	local now = CurTime()
	for k, v in pairs(Nav.Cache) do
		if now - v.t > CACHE_TIME then Nav.Cache[k] = nil end
	end
end)

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

local function allowed(ply) return not IsValid(ply) or ply:IsSuperAdmin() end
local function tell(ply, msg)
	msg = "[NGL] " .. msg
	print(msg)
	if IsValid(ply) and not game.SinglePlayer() and not ply:IsListenServerHost() then
		ply:PrintMessage(HUD_PRINTTALK, msg)
	end
end

function Nav.Generate(ply)
	if genRoutine then tell(ply, "Generation is already running.") return false end
	tell(ply, string.format("Generating nav grid for %s at %d-unit spacing...", game.GetMap(), cvSpacing:GetInt()))
	genRoutine = coroutine.create(function() generate(function(m) tell(ply, m) end) end)
	return true
end
function Nav.Generating() return genRoutine ~= nil end

concommand.Add("ngl_nav_generate", function(ply)
	if not allowed(ply) then return end
	Nav.Generate(ply)
end)

concommand.Add("ngl_nav_info", function(ply)
	if not allowed(ply) then return end
	if genRoutine then tell(ply, "Generation is running.") return end
	if not Nav.Loaded then tell(ply, "No nav grid for this map. Run ngl_nav_generate.") return end
	local st = Nav.Stats
	tell(ply, string.format("Nav loaded: %d points, %d jump links, %d edits, %d-unit spacing. Searches: %d queued, %d cached. Since start: %d found, %d failed, %d served from cache, %d dropped, %d rejected (queue full)",
		Nav.Count, #Nav.Links, Nav.Edits and #Nav.Edits or 0, Nav.S, #searches, table.Count(Nav.Cache), st.ok, st.fail, st.cached, st.dropped, st.rejected))
end)

-- Draws the grid around the caller for 15 s. debugoverlay only shows on a
-- listen server / singleplayer with `developer 1`.
concommand.Add("ngl_nav_draw", function(ply, _, args)
	if not allowed(ply) or not IsValid(ply) or not Nav.Loaded then return end
	local radius = tonumber(args[1] or "") or 1000
	local p = ply:GetPos()
	local S = Nav.S
	local r = math.ceil(radius / S)
	local cx, cy = floor(p.x / S + 0.5), floor(p.y / S + 0.5)
	local up = Vector(0, 0, 4)
	for x = cx - r, cx + r do
		for y = cy - r, cy + r do
			local c = Nav.Cells[cellKey(x, y)]
			if c then
				for _, i in ipairs(c) do
					local a = nodePos(i) + up
					local nb = Nav.NB[i]
					for k = 1, #nb, 2 do
						if nb[k] > i then
							debugoverlay.Line(a, nodePos(nb[k]) + up, 15, Color(0, 200, 255), true)
						end
					end
				end
			end
		end
	end
	tell(ply, "Drawing nav for 15 s (needs a listen server and developer 1).")
end)

concommand.Add("ngl_nav_reload", function(ply)
	if not allowed(ply) then return end
	tell(ply, Nav.Load() and ("Loaded " .. Nav.Count .. " points.") or "No nav file for this map.")
end)

-- Load this map's grid as soon as we can; with none, make one (ngl_nav_auto):
-- right after the map loads if it has spawn points, otherwise when the first
-- player spawns (generation starts from where players can stand).
local function autoGenerate()
	if Nav.Loaded or genRoutine or not cvAuto:GetBool() then return end
	if #seedPositions() == 0 then return end
	print("[NGL] No nav grid for this map: generating one (ngl_nav_auto 0 turns this off).")
	Nav.Generate(nil)
end

if Nav.Load() then
	print(string.format("[NGL] Nav grid loaded: %d points.", Nav.Count))
end
hook.Add("InitPostEntity", "NGL.Nav.Load", function()
	if not Nav.Loaded and Nav.Load() then
		print(string.format("[NGL] Nav grid loaded: %d points.", Nav.Count))
	end
	-- No generated grid and not making one: whatever was added by hand.
	if not Nav.Loaded and not cvAuto:GetBool() and Nav.ApplyEdits then Nav.ApplyEdits() end
	timer.Simple(3, autoGenerate)
end)
hook.Add("PlayerSpawn", "NGL.Nav.Auto", function()
	if Nav.Loaded or genRoutine then return end
	timer.Simple(1, autoGenerate)
end)
