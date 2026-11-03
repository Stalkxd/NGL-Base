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
-- generator walks through doors (NPCs open or kick them), follows narrow
-- halls and doorways (a point that doesn't fit at its spot in the grid is
-- moved within its square to where a person fits), and only links points a
-- person can really walk between: a ledge too high to step up is a jump
-- link, not a walk. NPCs jump up small ledges (ENT.JumpUp) and down small
-- drops (ENT.JumpDown). Players can fix the grid in game with the NGL Nav
-- Editor tool (sv_nav_edit.lua): add or remove walkable area, place jump and
-- climb links. Edits are kept apart from the generated grid
-- (data/ngl_nav/<map>_edits.txt), so they survive regenerating it.
--
-- Where four points round a square are all linked (both ways and across),
-- the square is open floor: paths cut straight across such squares instead of
-- following the grid lines, and the editor draws them filled.

NGL.Nav = NGL.Nav or {}
local Nav = NGL.Nav

local floor, sqrt, abs, huge = math.floor, math.sqrt, math.abs, math.huge
local SysTime, CurTime = SysTime, CurTime

local cvSpacing = CreateConVar("ngl_nav_spacing", "64", FCVAR_ARCHIVE, "Grid spacing used by ngl_nav_generate (units). Smaller: tighter places, more points.", 32, 256)
local cvMaxNodes = CreateConVar("ngl_nav_max_nodes", "300000", FCVAR_ARCHIVE, "Stop ngl_nav_generate after this many grid points.", 1000, 1000000)
local cvGenBudget = CreateConVar("ngl_nav_gen_budget", "20", FCVAR_ARCHIVE, "Milliseconds per tick ngl_nav_generate may use.", 1, 500)
local cvBudget = CreateConVar("ngl_nav_budget", "2", FCVAR_ARCHIVE, "Milliseconds per tick for NPC path-finding.", 0.1, 50)
local cvMaxExpand = CreateConVar("ngl_nav_max_expand", "16000", FCVAR_ARCHIVE, "Give up a path search after expanding this many grid points.", 100, 1000000)
local cvMaxQueue = CreateConVar("ngl_nav_max_queue", "64", FCVAR_ARCHIVE, "Path requests beyond this many queued searches fail at once (the NPC walks straight).", 1, 10000)
local cvFastOpen = CreateConVar("ngl_nav_fast_open", "1", FCVAR_ARCHIVE, "ngl_nav_generate: skip most traces on flat open ground (one box check per point instead of a hull and ground checks per link).", 0, 1)
local cvAuto = CreateConVar("ngl_nav_auto", "1", FCVAR_ARCHIVE, "Generate the NGL nav grid on its own when a map has none (0 = only with ngl_nav_generate).", 0, 1)
local cvDrops = CreateConVar("ngl_nav_drops", "1", FCVAR_ARCHIVE, "ngl_nav_generate links ledges up and down, so NPCs can jump onto and off them.", 0, 1)
local cvMaxDrop = CreateConVar("ngl_nav_max_drop", "250", FCVAR_ARCHIVE, "Highest ledge (units) ngl_nav_generate links to the ground below.", 32, 4000)
local cvMaxUp = CreateConVar("ngl_nav_max_up", "72", FCVAR_ARCHIVE, "Highest ledge (units) ngl_nav_generate links for jumping up onto.", 0, 256)

-- Hull the generator checks against: a standing NPC above step height
-- (HL2's person hull, 26 wide).
local STEP = 18
local HULL_MINS = Vector(-13, -13, 0)
local HULL_MAXS = Vector(13, 13, 72 - STEP)
local MIN_NORMAL_Z = 0.7 -- steeper than ~45 degrees is not walkable
local SAMPLE = 24        -- ground checked this often along a walk link

local DIRS = {
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 },
}
local OPP = { 2, 1, 4, 3, 6, 5, 8, 7 }
local DIR_COST = { 1, 1, 1, 1, 1.4142, 1.4142, 1.4142, 1.4142 }

----------------------------------------------------------------------------
-- Storage
----------------------------------------------------------------------------
-- Node i: grid coords NX[i], NY[i], height NZ[i], edge bitmask NM[i], and
-- where it sits in its square: OX[i], OY[i] units off the grid spot (0 in
-- the open; narrow halls and doorways move points to where a person fits).
-- Neighbours are resolved after load into NB[i] = { j1, c1, j2, c2, ... };
-- SQ[i] is true when the square with i at its low corner is open floor.

local function cellKey(ix, iy)
	return (ix + 32768) * 65536 + (iy + 32768)
end

local searches = {}   -- running path searches (coroutines), oldest first
Nav.Stats = Nav.Stats or { ok = 0, fail = 0, dropped = 0, rejected = 0, cached = 0 }

local function reset()
	Nav.S = cvSpacing:GetInt()
	Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.NB = {}, {}, {}, {}, {}
	Nav.OX, Nav.OY, Nav.SQ = {}, {}, {}
	Nav.Cells = {}
	Nav.Count = 0
	Nav.Dead = {}  -- removed by an edit, until the next compact()
	-- One-way links: { a = node, b = node, kind, h }. kind: "drop" (jump down),
	-- "up" (jump up onto a ledge), "vault" (jump over something in the way,
	-- h = minus how high), "jump" (across a gap), "climb", or "walk" (joined
	-- by hand with the editor). h: how far a is above b.
	Nav.Links = {}
	Nav.LB = {}    -- [node] = { link index, ... } leaving it
	Nav.Loaded = false
	Nav.Cache = {}
	Nav.Pending = {}
	Nav.Wide = {} -- [half width] = { [node] = true/false }, filled lazily by wide searches
	Nav.IslandWalk, Nav.IslandAny = nil, nil
	Nav.Fields = {}
	-- Searches over the old grid are meaningless now. Their callers time out
	-- on their own (see chase in sv_core.lua).
	for k in pairs(searches) do searches[k] = nil end
end

if not Nav.NX then reset() end

local function addNode(ix, iy, z, ox, oy)
	local n = Nav.Count + 1
	Nav.Count = n
	Nav.NX[n], Nav.NY[n], Nav.NZ[n], Nav.NM[n] = ix, iy, z, 0
	Nav.OX[n], Nav.OY[n] = ox or 0, oy or 0
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
	return Vector(Nav.NX[i] * S + Nav.OX[i], Nav.NY[i] * S + Nav.OY[i], Nav.NZ[i])
end
Nav.NodePos = nodePos

-- Height tolerance for finding the neighbour a walk link goes to (steep
-- ramps rise up to about a square's width).
local function linkTol() return Nav.S * 1.05 + 16 end

local function buildNeighbours(saved)
	local S = Nav.S
	local tol = linkTol()
	local NX, NY, NZ, NM, OX, OY = Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.OX, Nav.OY
	local byDir = {}
	for i = 1, Nav.Count do
		local nb, bd = {}, {}
		local m, ix, iy, z = NM[i], NX[i], NY[i], NZ[i]
		for d = 1, 8 do
			if bit.band(m, bit.lshift(1, d - 1)) ~= 0 then
				local j = nodeAt(ix + DIRS[d][1], iy + DIRS[d][2], z, tol)
				if j then
					nb[#nb + 1] = j
					nb[#nb + 1] = DIR_COST[d]
					bd[d] = j
				end
			end
		end
		Nav.NB[i] = nb
		byDir[i] = bd
	end
	-- Open areas: every triangle of three points all linked to each other
	-- (two sides of a grid square and a diagonal). Two triangles make a
	-- square. Each is listed in every grid square its corners reach into.
	local TA, TB, TC, TCells, TOwner = {}, {}, {}, {}, {}
	local SQ, InTri = {}, {}
	local nt = 0
	local owner
	local function addTri(a, b, c)
		nt = nt + 1
		TA[nt], TB[nt], TC[nt], TOwner[nt] = a, b, c, owner
		InTri[a], InTri[b], InTri[c] = true, true, true
		local xa, xb, xc = NX[a] * S + OX[a], NX[b] * S + OX[b], NX[c] * S + OX[c]
		local ya, yb, yc = NY[a] * S + OY[a], NY[b] * S + OY[b], NY[c] * S + OY[c]
		for cx = floor(math.min(xa, xb, xc) / S), floor(math.max(xa, xb, xc) / S) do
			for cy = floor(math.min(ya, yb, yc) / S), floor(math.max(ya, yb, yc) / S) do
				local k = cellKey(cx, cy)
				local list = TCells[k]
				if not list then list = {}; TCells[k] = list end
				list[#list + 1] = nt
			end
		end
	end
	for i = 1, Nav.Count do
		owner = i
		local bd = byDir[i]
		local e, n, ne = bd[1], bd[3], bd[5]
		local t1 = e and ne and byDir[e][3] == ne            -- i, e, ne
		local t2 = n and ne and byDir[n][1] == ne            -- i, ne, n
		local t3 = e and n and byDir[e][8] == n              -- i, e, n
		local ne2 = e and byDir[e][3]
		local t4 = t3 and ne2 and byDir[n][1] == ne2         -- e, ne, n
		if t1 then addTri(i, e, ne) end
		if t2 then addTri(i, ne, n) end
		if t3 then addTri(i, e, n) end
		if t4 then addTri(e, ne2, n) end
		if (t1 and t2) or (t3 and t4) then SQ[i] = true end -- a whole square
	end
	Nav.TA, Nav.TB, Nav.TC, Nav.TCells, Nav.TriCount, Nav.TOwner = TA, TB, TC, TCells, nt, TOwner
	Nav.SQ, Nav.InTri = SQ, InTri
	-- Areas as saved (Nav.Load), or built again.
	if saved then
		Nav.Areas, Nav.AreaOf, Nav.AreaEdges = saved.Areas, saved.AreaOf, nil
	else
		Nav.BuildAreas(byDir)
	end
	Nav.IslandWalk, Nav.IslandAny = nil, nil
	Nav.Version = (Nav.Version or 0) + 1 -- what the editor view was sent from has changed
end

----------------------------------------------------------------------------
-- Areas: the grid merged into rectangles, like the Source navmesh's areas.
-- A rectangle is a block of grid points, each on its own grid spot, where
-- every square inside is open floor (all four sides and a diagonal walkable),
-- so anywhere inside it can be walked to in a straight line. Points that
-- don't fit in one (narrow halls, doorways, ledges) are areas of their own.
-- Paths are searched over areas (far fewer than points) and drawn straight
-- through them (see areaSearch).
--   Areas[a] = { x0, y0, x1, y1 (grid coords), n (corner node), big }
--   AreaOf[node] = a
----------------------------------------------------------------------------

local AREA_MAX = 16 -- grid squares a side, at most

-- The square with grid corners a (low x, low y), b (+x), c (+y), d (+x +y):
-- all four sides walkable and open floor.
local function squareWhole(byDir, a, b, c, d)
	local bd = byDir[a]
	return bd and bd[1] == b and bd[3] == c and byDir[b] and byDir[b][3] == d
		and byDir[c] and byDir[c][1] == d and Nav.SQ[a] or false
end

local function sortNodes(order)
	local NX, NY, NZ = Nav.NX, Nav.NY, Nav.NZ
	table.sort(order, function(a, b)
		if NY[a] ~= NY[b] then return NY[a] < NY[b] end
		if NX[a] ~= NX[b] then return NX[a] < NX[b] end
		return NZ[a] < NZ[b]
	end)
end

-- Merges the points in `order` (sorted, see sortNodes) that have no area yet
-- in AreaOf into new areas, numbered by alloc(); returns their numbers.
local buildAreasOver
function Nav.BuildAreas(byDir)
	local order, dead = {}, Nav.Dead
	for i = 1, Nav.Count do if not dead[i] then order[#order + 1] = i end end
	sortNodes(order)
	local Areas, AreaOf = {}, {}
	buildAreasOver(order, byDir, Areas, AreaOf, function() return #Areas + 1 end)
	Nav.Areas, Nav.AreaOf, Nav.AreaEdges = Areas, AreaOf, nil
end

buildAreasOver = function(order, byDir, Areas, AreaOf, alloc)
	local NX, NY, NZ, OX, OY = Nav.NX, Nav.NY, Nav.NZ, Nav.OX, Nav.OY
	local made = {}
	local function free(i) return i and not AreaOf[i] and OX[i] == 0 and OY[i] == 0 end
	for _, i in ipairs(order) do
		if not AreaOf[i] then
			local rows, w = nil, 0
			if free(i) then
				-- First row: as far +x as the points go.
				local row, cur = { i }, i
				while #row < AREA_MAX do
					local e = byDir[cur][1]
					if not free(e) then break end
					row[#row + 1] = e
					cur = e
				end
				rows, w = { row }, #row
				-- Then rows above while every square between is open floor;
				-- narrower if that makes a bigger rectangle.
				while #rows < AREA_MAX and w >= 2 do
					local prev, nxt = rows[#rows], {}
					local ok = 0
					for k = 1, w do
						local n = byDir[prev[k]][3]
						if not free(n) then break end
						if k > 1 and not squareWhole(byDir, prev[k - 1], prev[k], nxt[k - 1], n) then break end
						nxt[k] = n
						ok = k
					end
					if ok >= 2 and ok * (#rows + 1) > w * #rows then
						if ok < w then
							for _, r in ipairs(rows) do for k = ok + 1, w do r[k] = nil end end
							w = ok
						end
						for k = w + 1, #nxt do nxt[k] = nil end
						rows[#rows + 1] = nxt
					else
						break
					end
				end
			end
			if rows and w >= 2 and #rows >= 2 then
				local a = alloc()
				made[#made + 1] = a
				for _, r in ipairs(rows) do for _, n in ipairs(r) do AreaOf[n] = a end end
				local top = rows[#rows]
				Areas[a] = { x0 = NX[i], y0 = NY[i], x1 = NX[i] + w - 1, y1 = NY[i] + #rows - 1, big = true,
					c00 = i, c10 = rows[1][w], c01 = top[1], c11 = top[w] }
			end
		end
	end
	-- Narrow places: straight runs of points along a hall (all moved the
	-- same way off their grid spots, linked one to the next) become thin
	-- rectangles. Walking along one is a straight line.
	local function run(i, dir)
		local list, cur = { i }, i
		local ox, oy = OX[i], OY[i]
		while #list < AREA_MAX do
			local n = byDir[cur][dir]
			if not (n and not AreaOf[n] and OX[n] == ox and OY[n] == oy) then break end
			-- linked both ways
			if byDir[n][OPP[dir]] ~= cur then break end
			list[#list + 1] = n
			cur = n
		end
		return list
	end
	for _, i in ipairs(order) do
		if not AreaOf[i] then
			local a = alloc()
			made[#made + 1] = a
			local h, v = run(i, 1), run(i, 3)
			local strip = #h >= #v and h or v
			if #strip >= 2 then
				for _, n in ipairs(strip) do AreaOf[n] = a end
				local last = strip[#strip]
				if strip == h then
					Areas[a] = { x0 = NX[i], y0 = NY[i], x1 = NX[last], y1 = NY[i], big = false, strip = true,
						c00 = i, c10 = last, c01 = i, c11 = last }
				else
					Areas[a] = { x0 = NX[i], y0 = NY[i], x1 = NX[i], y1 = NY[last], big = false, strip = true,
						c00 = i, c10 = i, c01 = last, c11 = last }
				end
			else
				AreaOf[i] = a
				Areas[a] = { x0 = NX[i], y0 = NY[i], x1 = NX[i], y1 = NY[i], big = false, c00 = i, c10 = i, c01 = i, c11 = i }
			end
		end
	end
	-- How far each area reaches round its points, for drawing it as a
	-- square like the Source navmesh: half way to the next point where
	-- there is one on every point of that side, else a person's half width
	-- (a wall or a ledge there).
	local S = Nav.S
	local HALF = 16
	local function side(A, dir)
		local nodes = {}
		local function at(c) nodes[#nodes + 1] = c end
		-- the points along that side, walking from one corner to the other
		-- +x side: up the x1 column from c10; -x: up the x0 column from c00;
		-- +y side: along the y1 row from c01; -y: along the y0 row from c00
		local from = (dir == 1 and A.c10) or (dir == 3 and A.c01) or A.c00
		local step = (dir == 1 or dir == 2) and 3 or 1
		at(from)
		local cur, guard = from, 0
		local stopAt = (dir == 1 and A.c11) or (dir == 2 and A.c01) or (dir == 3 and A.c11) or A.c10
		while cur ~= stopAt and guard < AREA_MAX do
			cur = byDir[cur][step]
			if not cur then break end
			at(cur)
			guard = guard + 1
		end
		for _, n in ipairs(nodes) do
			local o = byDir[n][dir]
			if not o or byDir[o][OPP[dir]] ~= n then return HALF end
		end
		return S * 0.5
	end
	for _, a in ipairs(made) do
		local A = Areas[a]
		local p00, p11 = nodePos(A.c00), nodePos(A.c11)
		A.ex0, A.ex1 = p00.x - side(A, 2), p11.x + side(A, 1)
		A.ey0, A.ey1 = p00.y - side(A, 4), p11.y + side(A, 3)
	end
	return made
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
	Nav.AreaEdges = nil -- rebuilt on the next search
	Nav.IslandWalk, Nav.IslandAny = nil, nil
end
Nav.BuildLinks = buildLinks

-- Rebuilds the grid round one spot after an edit there (points added or
-- removed within r of p), instead of the whole map: the neighbour lists,
-- open triangles and areas of the points within r (plus two squares) of p.
-- Removed points stay in the arrays, marked dead, until the grid is next
-- loaded or made. Area numbers elsewhere don't change, except the last few,
-- moved into freed numbers. Area edges, regions and islands are made again
-- on the next search (one pass each, no sorting).
function Nav.RebuildAround(p, r)
	if not (Nav.Areas and Nav.AreaOf and Nav.TCells) then return false end
	local S = Nav.S
	local tol = linkTol()
	local NX, NY, NZ, NM, NB, dead = Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.NB, Nav.Dead
	local Cells = Nav.Cells
	local cr = math.ceil(r / S) + 2
	local cx, cy = floor(p.x / S + 0.5), floor(p.y / S + 0.5)
	local T, list = {}, {}
	for x = cx - cr, cx + cr do
		for y = cy - cr, cy + cr do
			local c = Cells[cellKey(x, y)]
			if c then for k = 1, #c do local i = c[k]; T[i] = true; list[#list + 1] = i end end
		end
	end
	-- Each point's neighbour in each direction, worked out when first asked.
	local byDir = setmetatable({}, { __index = function(t, i)
		local bd = {}
		if not dead[i] then
			local m, ix, iy, z = NM[i], NX[i], NY[i], NZ[i]
			for d = 1, 8 do
				if bit.band(m, bit.lshift(1, d - 1)) ~= 0 then
					local j = nodeAt(ix + DIRS[d][1], iy + DIRS[d][2], z, tol)
					if j then bd[d] = j end
				end
			end
		end
		t[i] = bd
		return bd
	end })
	-- Neighbour lists.
	for _, i in ipairs(list) do
		local nb = {}
		if not dead[i] then
			local bd = byDir[i]
			for d = 1, 8 do
				local j = bd[d]
				if j then nb[#nb + 1] = j; nb[#nb + 1] = DIR_COST[d] end
			end
		end
		NB[i] = nb
	end
	-- Open triangles: the ones of these points out, new ones in.
	local TA, TB, TC, TCells, TOwner, SQ, InTri = Nav.TA, Nav.TB, Nav.TC, Nav.TCells, Nav.TOwner, Nav.SQ, Nav.InTri
	for x = cx - cr - 1, cx + cr + 1 do
		for y = cy - cr - 1, cy + cr + 1 do
			local key = cellKey(x, y)
			local l = TCells[key]
			if l then
				local keep = {}
				for m = 1, #l do if not T[TOwner[l[m]]] then keep[#keep + 1] = l[m] end end
				TCells[key] = #keep > 0 and keep or nil
			end
		end
	end
	local nt = Nav.TriCount
	local owner
	local function addTri(a, b, c)
		nt = nt + 1
		TA[nt], TB[nt], TC[nt], TOwner[nt] = a, b, c, owner
		local xa, xb, xc = NX[a] * S + Nav.OX[a], NX[b] * S + Nav.OX[b], NX[c] * S + Nav.OX[c]
		local ya, yb, yc = NY[a] * S + Nav.OY[a], NY[b] * S + Nav.OY[b], NY[c] * S + Nav.OY[c]
		for tx = floor(math.min(xa, xb, xc) / S), floor(math.max(xa, xb, xc) / S) do
			for ty = floor(math.min(ya, yb, yc) / S), floor(math.max(ya, yb, yc) / S) do
				local k = cellKey(tx, ty)
				local l = TCells[k]
				if not l then l = {}; TCells[k] = l end
				l[#l + 1] = nt
			end
		end
	end
	for _, i in ipairs(list) do
		SQ[i], InTri[i] = nil, nil
		if not dead[i] then
			owner = i
			local bd = byDir[i]
			local e, n, ne = bd[1], bd[3], bd[5]
			local t1 = e and ne and byDir[e][3] == ne
			local t2 = n and ne and byDir[n][1] == ne
			local t3 = e and n and byDir[e][8] == n
			local ne2 = e and byDir[e][3]
			local t4 = t3 and ne2 and byDir[n][1] == ne2
			if t1 then addTri(i, e, ne) end
			if t2 then addTri(i, ne, n) end
			if t3 then addTri(i, e, n) end
			if t4 then addTri(e, ne2, n) end
			if (t1 and t2) or (t3 and t4) then SQ[i] = true end
		end
	end
	Nav.TriCount = nt
	for x = cx - cr - 1, cx + cr + 1 do
		for y = cy - cr - 1, cy + cr + 1 do
			local l = TCells[cellKey(x, y)]
			if l then for m = 1, #l do local k = l[m]; InTri[TA[k]], InTri[TB[k]], InTri[TC[k]] = true, true, true end end
		end
	end
	-- Areas: every area with a point here is taken apart and its points,
	-- with the new ones, merged again.
	local Areas, AreaOf = Nav.Areas, Nav.AreaOf
	local rip, holes = {}, {}
	for _, i in ipairs(list) do
		local a = AreaOf[i]
		if a and not rip[a] then rip[a] = true; holes[#holes + 1] = a end
	end
	local redo, seen = {}, {}
	local function membersOf(a, fn)
		local A = Areas[a]
		for x = A.x0, A.x1 do
			for y = A.y0, A.y1 do
				local c = Cells[cellKey(x, y)]
				if c then for k = 1, #c do if AreaOf[c[k]] == a then fn(c[k]) end end end
			end
		end
	end
	for _, a in ipairs(holes) do
		membersOf(a, function(i) if not seen[i] then seen[i] = true; redo[#redo + 1] = i end end)
	end
	for _, i in ipairs(list) do if not seen[i] then seen[i] = true; redo[#redo + 1] = i end end
	for _, i in ipairs(redo) do AreaOf[i] = nil end
	for _, a in ipairs(holes) do Areas[a] = false end
	local order = {}
	for _, i in ipairs(redo) do if not dead[i] then order[#order + 1] = i end end
	sortNodes(order)
	table.sort(holes, function(a, b) return a > b end) -- lowest last: used first
	buildAreasOver(order, byDir, Areas, AreaOf, function()
		local h = table.remove(holes)
		return h or #Areas + 1
	end)
	-- Numbers left over: move the last areas into them.
	table.sort(holes, function(a, b) return a > b end)
	for _, h in ipairs(holes) do
		local last = #Areas
		if h < last then
			Areas[h] = Areas[last]
			Areas[last] = nil
			local A = Areas[h]
			for x = A.x0, A.x1 do
				for y = A.y0, A.y1 do
					local c = Cells[cellKey(x, y)]
					if c then for k = 1, #c do if AreaOf[c[k]] == last then AreaOf[c[k]] = h end end end
				end
			end
		elseif h == last then
			Areas[last] = nil
		end
	end
	Nav.AreaEdges = nil
	Nav.IslandWalk, Nav.IslandAny = nil, nil
	Nav.Version = (Nav.Version or 0) + 1
	return true
end

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
								local dx, dy = x * S + Nav.OX[i] - pos.x, y * S + Nav.OY[i] - pos.y
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

-- Open areas (triangles, see buildNeighbours) containing the point (x, y),
-- passed to fn(k) one by one; stops when fn returns true.
local TRI_EPS = 0.5
local function eachTriAt(x, y, fn)
	local list = Nav.TCells and Nav.TCells[cellKey(floor(x / Nav.S), floor(y / Nav.S))]
	if not list then return end
	local S, NX, NY, OX, OY = Nav.S, Nav.NX, Nav.NY, Nav.OX, Nav.OY
	local TA, TB, TC = Nav.TA, Nav.TB, Nav.TC
	for m = 1, #list do
		local k = list[m]
		local a, b, c = TA[k], TB[k], TC[k]
		local ax, ay = NX[a] * S + OX[a], NY[a] * S + OY[a]
		local bx, by = NX[b] * S + OX[b], NY[b] * S + OY[b]
		local cx, cy = NX[c] * S + OX[c], NY[c] * S + OY[c]
		local d1 = (bx - ax) * (y - ay) - (by - ay) * (x - ax)
		local d2 = (cx - bx) * (y - by) - (cy - by) * (x - bx)
		local d3 = (ax - cx) * (y - cy) - (ay - cy) * (x - cx)
		-- Inside (or on an edge, give or take TRI_EPS units).
		local e1 = TRI_EPS * math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
		local e2 = TRI_EPS * math.sqrt((cx - bx) ^ 2 + (cy - by) ^ 2)
		local e3 = TRI_EPS * math.sqrt((ax - cx) ^ 2 + (ay - cy) ^ 2)
		if (d1 >= -e1 and d2 >= -e2 and d3 >= -e3) or (d1 <= e1 and d2 <= e2 and d3 <= e3) then
			if fn(k) then return end
		end
	end
end
Nav.EachTriAt = eachTriAt

local function sharesCorner(k, m)
	local TA, TB, TC = Nav.TA, Nav.TB, Nav.TC
	local a, b, c = TA[m], TB[m], TC[m]
	local p, q, r = TA[k], TB[k], TC[k]
	return p == a or p == b or p == c or q == a or q == b or q == c or r == a or r == b or r == c
end

local function hasCorner(k, node)
	return Nav.TA[k] == node or Nav.TB[k] == node or Nav.TC[k] == node
end

-- True when the straight line from a to b stays on open areas, one floor
-- all the way: each open triangle it crosses into shares a corner with the
-- last (so not up or down a ledge between two separate floors), so an NPC
-- can walk it without following the grid lines. Table lookups only.
-- `from` (optional): the grid point a is on, to start on the right floor.
function Nav.OpenLine(a, b, from)
	if not Nav.Loaded or not Nav.TCells then return false end
	local S = Nav.S
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local len = sqrt(dx * dx + dy * dy)
	local n = math.max(1, math.ceil(len / (S / 6)))
	local prev
	for k = 0, n do
		local f = k / n
		local x, y, z = a.x + dx * f, a.y + dy * f, a.z + dz * f
		local found
		if prev then
			eachTriAt(x, y, function(t)
				if t == prev then found = t return true end
				if not found and sharesCorner(t, prev) then found = t end
			end)
		else
			eachTriAt(x, y, function(t)
				if from then
					if hasCorner(t, from) then found = t return true end
				elseif abs(Nav.NZ[Nav.TA[t]] - z) < 48 then
					found = t
					return true
				end
			end)
		end
		if not found then return false end
		prev = found
	end
	return true
end

local function linked(i, j)
	if i == j then return true end
	local nb = Nav.NB[i]
	for k = 1, #nb, 2 do
		if nb[k] == j then return true end
	end
	return false
end

-- Can an NPC walk straight from a to b? Checked on the grid, no traces: the
-- line has to go from grid point to linked grid point all the way (so not
-- over a ledge, into a wall or off the grid). nil when a isn't on the grid
-- at all (nothing to go by).
function Nav.WalkLine(a, b)
	if not Nav.Loaded then return nil end
	local S = Nav.S
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local len = sqrt(dx * dx + dy * dy)
	local n = math.max(1, math.ceil(len / (S * 0.5)))
	local tol = linkTol()
	local prev = Nav.Nearest(a)
	if not prev then return nil end
	local NZ = Nav.NZ
	for k = 1, n do
		local f = k / n
		local u, v = (a.x + dx * f) / S, (a.y + dy * f) / S
		-- The point in that square nearest the height we're walking at.
		local cur = nodeAt(floor(u + 0.5), floor(v + 0.5), NZ[prev], tol)
		if not cur or not linked(prev, cur) then return false end
		prev = cur
	end
	return true
end

-- A short stroll along the grid for idle NPCs: walk up to `cells` points in
-- a random direction, turning (at most twice) at walls or where the walk
-- would leave `radius` around `home`. Costs a few table reads, no search.
-- Returns a list of waypoints, or nil off the grid.
function Nav.RandomWalk(pos, home, radius, cells)
	local cur = Nav.Nearest(pos)
	if not cur then return nil end
	local NX, NY, NB, S = Nav.NX, Nav.NY, Nav.NB, Nav.S
	cells = math.ceil(cells * 96 / S) -- `cells` counts 96-unit steps, whatever the spacing
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
local KIND_CODE, CODE_KIND = { drop = 1, jump = 2, up = 3, climb = 4, walk = 5, vault = 6 },
	{ "drop", "jump", "up", "climb", "walk", "vault" }
Nav.KindCode, Nav.CodeKind = KIND_CODE, CODE_KIND
local FORMAT = 5 -- 5: binary with areas; 4: text (still loads); older grids are made again

-- Binary format (FORMAT 5): a text header line "NGLNAVB<format> <spacing>
-- <points> <links> <areas>", then fixed-size records, all compressed:
--   point: grid x, y (2 bytes each), height x8 (4), links bitmask (1),
--          offset x, y (1 each)                                  11 bytes
--   link:  a, b (4 each), kind (1), height x8 (4)                 13 bytes
--   area:  x0, y0, x1, y1 (2 each), flags (1: big, 2: strip),
--          c00, c10, c01, c11 (4 each), ex0, ex1, ey0, ey1 x8 (4 each) 41 bytes
--   then the area of every point (4 each, 0: none)
-- Loading reads the numbers straight back (no text to parse) and keeps the
-- saved areas instead of building them again. Older text grids (FORMAT 4)
-- still load.
local char, byte = string.char, string.byte
local function u16(v) v = floor(v) % 65536; return char(floor(v / 256), v % 256) end
local function u32(v)
	v = floor(v) % 4294967296
	return char(floor(v / 16777216) % 256, floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
end
local function i16(v) return u16(v + 32768) end
local function i32(v) return u32(floor(v + 0.5) + 2147483648) end
local function i8(v) return char((floor(v) + 128) % 256) end
local function r16(s, p) local a, b = byte(s, p, p + 1); return a * 256 + b end
local function r32(s, p) local a, b, c, d = byte(s, p, p + 3); return ((a * 256 + b) * 256 + c) * 256 + d end

function Nav.Save()
	local n, Links, Areas, AreaOf = Nav.Count, Nav.Links, Nav.Areas or {}, Nav.AreaOf or {}
	local parts = { string.format("NGLNAVB%d %d %d %d %d\n", FORMAT, Nav.S, n, #Links, #Areas) }
	local NX, NY, NZ, NM, OX, OY = Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.OX, Nav.OY
	for i = 1, n do
		parts[#parts + 1] = i16(NX[i]) .. i16(NY[i]) .. i32(NZ[i] * 8) .. char(NM[i] % 256) .. i8(OX[i]) .. i8(OY[i])
	end
	for _, L in ipairs(Links) do
		parts[#parts + 1] = u32(L.a) .. u32(L.b) .. char(KIND_CODE[L.kind] or 1) .. i32((L.h or 0) * 8)
	end
	for _, A in ipairs(Areas) do
		parts[#parts + 1] = i16(A.x0) .. i16(A.y0) .. i16(A.x1) .. i16(A.y1)
			.. char((A.big and 1 or 0) + (A.strip and 2 or 0))
			.. u32(A.c00) .. u32(A.c10) .. u32(A.c01) .. u32(A.c11)
			.. i32(A.ex0 * 8) .. i32(A.ex1 * 8) .. i32(A.ey0 * 8) .. i32(A.ey1 * 8)
	end
	if #Areas > 0 then
		for i = 1, n do parts[#parts + 1] = u32(AreaOf[i] or 0) end
	end
	file.CreateDir("ngl_nav")
	file.Write(navPath(), util.Compress(table.concat(parts)))
end

-- The binary grid in `data` (after its header line). Returns the saved
-- areas (or nil when there are none or they don't fit the points).
local function loadBinary(data, n, nl, na)
	local NX, NY, NZ, NM, OX, OY, Cells = Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.OX, Nav.OY, Nav.Cells
	if #data < n * 11 + nl * 13 + na * 41 + (na > 0 and n * 4 or 0) then return nil, false end
	local p = 1
	for i = 1, n do
		local x1, x2, y1, y2, z1, z2, z3, z4, m, ox, oy = byte(data, p, p + 10)
		local ix, iy = x1 * 256 + x2 - 32768, y1 * 256 + y2 - 32768
		NX[i], NY[i] = ix, iy
		NZ[i] = (((z1 * 256 + z2) * 256 + z3) * 256 + z4 - 2147483648) / 8
		NM[i], OX[i], OY[i] = m, ox - 128, oy - 128
		local k = cellKey(ix, iy)
		local c = Cells[k]
		if not c then c = {}; Cells[k] = c end
		c[#c + 1] = i
		p = p + 11
	end
	Nav.Count = n
	local Links = Nav.Links
	for _ = 1, nl do
		local a, b = r32(data, p), r32(data, p + 4)
		local k = byte(data, p + 8)
		local h = (r32(data, p + 9) - 2147483648) / 8
		if a >= 1 and a <= n and b >= 1 and b <= n then
			Links[#Links + 1] = { a = a, b = b, kind = CODE_KIND[k] or "drop", h = h }
		end
		p = p + 13
	end
	if na == 0 then return nil, true end
	local Areas = {}
	local function s16(q) return r16(data, q) - 32768 end
	local function s32(q) return (r32(data, q) - 2147483648) / 8 end
	for a = 1, na do
		local f = byte(data, p + 8)
		local A = { x0 = s16(p), y0 = s16(p + 2), x1 = s16(p + 4), y1 = s16(p + 6),
			big = f % 2 == 1, strip = f >= 2 or nil,
			c00 = r32(data, p + 9), c10 = r32(data, p + 13), c01 = r32(data, p + 17), c11 = r32(data, p + 21),
			ex0 = s32(p + 25), ex1 = s32(p + 29), ey0 = s32(p + 33), ey1 = s32(p + 37) }
		if A.c00 < 1 or A.c00 > n or A.c11 < 1 or A.c11 > n or A.c10 > n or A.c01 > n then return nil, true end
		Areas[a] = A
		p = p + 41
	end
	local AreaOf = {}
	for i = 1, n do
		local a = r32(data, p)
		if a > na then return nil, true end
		if a > 0 then AreaOf[i] = a end
		p = p + 4
	end
	return { Areas = Areas, AreaOf = AreaOf }, true
end

-- Loads the generated grid, then puts the edits back on (Nav.ApplyEdits).
function Nav.Load()
	local raw = file.Read(navPath(), "DATA")
	if not raw then return false end
	local text = util.Decompress(raw)
	if not text then return false end

	local nl = text:find("\n", 1, true)
	local header = nl and text:sub(1, nl - 1) or text
	local bver, bS, bn, blinks, bareas = header:match("^NGLNAVB(%d+) (%d+) (%d+) (%d+) (%d+)$")
	if bver then
		reset()
		Nav.S = tonumber(bS)
		local saved, ok = loadBinary(text:sub(nl + 1), tonumber(bn), tonumber(blinks), tonumber(bareas))
		if not ok then
			reset()
			return false
		end
		buildNeighbours(saved)
		buildLinks()
		Nav.Loaded = Nav.Count > 0
		if Nav.ApplyEdits then Nav.ApplyEdits() end
		return Nav.Loaded
	end

	local header2, rest = text:match("^([^\n]*)\n?(.*)$")
	local ver, S = nil, nil
	if header2 then ver, S = header2:match("^NGLNAV(%d+) (%d+)") end
	ver, S = tonumber(ver), tonumber(S)
	if not S then return false end
	if ver < 4 then
		print("[NGL] This map's nav grid is from an older version: making a new one (your edits are kept).")
		return false
	end

	reset()
	Nav.S = S
	local nodes, links = rest, nil
	local cut = rest:find("LINKS", 1, true)
	if cut then nodes, links = rest:sub(1, cut - 1), rest:sub(cut + 5) end
	for ix, iy, z, m, ox, oy in nodes:gmatch("(-?%d+) (-?%d+) (-?[%d%.]+) (%d+) (-?%d+) (-?%d+)") do
		local i = addNode(tonumber(ix), tonumber(iy), tonumber(z), tonumber(ox), tonumber(oy))
		Nav.NM[i] = tonumber(m)
	end
	if links then
		local n = Nav.Count
		for a, b, k, h in links:gmatch("(%d+) (%d+) (%d+) (-?[%d%.]+)") do
			a, b = tonumber(a), tonumber(b)
			if a <= n and b <= n then Nav.Links[#Nav.Links + 1] = { a = a, b = b, kind = CODE_KIND[tonumber(k)] or "drop", h = tonumber(h) } end
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

local function hullClear(ax, ay, az, bx, by, bz)
	hullTrace.start = Vector(ax, ay, az)
	hullTrace.endpos = Vector(bx, by, bz)
	util.TraceHull(hullTrace)
	return not hullResult.Hit and not hullResult.StartSolid
end

-- A person fits all the way from a to b, a step above the ground. One hull
-- trace in a straight line; if that hits something, it may only be the
-- ground itself (over the top of a hill, the straight line goes into it):
-- then again in short pieces that follow the ground, SAMPLE units each.
local function walkable(ax, ay, az, bx, by, bz)
	if hullClear(ax, ay, az + STEP, bx, by, bz + STEP) then return true end
	local dx, dy = bx - ax, by - ay
	local len = sqrt(dx * dx + dy * dy)
	local n = math.ceil(len / SAMPLE)
	if n < 2 then return false end
	local px, py, pz = ax, ay, az
	for k = 1, n do
		local x, y, z
		if k == n then
			x, y, z = bx, by, bz
		else
			local f = k / n
			x, y = ax + dx * f, ay + dy * f
			local reach = STEP * 2 + len / n * 1.05 + 4
			z = groundAt(x, y, pz + reach, pz - reach)
			if not z then return false end
		end
		if not hullClear(px, py, pz + STEP, x, y, z + STEP) then return false end
		px, py, pz = x, y, z
	end
	return true
end

-- The ground all along a to b is walkable for a NextBot: no ledge higher than
-- a step (more on a slope, as steep as the ground there), no hole, nothing
-- too steep. Samples the ground every SAMPLE units; where two samples differ
-- by more than a step it looks in between (stairs: two small steps, fine; a
-- ledge: one big one, not).
local MIN_SPLIT = 4
local function groundBetween(x1, y1, z1, s1, x2, y2, z2, s2, depth)
	local dx, dy = x2 - x1, y2 - y1
	local d = sqrt(dx * dx + dy * dy)
	if abs(z2 - z1) <= STEP + d * math.max(s1, s2) then return true end
	if d < MIN_SPLIT or depth > 6 then return false end
	local mx, my = (x1 + x2) * 0.5, (y1 + y2) * 0.5
	local hi, lo = math.max(z1, z2), math.min(z1, z2)
	local mz = groundAt(mx, my, hi + STEP + 4, lo - STEP - 4)
	if not mz then return false end
	local nz = groundResult.HitNormal.z
	local ms = nz < 0.999 and sqrt(1 - nz * nz) / nz or 0
	return groundBetween(x1, y1, z1, s1, mx, my, mz, ms, depth + 1)
		and groundBetween(mx, my, mz, ms, x2, y2, z2, s2, depth + 1)
end

local function smoothGround(ax, ay, az, bx, by, bz)
	local dx, dy = bx - ax, by - ay
	local len = sqrt(dx * dx + dy * dy)
	local n = math.max(1, math.ceil(len / SAMPLE))
	local step = len / n
	local px, py, pz, pslope = ax, ay, az, 0
	for k = 1, n do
		local f = k / n
		local x, y = ax + dx * f, ay + dy * f
		local z, slope
		if k == n then
			z, slope = bz, pslope
		else
			local reach = STEP * 2 + step * 1.05 + 4
			z = groundAt(x, y, pz + reach, pz - reach)
			if not z then return false end
			local nz = groundResult.HitNormal.z
			slope = nz < 0.999 and sqrt(1 - nz * nz) / nz or 0
		end
		if not groundBetween(px, py, pz, pslope, x, y, z, slope, 0) then return false end
		px, py, pz, pslope = x, y, z, slope
	end
	return true
end

-- A hull trace with a lower box (crouched, for vaulting through windows).
local VAULT_TALL = 36
local function hullClearLow(ax, ay, az, bx, by, bz)
	local top = hullTrace.maxs
	hullTrace.maxs = Vector(top.x, top.y, VAULT_TALL)
	local ok = hullClear(ax, ay, az, bx, by, bz)
	hullTrace.maxs = top
	return ok
end

-- Why links weren't made, for the editor's report.
Nav.Why = Nav.Why or {}
local why = Nav.Why

-- How a person gets from a point at (ax, ay, az) to one at (bx, by, bz) next
-- to it: "walk", "up" (jump up onto a ledge), "drop" (jump down), "vault"
-- (jump over something in the way, or through a window, or over a hole), or
-- nil. Second result: the link's height (a above b; for a vault minus how
-- high it has to go). `vault`: also try vaulting.
local VAULT_HEIGHTS = { 24, 36, 48, 60, 72 }
local function connect(ax, ay, az, bx, by, bz, maxDrop, maxUp, vault)
	local dz = bz - az
	local clear = walkable(ax, ay, az, bx, by, bz)
	if clear and smoothGround(ax, ay, az, bx, by, bz) then return "walk", az - bz end
	if dz > STEP then
		-- Room to jump straight up, then across onto the ledge?
		if dz <= maxUp and hullClear(ax, ay, az + STEP, ax, ay, bz + STEP)
			and hullClear(ax, ay, bz + STEP, bx, by, bz + STEP) then
			return "up", az - bz
		end
		why.ledge = (why.ledge or 0) + 1
	elseif dz < -STEP and maxDrop and -dz <= maxDrop then
		-- Room to step off the edge, then to fall straight down?
		if hullClear(ax, ay, az + STEP, bx, by, az + STEP) and hullClear(bx, by, az + STEP, bx, by, bz + STEP) then
			return "drop", az - bz
		end
		why.ledge = (why.ledge or 0) + 1
	elseif vault and maxUp > 0 and abs(dz) <= STEP then
		-- Something in the way (a low wall, a window sill, a hole): over it?
		local top = math.max(az, bz)
		local best = nil
		for k = #VAULT_HEIGHTS, 1, -1 do
			local v = VAULT_HEIGHTS[k]
			if v <= maxUp then
				if hullClearLow(ax, ay, top + v, bx, by, top + v) then best = v
				elseif best then break end
			end
		end
		-- Up from here crouched, down there, and room to stand up there.
		if best and hullClearLow(ax, ay, az + STEP, ax, ay, top + best)
			and hullClearLow(bx, by, top + best, bx, by, bz + STEP)
			and hullClear(bx, by, bz + STEP, bx, by, bz + STEP) then
			return "vault", -(top + best - az)
		end
		why[clear and "step" or "wall"] = (why[clear and "step" or "wall"] or 0) + 1
	else
		why[clear and "step" or "wall"] = (why[clear and "step" or "wall"] or 0) + 1
	end
	return nil
end

-- Where in a square a point may go when its grid spot doesn't fit: nearest
-- the spot first. Rebuilt when the spacing changes.
local offsets, offsetsFor = nil, nil
local function cellOffsets(S)
	if offsetsFor == S then return offsets end
	local v = { 0 }
	for _, f in ipairs({ 0.15, 0.3, 0.44 }) do v[#v + 1] = floor(S * f); v[#v + 1] = -floor(S * f) end
	offsets = {}
	for _, x in ipairs(v) do
		for _, y in ipairs(v) do offsets[#offsets + 1] = { x, y } end
	end
	table.sort(offsets, function(p, q) return p[1] * p[1] + p[2] * p[2] < q[1] * q[1] + q[2] * q[2] end)
	offsetsFor = S
	return offsets
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

local function joinNodes(i, j, d, kind, h)
	if kind == "walk" then
		Nav.NM[i] = bit.bor(Nav.NM[i], bit.lshift(1, d - 1))
		Nav.NM[j] = bit.bor(Nav.NM[j], bit.lshift(1, OPP[d] - 1))
	else
		addLink(i, j, kind, h)
	end
end

-- A moved spot within 0.6 of a square of a point next to it: that point
-- already covers it, and a second one there would make a hall two rows of
-- points side by side.
local function crowded(nx, ny, bx, by, z)
	local S = Nav.S
	local lim = (S * 0.6) ^ 2
	for d = 1, 8 do
		local cx, cy = nx + DIRS[d][1], ny + DIRS[d][2]
		local j = nodeAt(cx, cy, z, 32)
		if j then
			local dx, dy = cx * S + Nav.OX[j] - bx, cy * S + Nav.OY[j] - by
			if dx * dx + dy * dy < lim then return true end
		end
	end
	return false
end

-- Links node i to its 8 neighbours where a person can walk, jump up or jump
-- down, adding new points to `queue`. A neighbour square with no point yet
-- gets one at its grid spot, or, when a person doesn't fit there or can't get
-- there, at the nearest spot in the square that works (narrow halls,
-- doorways, along walls). `canAdd(ix, iy, z)`, if given, says where new
-- points may go (the editor's add tool keeps to its circle). `drops`: the
-- highest drop to link (nil: none, nor jumps up).
-- Flat open ground, fast: nothing at all (wall, prop, low ceiling) in a box
-- a person tall reaching a square and a half round the point, from a step
-- above its ground. Then a neighbour whose ground is level with this one,
-- and level half way there too, is walked to without the hull and ground
-- checks of connect(): on an open field that's most of them.
local openTrace = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local FLAT_DZ = 1
local function openAround(x, y, z, S)
	local t = openTrace
	local r = S + 14
	t.start, t.endpos = Vector(x, y, z + STEP + 1), Vector(x, y, z + STEP + 1)
	t.mins, t.maxs = Vector(-r, -r, 0), Vector(r, r, HULL_MAXS.z)
	t.filter = hullTrace.filter
	local tr = util.TraceHull(t)
	return not tr.Hit and not tr.StartSolid
end

local tried = {}
local function expandNode(i, queue, maxNodes, canAdd, drops)
	local S = Nav.S
	local maxUp = drops and cvMaxUp:GetFloat() or 0
	local top = math.max(maxUp, S * 1.05) + 8
	local ix, iy, z = Nav.NX[i], Nav.NY[i], Nav.NZ[i]
	local ax, ay = ix * S + Nav.OX[i], iy * S + Nav.OY[i]
	local open = cvFastOpen:GetBool() and Nav.OX[i] == 0 and Nav.OY[i] == 0 and openAround(ax, ay, z, S)
	for d = 1, 8 do
		if bit.band(Nav.NM[i], bit.lshift(1, d - 1)) == 0 then
			local nx, ny = ix + DIRS[d][1], iy + DIRS[d][2]
			-- Try spots in the square, nearest its grid spot first, until one
			-- can be walked to (an existing point there, or a new one). With
			-- none, the first that can be jumped to (straight ahead only, so
			-- each ledge gets one jump per grid line, not three).
			local done, best = false, nil
			for k in pairs(tried) do tried[k] = nil end
			-- One spot: "walk" when joined, "solid" when inside a wall.
			local function try(o, centre)
				local bx, by = nx * S + o[1], ny * S + o[2]
				-- From just above a step first (works under low ceilings); if
				-- that's inside something, it may be a ledge to jump up on:
				-- look from higher up.
				local gz = groundAt(bx, by, z + STEP + 8, z - (drops or 64))
				if not gz and groundResult.StartSolid then
					gz = groundAt(bx, by, z + top, z - (drops or 64))
					if not gz and groundResult.StartSolid then return "solid" end
				end
				if not gz then return nil end
				-- Flat open ground both ends and half way: walk, no more checks.
				if open and centre and abs(gz - z) <= FLAT_DZ and groundResult.HitNormal.z >= 0.999 then
					local mz = groundAt((ax + bx) * 0.5, (ay + by) * 0.5, z + STEP, z - STEP)
					if mz and abs(mz - z) <= FLAT_DZ and groundResult.HitNormal.z >= 0.999 then
						local j = nodeAt(nx, ny, gz, 32)
						if j then
							if Nav.OX[j] == 0 and Nav.OY[j] == 0 then
								joinNodes(i, j, d, "walk", z - gz)
								return "walk"
							end
						elseif Nav.Count < maxNodes and (not canAdd or canAdd(nx, ny, gz)) then
							j = addNode(nx, ny, gz, 0, 0)
							queue[#queue + 1] = j
							joinNodes(i, j, d, "walk", z - gz)
							Nav.FastLinks = (Nav.FastLinks or 0) + 1
							return "walk"
						end
					end
				end
				local j = nodeAt(nx, ny, gz, 32)
				if j then
					if tried[j] then return nil end
					tried[j] = true
					local jz = Nav.NZ[j]
					local kind, h = connect(ax, ay, z, nx * S + Nav.OX[j], ny * S + Nav.OY[j], jz, drops, maxUp, d <= 4)
					if kind == "walk" then
						joinNodes(i, j, d, kind, h)
						return "walk"
					elseif kind and not best and d <= 4 then
						best = { kind = kind, j = j, z = jz, h = h }
					end
				elseif Nav.Count < maxNodes and (not canAdd or canAdd(nx, ny, gz))
					and (centre or not crowded(nx, ny, bx, by, gz)) then
					local kind, h = connect(ax, ay, z, bx, by, gz, drops, maxUp, d <= 4 and centre)
					if kind == "walk" then
						j = addNode(nx, ny, gz, o[1], o[2])
						queue[#queue + 1] = j
						joinNodes(i, j, d, kind, h)
						return "walk"
					elseif kind and not best and d <= 4 then
						best = { kind = kind, z = gz, o = o, h = h }
					end
				end
				return nil
			end
			-- The grid spot first. Then, in a hall or doorway where it doesn't
			-- fit, the spot that keeps this point's line: going along x, the
			-- same y offset (and the other way round), then the same offset
			-- as this point. That way the points of a hall stay in a straight
			-- row and join into one strip of squares, not a zig-zag.
			local ox, oy = Nav.OX[i], Nav.OY[i]
			local results = {}
			local function key(o) return o[1] .. ":" .. o[2] end
			local r = try({ 0, 0 }, true)
			results["0:0"] = r or false
			done = r == "walk"
			if not done and (ox ~= 0 or oy ~= 0) then
				local pref = {}
				if DIRS[d][2] == 0 then pref[1] = { 0, oy }
				elseif DIRS[d][1] == 0 then pref[1] = { ox, 0 } end
				pref[#pref + 1] = { ox, oy }
				for _, o in ipairs(pref) do
					local k = key(o)
					if results[k] == nil then
						r = try(o, false)
						results[k] = r or false
						if r == "walk" then done = true break end
					end
				end
			end
			-- The rest, nearest the grid spot first. The middle of the square
			-- and the four spots round it all inside a wall: the square is
			-- wall, don't try the rest.
			if not done then
				local solid = 0
				for c, o in ipairs(cellOffsets(S)) do
					if c == 6 and solid == 5 then why.wall = (why.wall or 0) + 1 break end
					local k = key(o)
					r = results[k]
					if r == nil then
						r = try(o, false)
						results[k] = r or false
						if r == "walk" then done = true break end
					end
					if r == "solid" and c <= 5 then solid = solid + 1 end
				end
			end
			if not done and best then
				local j = best.j
				if not j then
					j = addNode(nx, ny, best.z, best.o[1], best.o[2])
					queue[#queue + 1] = j
				end
				joinNodes(i, j, d, best.kind, best.h)
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

-- A point right where p is (on the ground below it, within `down`), in
-- whichever square it falls in. Returns it and whether it is new.
local function seedNode(p, down)
	local S = Nav.S
	local ix, iy = floor(p.x / S + 0.5), floor(p.y / S + 0.5)
	local z = groundAt(p.x, p.y, p.z + 32, p.z - down)
	if not z then return nil end
	local j = nodeAt(ix, iy, z, 32)
	if j then return j, false end
	local ox, oy = floor(p.x - ix * S + 0.5), floor(p.y - iy * S + 0.5)
	-- Right on the grid spot when it's close, so open squares stay open.
	if ox * ox + oy * oy < 64 * 64 and hullClear(ix * S, iy * S, z + STEP, ix * S, iy * S, z + STEP) then ox, oy = 0, 0 end
	return addNode(ix, iy, z, ox, oy), true
end

local function generate(report)
	reset()
	local S = Nav.S
	local maxNodes = cvMaxNodes:GetInt()
	local queue = {}
	doorFilter()

	for _, p in ipairs(seedPositions()) do
		local j, new = seedNode(p, 256)
		if new then queue[#queue + 1] = j end
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
	seedNode = seedNode, connect = connect, smoothGround = smoothGround, linkTol = linkTol,
	maxUp = function() return cvDrops:GetBool() and cvMaxUp:GetFloat() or 0 end,
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

-- How an NPC with these capabilities (ENT.JumpDown, JumpUp, JumpGap, Climb)
-- gets along a link: "jump" (down a ledge or across a gap), "up" (jump up
-- onto a ledge), "climb", or nil when it can't.
local function linkMove(L, caps)
	local kind, h = L.kind, L.h or 0
	if kind == "walk" then return "walk" end -- everyone
	if not caps then return nil end
	if kind == "jump" then return caps.gap and "jump" or nil end
	if kind == "drop" and h <= caps.drop then return "jump" end
	if (kind == "up" or kind == "vault") and -h <= caps.up then return "up" end
	if abs(h) <= caps.climb and (kind == "climb" or kind == "up" or kind == "drop") then return "climb" end
	return nil
end
Nav.LinkMove = linkMove

-- Turns a node chain into waypoints. Straight runs along the grid lose their
-- middle points, and so do stretches that can be walked in a straight line
-- over open squares (the NPC cuts across instead of following the grid
-- lines). linkIn[k]: the link taken from chain[k - 1] to chain[k]. Both ends
-- of a link are kept, and pts.links[w] = { move = ..., h = height } marks
-- waypoint w as the take-off point (w + 1 is where it lands).
local MAX_SPAN = 24 -- chain points one straight stretch may skip
local function toWaypoints(chain, linkIn, caps)
	local NX, NY, NZ, OX, OY = Nav.NX, Nav.NY, Nav.NZ, Nav.OX, Nav.OY
	local n = #chain
	local keep = { [1] = true, [n] = true }
	local anchor, ddx, ddy, straight = 1, nil, nil, true
	local work = 0
	for k = 2, n - 1 do
		local a, b, c = chain[k - 1], chain[k], chain[k + 1]
		local brk = linkIn and (linkIn[k] or linkIn[k + 1])
		if not brk then
			-- Still on one straight grid line from the anchor?
			local sx, sy = NX[c] - NX[b], NY[c] - NY[b]
			if k == anchor + 1 then
				ddx, ddy = NX[b] - NX[a], NY[b] - NY[a]
				straight = OX[a] == OX[b] and OY[a] == OY[b]
			end
			straight = straight and sx == ddx and sy == ddy and OX[c] == OX[b] and OY[c] == OY[b]
				and abs(NZ[c] - NZ[b]) <= 24
			if not straight then
				if k + 1 - anchor > MAX_SPAN then
					brk = true
				else
					work = work + (k + 1 - anchor)
					brk = not Nav.OpenLine(nodePos(chain[anchor]), nodePos(c), chain[anchor])
				end
			end
		end
		if brk then
			keep[k] = true
			anchor = k
		end
		if work > 200 then
			work = 0
			coroutine.yield()
		end
	end
	local pts = {}
	local inTri = Nav.InTri or {}
	for k = 1, n do
		if keep[k] then
			pts[#pts + 1] = nodePos(chain[k])
			-- In a narrow place (doorway, hall): reach this point properly
			-- before turning, so the turn doesn't clip the door frame.
			if not inTri[chain[k]] then
				pts.tight = pts.tight or {}
				pts.tight[#pts] = true
			end
		end
		local L = linkIn and linkIn[k + 1]
		local move = L and linkMove(L, caps)
		if move and move ~= "walk" then -- a link joined by hand is just walked
			pts.links = pts.links or {}
			pts.links[#pts] = { move = move, h = L.h or 0 }
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

-- Area edges, built on the first search after the grid or its links change:
--   AreaEdges[a] = list of { to, cost, kind, ... }
--     "portal": a run of open squares between two big areas along one side:
--               p1, p2 (ends on a's side), q1, q2 (on the other's side)
--     "pair":   one walk link between two grid points i, j
--     "link":   a jump, climb or hand-made link L
local function areaCenter(A)
	local p, q = nodePos(A.c00), nodePos(A.c11)
	return Vector((p.x + q.x) * 0.5, (p.y + q.y) * 0.5, (p.z + q.z) * 0.5)
end

local function buildAreaEdges()
	local Areas, AreaOf, NB, NX, NY = Nav.Areas, Nav.AreaOf, Nav.NB, Nav.NX, Nav.NY
	local S = Nav.S
	local tol = linkTol()
	local centers = {}
	for a, A in ipairs(Areas) do centers[a] = areaCenter(A) end
	local edges = {}
	local function add(a, e)
		local m = e.mid
		e.cost = centers[a]:Distance(m) + m:Distance(centers[e.to]) + (e.extra or 0)
		local list = edges[a]
		if not list then list = {}; edges[a] = list end
		list[#list + 1] = e
	end
	-- the grid point next to i in direction (dx, dy), on i's floor
	local function step(i, dx, dy) return nodeAt(NX[i] + dx, NY[i] + dy, Nav.NZ[i], tol) end
	local function linked(i, j)
		local nb = NB[i]
		for k = 1, #nb, 2 do if nb[k] == j then return true end end
		return false
	end
	for i = 1, Nav.Count do
		local a = AreaOf[i]
		if a then
			local A = Areas[a]
			local nb = NB[i]
			for k = 1, #nb, 2 do
				local j = nb[k]
				local b = AreaOf[j]
				if b and b ~= a then
					local B = Areas[b]
					local dx, dy = NX[j] - NX[i], NY[j] - NY[i]
					if A.big and B.big and (dx == 0 or dy == 0) then
						-- Straight across between two big areas: start a portal
						-- run here if the point before along the side isn't one.
						local ax, ay = dy ~= 0 and 1 or 0, dx ~= 0 and 1 or 0 -- along the side
						local pi = step(i, -ax, -ay)
						local pj = pi and step(j, -ax, -ay)
						local low = dx + dy > 0 -- i is on the low side of the square between
						local continues = pi and pj and AreaOf[pi] == a and AreaOf[pj] == b and linked(pi, pj)
							and linked(pi, i) and linked(pj, j) and Nav.SQ[low and pi or pj]
						if not continues then
							local ii, jj, n = i, j, 1
							while true do
								local ni, nj = step(ii, ax, ay), step(jj, ax, ay)
								if not (ni and nj and AreaOf[ni] == a and AreaOf[nj] == b and linked(ni, nj)
									and linked(ii, ni) and linked(jj, nj)) then break end
								-- the square between has to be open floor too
								if not Nav.SQ[low and ii or jj] then break end
								ii, jj, n = ni, nj, n + 1
							end
							if n >= 2 then
								local p1, p2, q1, q2 = nodePos(i), nodePos(ii), nodePos(j), nodePos(jj)
								add(a, { to = b, kind = "portal", p1 = p1, p2 = p2, q1 = q1, q2 = q2,
									mid = (p1 + p2 + q1 + q2) * 0.25 })
							else
								add(a, { to = b, kind = "pair", i = i, j = j, mid = (nodePos(i) + nodePos(j)) * 0.5 })
							end
						end
					else
						add(a, { to = b, kind = "pair", i = i, j = j, mid = (nodePos(i) + nodePos(j)) * 0.5 })
					end
				end
			end
			local out = Nav.LB and Nav.LB[i]
			if out then
				for k = 1, #out do
					local L = Nav.Links[out[k]]
					local b = AreaOf[L.b]
					if b then
						local pa, pb = nodePos(L.a), nodePos(L.b)
						add(a, { to = b, kind = "link", L = L, mid = (pa + pb) * 0.5, extra = L.kind == "walk" and 0 or 3 * S })
					end
				end
			end
		end
	end
	Nav.AreaEdges, Nav.AreaCenters = edges, centers
	return edges
end
Nav.BuildAreaEdges = buildAreaEdges

-- The shortest line through a list of portals ({ l, r } pairs of points, a
-- single point when l == r), from the first to the last ("simple stupid
-- funnel"). Left is the side a positive cross product points to, seen
-- along the way. Returns the corner points, the same Vector objects.
local function cross(o, a, b) return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) end
local function same(a, b) return a.x == b.x and a.y == b.y end
local function funnel(portals)
	local out = { portals[1].l }
	local apex, left, right = portals[1].l, portals[1].l, portals[1].r
	local ai, li, ri = 1, 1, 1
	local i = 2
	local n = #portals
	local guard = 0
	while i <= n do
		guard = guard + 1
		if guard > n * 8 + 64 then break end
		local l, r = portals[i].l, portals[i].r
		local restart = false
		-- right side tightens when r is not right of the right edge
		if cross(apex, right, r) >= 0 then
			if same(apex, right) or cross(apex, left, r) < 0 then
				right, ri = r, i
			else
				-- crossed over the left edge: its end is a corner
				out[#out + 1] = left
				apex, ai = left, li
				right, ri = apex, ai
				i = ai + 1
				restart = true
			end
		end
		if not restart then
			if cross(apex, left, l) <= 0 then
				if same(apex, left) or cross(apex, right, l) > 0 then
					left, li = l, i
				else
					out[#out + 1] = right
					apex, ai = right, ri
					left, li = apex, ai
					i = ai + 1
					restart = true
				end
			end
		end
		if not restart then i = i + 1 end
	end
	local last = portals[n].l
	if not same(out[#out], last) then out[#out + 1] = last end
	return out
end
Nav.Funnel = funnel

-- A portal from segment (p, q) for going from `from` towards `to`.
local function portalOf(p, q, from, to)
	local d = { x = to.x - from.x, y = to.y - from.y }
	local c = d.x * (q.y - p.y) - d.y * (q.x - p.x)
	if c > 0 then return { l = q, r = p } end
	return { l = p, r = q }
end

-- A* over areas, then the path straightened through them. Same result as
-- the point search (waypoints, .links for jumps, .tight for narrow places).
----------------------------------------------------------------------------
-- Regions: areas grouped into chunks of about REGION_AREAS (a room, a piece
-- of field), joined where any of their areas are. A long path is first
-- searched over regions (a few dozen instead of thousands of areas), then
-- over the areas of the regions on that route only; if that finds nothing,
-- over all areas as before.
----------------------------------------------------------------------------
local REGION_AREAS = 40
local HIER_MIN = 1500   -- straight distance from which a path is searched in two steps
local function buildRegions(edges)
	if Nav.RegionsFor == edges then return Nav.RegionOf, Nav.RegionEdges, Nav.RegionCenters end
	local Areas, centers = Nav.Areas, Nav.AreaCenters
	local R, nr = {}, 0
	local members = {}
	for a = 1, #Areas do
		if not R[a] then
			nr = nr + 1
			R[a] = nr
			local queue, head, n = { a }, 1, 1
			members[nr] = queue
			while head <= #queue and n < REGION_AREAS do
				local list = edges[queue[head]]
				head = head + 1
				if list then
					for k = 1, #list do
						local e = list[k]
						local b = e.to
						if not R[b] and (e.kind ~= "link" or e.L.kind == "walk") and n < REGION_AREAS then
							R[b] = nr
							n = n + 1
							queue[#queue + 1] = b
						end
					end
				end
			end
		end
	end
	local rc = {}
	for r = 1, nr do
		local x, y, z, m = 0, 0, 0, members[r]
		for k = 1, #m do local c = centers[m[k]]; x, y, z = x + c.x, y + c.y, z + c.z end
		rc[r] = Vector(x / #m, y / #m, z / #m)
	end
	-- Region edges: { to, cost, walk = any walking crossing, links = { L, ... } }
	local re = {}
	for a, list in pairs(edges) do
		local ra = R[a]
		for k = 1, #list do
			local e = list[k]
			local rb = R[e.to]
			if rb and rb ~= ra then
				local t = re[ra]
				if not t then t = {}; re[ra] = t end
				local x = t[rb]
				if not x then
					x = { to = rb, cost = rc[ra]:Distance(rc[rb]), walk = false }
					t[rb] = x
				end
				if e.kind ~= "link" or e.L.kind == "walk" then x.walk = true
				else x.links = x.links or {}; x.links[#x.links + 1] = e.L end
			end
		end
	end
	local S = Nav.S
	for _, t in pairs(re) do for _, x in pairs(t) do if not x.walk then x.cost = x.cost + 3 * S end end end
	Nav.RegionOf, Nav.RegionEdges, Nav.RegionCenters, Nav.RegionCount, Nav.RegionsFor = R, re, rc, nr, edges
	return R, re, rc
end
Nav.BuildRegions = buildRegions

-- The regions a path from region rs to rg may go through (those on the
-- shortest route over regions), or nil if there's none.
local function regionCorridor(rs, rg, caps)
	local R, re, rc = Nav.RegionOf, Nav.RegionEdges, Nav.RegionCenters
	local goalPos = rc[rg]
	local hn, hf, size = {}, {}, 0
	local g, came, closed = { [rs] = 0 }, {}, {}
	size = heapPush(hn, hf, size, rs, rc[rs]:Distance(goalPos))
	local found = false
	while size > 0 do
		local cur
		cur, size = heapPop(hn, hf, size)
		if cur == rg then found = true break end
		if not closed[cur] then
			closed[cur] = true
			local t = re[cur]
			if t then
				for b, x in pairs(t) do
					local ok = x.walk
					if not ok and x.links then
						for k = 1, #x.links do if linkMove(x.links[k], caps) then ok = true break end end
					end
					if ok and not closed[b] then
						local ng = g[cur] + x.cost
						if not g[b] or ng < g[b] then
							g[b], came[b] = ng, cur
							size = heapPush(hn, hf, size, b, ng + rc[b]:Distance(goalPos))
						end
					end
				end
			end
		end
	end
	if not found then return nil end
	local allowed = {}
	local cur = rg
	while cur do
		allowed[cur] = true
		cur = came[cur]
	end
	return allowed
end
Nav.RegionCorridor = regionCorridor

local areaPath
local areaSearchIn
local function areaSearch(start, goal, caps)
	local edges = Nav.AreaEdges or buildAreaEdges()
	local AreaOf = Nav.AreaOf
	local sa, ga = AreaOf[start], AreaOf[goal]
	if not sa or not ga then return nil end
	-- Far: over regions first, then only the areas along that route.
	if nodePos(start):DistToSqr(nodePos(goal)) > HIER_MIN * HIER_MIN then
		local R = buildRegions(edges)
		if R[sa] ~= R[ga] then
			local allowed = regionCorridor(R[sa], R[ga], caps)
			if allowed then
				local path = areaSearchIn(start, goal, caps, allowed, R)
				if path then
					Nav.Stats.hier = (Nav.Stats.hier or 0) + 1
					return path
				end
			end
		end
	end
	return areaSearchIn(start, goal, caps)
end
Nav.AreaSearch = areaSearch
Nav.AreaSearchAll = function(start, goal, caps) return areaSearchIn(start, goal, caps) end

areaSearchIn = function(start, goal, caps, allowed, R)
	local edges = Nav.AreaEdges or buildAreaEdges()
	local AreaOf, Areas, centers = Nav.AreaOf, Nav.Areas, Nav.AreaCenters
	local sa, ga = AreaOf[start], AreaOf[goal]
	if not sa or not ga then return nil end
	local goalPos = nodePos(goal)
	local hn, hf, size = {}, {}, 0
	local g, came, cameBy, closed = { [sa] = 0 }, {}, {}, {}
	size = heapPush(hn, hf, size, sa, centers[sa]:Distance(goalPos))
	local maxExpand = cvMaxExpand:GetInt()
	local expanded = 0
	local found = false
	while size > 0 do
		local cur
		cur, size = heapPop(hn, hf, size)
		if cur == ga then found = true break end
		if not closed[cur] then
			closed[cur] = true
			expanded = expanded + 1
			if expanded > maxExpand then return nil end
			local list = edges[cur]
			if list then
				local gc = g[cur]
				for k = 1, #list do
					local e = list[k]
					local b = e.to
					if not closed[b] and (e.kind ~= "link" or linkMove(e.L, caps)) and (not allowed or allowed[R[b]]) then
						local ng = gc + e.cost
						if not g[b] or ng < g[b] then
							g[b], came[b], cameBy[b] = ng, cur, e
							size = heapPush(hn, hf, size, b, ng + centers[b]:Distance(goalPos))
						end
					end
				end
			end
			if expanded % 64 == 0 then coroutine.yield() end
		end
	end
	Nav.Stats.lastExpanded = expanded
	if not found then return nil end
	-- The areas and edges from start to goal.
	local seq = {}
	local cur = ga
	while came[cur] do
		table.insert(seq, 1, cameBy[cur])
		cur = came[cur]
	end
	return areaPath(start, goal, seq, caps)
end

-- Waypoints from point `start` to point `goal` through the area edges `seq`
-- (from an area search or a flow field).
-- Portals; jumps split it into stretches, each straightened on its own.
areaPath = function(start, goal, seq, caps)
	local Areas, AreaOf = Nav.Areas, Nav.AreaOf
	local goalPos = nodePos(goal)
	local pts, tight = {}, {}
	local links, tightIdx = nil, nil
	local stretch = { }
	local startPos = nodePos(start)
	stretch[1] = { l = startPos, r = startPos }
	local function point(p) stretch[#stretch + 1] = { l = p, r = p } end
	local function flush()
		local corners = funnel(stretch)
		for _, c in ipairs(corners) do
			if not (pts[#pts] and same(pts[#pts], c) and pts[#pts].z == c.z) then
				pts[#pts + 1] = c
				if tight[c] then tightIdx = tightIdx or {}; tightIdx[#pts] = true end
			end
		end
	end
	for _, e in ipairs(seq) do
		if e.kind == "portal" then
			local mp, mq = (e.p1 + e.p2) * 0.5, (e.q1 + e.q2) * 0.5
			stretch[#stretch + 1] = portalOf(e.p1, e.p2, mp, mq)
			stretch[#stretch + 1] = portalOf(e.q1, e.q2, mp, mq)
		elseif e.kind == "pair" then
			local pi, pj = nodePos(e.i), nodePos(e.j)
			if not Areas[AreaOf[e.i]].big then tight[pi] = true end
			if not Areas[AreaOf[e.j]].big then tight[pj] = true end
			point(pi)
			point(pj)
		else
			local L = e.L
			local pa, pb = nodePos(L.a), nodePos(L.b)
			point(pa)
			flush()
			local move = linkMove(L, caps)
			if move and move ~= "walk" then
				links = links or {}
				links[#pts] = { move = move, h = L.h or 0 }
			end
			stretch = { { l = pb, r = pb } }
			if not Areas[AreaOf[L.b]].big then tight[pb] = true end
		end
	end
	point(goalPos)
	flush()
	if #pts == 1 then pts[2] = goalPos end
	pts.links, pts.tight = links, tightIdx
	return pts
end

----------------------------------------------------------------------------
-- Flow fields: when many NPCs head for the same spot (a squad, a horde
-- chasing one player), one search outward from that spot over the areas
-- (Dijkstra, every area's way to it) serves them all: each NPC's path is
-- read off the field by following it from its own area, no search at all.
-- Made when FIELD_MIN requests from different places want the same goal
-- region within FIELD_WINDOW seconds; kept FIELD_TIME seconds.
----------------------------------------------------------------------------
local FIELD_MIN = 4
local FIELD_WINDOW = 3
local FIELD_TIME = 4
local FIELD_MAX = 8000    -- areas a field reaches at most (further: normal searches)
Nav.Fields = Nav.Fields or {}   -- [key] = field
local demand = {}               -- [key] = { t = first request, n = count, from = { [start key] = true } }

-- Edges into each area (the field is searched backwards from the goal).
local function reverseEdges(edges)
	if Nav.AreaRevFor == edges then return Nav.AreaRev end
	local rev = {}
	for a, list in pairs(edges) do
		for k = 1, #list do
			local e = list[k]
			local r = rev[e.to]
			if not r then r = {}; rev[e.to] = r end
			r[#r + 1] = a
			r[#r + 1] = e
		end
	end
	Nav.AreaRev, Nav.AreaRevFor = rev, edges
	return rev
end

local function buildField(goal, caps)
	local edges = Nav.AreaEdges or buildAreaEdges()
	local rev = reverseEdges(edges)
	local ga = Nav.AreaOf[goal]
	if not ga then return nil end
	local dist, nextE = { [ga] = 0 }, {}
	local closed = {}
	local hn, hf, size = {}, {}, 0
	size = heapPush(hn, hf, size, ga, 0)
	local expanded = 0
	while size > 0 do
		local cur
		cur, size = heapPop(hn, hf, size)
		if not closed[cur] then
			closed[cur] = true
			expanded = expanded + 1
			if expanded > FIELD_MAX then break end
			local list = rev[cur]
			if list then
				local dc = dist[cur]
				for k = 1, #list, 2 do
					local a, e = list[k], list[k + 1]
					if not closed[a] and (e.kind ~= "link" or linkMove(e.L, caps)) then
						local nd = dc + e.cost
						if not dist[a] or nd < dist[a] then
							dist[a], nextE[a] = nd, e
							size = heapPush(hn, hf, size, a, nd)
						end
					end
				end
			end
			if expanded % 128 == 0 then coroutine.yield() end
		end
	end
	return { goal = goal, ga = ga, dist = closed, nextE = nextE, edges = edges, t = CurTime(), caps = caps }
end

-- The path from point s along the field, or nil if s isn't in it.
local function fieldPath(F, s)
	if Nav.AreaEdges ~= F.edges then return nil end
	local a = Nav.AreaOf[s]
	if not a or not F.dist[a] then return nil end
	local seq = {}
	local guard = 0
	while a ~= F.ga do
		local e = F.nextE[a]
		if not e then return nil end
		seq[#seq + 1] = e
		a = e.to
		guard = guard + 1
		if guard > FIELD_MAX then return nil end
	end
	return areaPath(s, F.goal, seq, F.caps)
end
Nav.FieldPath = fieldPath

local function search(start, goal, width, caps)
	-- People search over areas; wide NPCs over points (each point's width is
	-- checked on the way).
	if not width and Nav.Areas then return areaSearch(start, goal, caps) end
	local known
	if width then
		Nav.Wide[width] = Nav.Wide[width] or {}
		known = Nav.Wide[width]
	end
	local traced = 0
	local hn, hf, size = {}, {}, 0
	local g, came, closed = { [start] = 0 }, {}, {}
	local LB, Links = Nav.LB, Nav.Links
	local viaLink = {}
	size = heapPush(hn, hf, size, start, heuristic(start, goal))
	local maxExpand = cvMaxExpand:GetInt()
	local expanded = 0

	while size > 0 do
		local cur
		cur, size = heapPop(hn, hf, size)
		if cur == goal then
			local chain, linkIn = { cur }, {}
			local rev = { viaLink[cur] or false }
			while came[cur] do
				cur = came[cur]
				table.insert(chain, 1, cur)
				table.insert(rev, 1, viaLink[cur] or false)
			end
			for k = 1, #chain do if rev[k] then linkIn[k] = rev[k] end end
			if next(linkIn) == nil then linkIn = nil end
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
						viaLink[j] = nil
						size = heapPush(hn, hf, size, j, ng + heuristic(j, goal))
					end
				end
			end

			-- Jumps and drops this NPC can take, and links joined by hand.
			local out = LB[cur]
			if out then
				for k = 1, #out do
					local L = Links[out[k]]
					local j = L.b
					if not closed[j] and linkMove(L, caps) then
						local dx, dy = Nav.NX[j] - Nav.NX[cur], Nav.NY[j] - Nav.NY[cur]
						-- Jumps a bit dearer than walking; links joined by hand cost their length.
						local ng = gc + sqrt(dx * dx + dy * dy) + (L.kind == "walk" and 0 or 3)
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
	local up = ent.JumpUp or 0
	local climb = ent.Climb or 0
	local gap = ent.JumpGap and true or false
	if drop <= 0 and up <= 0 and climb <= 0 and not gap then return nil end
	local key = string.format("c%d:%d:%d:%s", drop, up, climb, gap and 1 or 0)
	local c = capsCache[key]
	if not c then
		c = { key = key, drop = drop, up = up, climb = climb, gap = gap }
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

-- Islands: which points can reach which. Built once after the grid or its
-- links change (one pass over every point), then a path to a point on
-- another island fails at once instead of searching everything it can reach
-- first. IslandWalk[i]: joined by walking (and links joined by hand, which
-- go both ways); IslandAny[i]: also by any jump, drop or climb, either way.
-- Points on different IslandAny islands are never reachable; with no jumps
-- (caps nil), neither are points on different IslandWalk islands.
local function islands()
	if Nav.IslandWalk then return Nav.IslandWalk, Nav.IslandAny end
	local n, NB, Links = Nav.Count, Nav.NB, Nav.Links
	local parent = {}
	for i = 1, n do parent[i] = i end
	local function find(x)
		local r = x
		while parent[r] ~= r do r = parent[r] end
		while parent[x] ~= r do local nx = parent[x]; parent[x] = r; x = nx end
		return r
	end
	local function union(a, b)
		a, b = find(a), find(b)
		if a ~= b then parent[a] = b end
	end
	for i = 1, n do
		local nb = NB[i]
		if nb then for k = 1, #nb, 2 do union(i, nb[k]) end end
	end
	for _, L in ipairs(Links) do if L.kind == "walk" then union(L.a, L.b) end end
	local walk = {}
	for i = 1, n do walk[i] = find(i) end
	for _, L in ipairs(Links) do if L.kind ~= "walk" then union(L.a, L.b) end end
	local any = {}
	for i = 1, n do any[i] = find(i) end
	Nav.IslandWalk, Nav.IslandAny = walk, any
	return walk, any
end
Nav.Islands = islands

-- Can a path from point s to point t exist at all (see islands)?
function Nav.Reachable(s, t, caps)
	local walk, any = islands()
	if any[s] ~= any[t] then return false end
	if not caps and walk[s] ~= walk[t] then return false end
	return true
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
-- `caps` (optional, see Nav.Caps) lets the path jump up and down ledges,
-- across gaps or climb; such paths have `path.links` (see toWaypoints).
function Nav.RequestPath(from, to, callback, wanted, width, caps)
	if width and width <= 24 then width = nil end
	if caps and #Nav.Links == 0 then caps = nil end -- every path the same: share them
	if width then width = math.ceil(width / 8) * 8 end -- few width classes, more shared work
	if not Nav.Loaded then return false end
	local st = Nav.Stats
	local s, t = Nav.Nearest(from), Nav.Nearest(to)
	if not s or not t then
		st.fail = st.fail + 1
		callback(nil)
		return true
	end

	if not Nav.Reachable(s, t, caps) then
		st.fail = st.fail + 1
		st.unreachable = (st.unreachable or 0) + 1
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

	-- A flow field to this goal region (people only; wide NPCs search points).
	local fkey
	if not width and Nav.Areas then
		local NX, NY, NZ = Nav.NX, Nav.NY, Nav.NZ
		fkey = string.format("%s|%d:%d:%d", caps and caps.key or "", floor(NX[t] / GOAL_REGION),
			floor(NY[t] / GOAL_REGION), floor(NZ[t] / Z_BAND))
		local now = CurTime()
		local F = Nav.Fields[fkey]
		if F and now - F.t < FIELD_TIME then
			local path = fieldPath(F, s)
			if path then
				st.field = (st.field or 0) + 1
				Nav.Cache[key] = { path = path, t = now }
				callback(path)
				return true
			end
		end
		local fk = "F|" .. fkey
		local building = Nav.Pending[fk]
		if building then
			building[#building + 1] = { cb = callback, wanted = wanted, s = s, t = t, key = key, caps = caps }
			return true
		end
		local D = demand[fkey]
		if not D or now - D.t > FIELD_WINDOW then D = { t = now, n = 0, from = {} }; demand[fkey] = D end
		local from = string.format("%d:%d:%d", floor(NX[s] / REGION), floor(NY[s] / REGION), floor(NZ[s] / Z_BAND))
		if not D.from[from] then D.from[from] = true; D.n = D.n + 1 end
		if D.n >= FIELD_MIN and #searches < cvMaxQueue:GetInt() then
			demand[fkey] = nil
			Nav.Pending[fk] = { { cb = callback, wanted = wanted, s = s, t = t, key = key, caps = caps } }
			searches[#searches + 1] = {
				key = fk, field = fkey,
				co = coroutine.create(function() return buildField(t, caps) end),
			}
			return true
		end
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
				if not ok then print("[NGL] Path search error: " .. tostring(res)) end
				local ws = Nav.Pending[job.key]
				Nav.Pending[job.key] = nil
				if job.field then
					-- A flow field: every waiter's path read off it.
					local F = ok and res or nil
					if F then Nav.Fields[job.field] = F; st.fields = (st.fields or 0) + 1 end
					if ws then
						for i = 1, #ws do
							local w = ws[i]
							local path = F and fieldPath(F, w.s) or nil
							if path then
								st.field = (st.field or 0) + 1
								w.cb(path)
							elseif Nav.Pending[w.key] then
								table.insert(Nav.Pending[w.key], w)
							else
								-- Beyond the field: a search of its own.
								Nav.Pending[w.key] = { w }
								local ws_, wt, wc = w.s, w.t, w.caps
								searches[#searches + 1] = {
									key = w.key,
									co = coroutine.create(function() return search(ws_, wt, nil, wc) end),
								}
							end
						end
					end
				else
					local path = ok and res or nil
					if path then st.ok = st.ok + 1 else st.fail = st.fail + 1 end
					Nav.Cache[job.key] = { path = path, t = CurTime() }
					if ws then
						for i = 1, #ws do ws[i].cb(path) end
					end
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
	for k, F in pairs(Nav.Fields) do
		if now - F.t > FIELD_TIME then Nav.Fields[k] = nil end
	end
	for k, D in pairs(demand) do
		if now - D.t > FIELD_WINDOW then demand[k] = nil end
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
