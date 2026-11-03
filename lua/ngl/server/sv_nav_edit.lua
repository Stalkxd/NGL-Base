-- NGL nav grid editing: what the NGL Nav Editor tool (gmod_tool ngl_nav)
-- does on the server, and the grid it shows to the player holding it.
--
-- Edits are a list of operations kept in data/ngl_nav/<map>_edits.txt, by
-- world position, apart from the generated grid. Loading the grid (or
-- generating it again) puts them back on in order, and undo just reloads
-- the grid with one edit fewer.
--   add    { p, r }  walkable area flood-filled from p, within r
--   remove { p, r }  points within r of p (on that floor) taken out
--   link   { a, b }  a jump from a to b: down or up a ledge, or across a gap
--   climb  { a, b }  a climb between a and b, both ways (ENT.Climb NPCs)
--   connect { a, b } a walk link between the points nearest a and b, both ways
--   unlink { p, r }  jump, climb and walk links starting or ending within r of p taken out

local Nav = NGL.Nav
local I = Nav._I
local floor, abs = math.floor, math.abs

local FLOOR_Z = 100     -- an edit only touches points this close in height
local MAX_RADIUS = 1024
local MAX_EDITS = 2000

local function editsPath()
	return "ngl_nav/" .. game.GetMap() .. "_edits.txt"
end

local function vec(t) return Vector(t[1], t[2], t[3]) end
local function tab(v) return { math.Round(v.x, 1), math.Round(v.y, 1), math.Round(v.z, 1) } end

function Nav.LoadEdits()
	local raw = file.Read(editsPath(), "DATA")
	local list = raw and util.JSONToTable(raw)
	Nav.Edits = type(list) == "table" and list or {}
	return Nav.Edits
end

function Nav.SaveEdits()
	file.CreateDir("ngl_nav")
	if #Nav.Edits == 0 then
		file.Delete(editsPath())
	else
		file.Write(editsPath(), util.TableToJSON(Nav.Edits))
	end
end

-- Drops removed points and links to them, renumbers the rest and rebuilds
-- the neighbour and link lists. Searches over the old numbering are dropped
-- (their NPCs ask again).
local function compact()
	local dead = Nav.Dead
	local NX, NY, NZ, NM, OX, OY = Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.OX, Nav.OY
	local links = Nav.Links
	local map = {}
	local count = Nav.Count
	Nav.NX, Nav.NY, Nav.NZ, Nav.NM, Nav.NB = {}, {}, {}, {}, {}
	Nav.OX, Nav.OY, Nav.SQ = {}, {}, {}
	Nav.Cells, Nav.Count, Nav.Dead, Nav.Links = {}, 0, {}, {}
	for i = 1, count do
		if not dead[i] then
			local j = I.addNode(NX[i], NY[i], NZ[i], OX[i], OY[i])
			Nav.NM[j] = NM[i]
			map[i] = j
		end
	end
	for _, L in ipairs(links) do
		local a, b = map[L.a], map[L.b]
		if a and b then I.addLink(a, b, L.kind, L.h) end
	end
	I.buildNeighbours()
	I.buildLinks()
	I.clearSearches()
	Nav.Cache, Nav.Pending, Nav.Wide = {}, {}, {}
	Nav.Loaded = Nav.Count > 0
end
Nav.Compact = compact

local function eachNodeNear(p, r, fn)
	local S = Nav.S
	local cr = math.ceil(r / S)
	local cx, cy = floor(p.x / S + 0.5), floor(p.y / S + 0.5)
	local r2 = r * r
	for x = cx - cr, cx + cr do
		for y = cy - cr, cy + cr do
			local c = Nav.Cells[I.cellKey(x, y)]
			if c then
				for k = 1, #c do
					local i = c[k]
					local dx, dy = x * S + Nav.OX[i] - p.x, y * S + Nav.OY[i] - p.y
					if dx * dx + dy * dy <= r2 and abs(Nav.NZ[i] - p.z) < FLOOR_Z and not Nav.Dead[i] then fn(i) end
				end
			end
		end
	end
end

-- One edit on the grid as it is (no compact). Returns a short result text.
local APPLY = {}

function APPLY.remove(e)
	local p, r = vec(e.p), e.r
	local n = 0
	eachNodeNear(p, r, function(i) Nav.Dead[i] = true; n = n + 1 end)
	return string.format("removed %d points", n)
end

function APPLY.add(e)
	local p, r = vec(e.p), e.r
	local S = Nav.S
	I.doorFilter()
	local before = Nav.Count
	-- Right where it was clicked, so it works in narrow halls and doorways.
	local start = I.seedNode(Vector(p.x, p.y, p.z + 16), 112)
	if not start then return "no ground there" end
	local r2 = r * r
	local function inside(nx, ny, gz)
		local dx, dy = nx * S - p.x, ny * S - p.y
		return dx * dx + dy * dy <= r2 and abs(gz - p.z) < r + FLOOR_Z
	end
	-- Flood from the new point, and from the old points inside the circle so
	-- the new area links up with them.
	local queue = { start }
	eachNodeNear(p, r + S, function(i) if i ~= start then queue[#queue + 1] = i end end)
	for _, i in ipairs(queue) do Nav.NM[i] = 0 end -- re-check every direction here
	local why = Nav.Why
	for k in pairs(why) do why[k] = nil end
	I.flood(queue, I.maxNodes(), inside, I.maxDrop())
	local added = Nav.Count - before
	if added > 0 then return string.format("added %d points", added) end
	-- Nothing new: say what stopped it, so it can be fixed (a link by hand,
	-- a smaller spacing).
	local parts = {}
	if (why.wall or 0) > 0 then parts[#parts + 1] = why.wall .. " walls" end
	if (why.step or 0) > 0 then parts[#parts + 1] = why.step .. " steps too high" end
	if (why.ledge or 0) > 0 then parts[#parts + 1] = why.ledge .. " ledges" end
	if #parts == 0 then return "added 0 points (it's all on the grid already)" end
	return "added 0 points (blocked by " .. table.concat(parts, ", ") .. ")"
end

local MAX_JUMP_UP = 128

function APPLY.link(e)
	local a, b = Nav.Nearest(vec(e.a)), Nav.Nearest(vec(e.b))
	if not a or not b then return "both ends must be on the grid" end
	if a == b then return "same point" end
	local h = Nav.NZ[a] - Nav.NZ[b]
	if h < -MAX_JUMP_UP then return "too high to jump up (use a climb link)" end
	if h < -40 then
		I.addLink(a, b, "up", h)
		return string.format("jump up link, %d units up", -h)
	end
	if h > 40 then
		I.addLink(a, b, "drop", h)
		return string.format("drop link, %d units down", h)
	end
	-- About level: a gap jump, both ways.
	I.addLink(a, b, "jump", 0)
	I.addLink(b, a, "jump", 0)
	return "jump link (both ways)"
end

function APPLY.climb(e)
	local a, b = Nav.Nearest(vec(e.a)), Nav.Nearest(vec(e.b))
	if not a or not b then return "both ends must be on the grid" end
	if a == b then return "same point" end
	local h = Nav.NZ[a] - Nav.NZ[b]
	I.addLink(a, b, "climb", h)
	I.addLink(b, a, "climb", -h)
	return string.format("climb link, %d units (both ways)", math.abs(h))
end

-- Joins two points with a walk link both ways, for a doorway or a narrow
-- place the grid didn't get through. NPCs walk straight from one to the other.
local MAX_CONNECT = 512
function APPLY.connect(e)
	local a, b = Nav.Nearest(vec(e.a)), Nav.Nearest(vec(e.b))
	if not a or not b then return "both ends must be on the grid" end
	if a == b then return "same point" end
	local pa, pb = Nav.NodePos(a), Nav.NodePos(b)
	if pa:Distance(pb) > MAX_CONNECT then return string.format("too far apart (%d, at most %d)", pa:Distance(pb), MAX_CONNECT) end
	local h = Nav.NZ[a] - Nav.NZ[b]
	I.addLink(a, b, "walk", h)
	I.addLink(b, a, "walk", -h)
	return string.format("connected (%d units)", pa:Distance(pb))
end

function APPLY.unlink(e)
	local p, r = vec(e.p), e.r
	local r2 = r * r
	local keep, n = {}, 0
	for _, L in ipairs(Nav.Links) do
		local pa, pb = Nav.NodePos(L.a), Nav.NodePos(L.b)
		if pa:DistToSqr(p) <= r2 or pb:DistToSqr(p) <= r2 then n = n + 1 else keep[#keep + 1] = L end
	end
	Nav.Links = keep
	I.buildLinks()
	return string.format("removed %d links", n)
end

local function apply(e)
	local f = APPLY[e.op]
	if not f or not Nav.Loaded and e.op ~= "add" then return "skipped" end
	if not Nav.Loaded then
		-- Adding area on a map with no grid at all: start one.
		I.reset()
		Nav.Loaded = true
	end
	return f(e)
end

-- Puts every saved edit back on the freshly loaded or generated grid.
function Nav.ApplyEdits()
	local list = Nav.Edits or Nav.LoadEdits()
	if #list == 0 then return end
	for _, e in ipairs(list) do apply(e) end
	compact()
end

-- Adds one edit (from the tool), applies it and saves. Returns the result.
function Nav.AddEdit(e)
	Nav.Edits = Nav.Edits or Nav.LoadEdits()
	if #Nav.Edits >= MAX_EDITS then return "too many edits (ngl_nav_edit_clear to start over)" end
	if e.r then e.r = math.Clamp(e.r, 16, MAX_RADIUS) end
	local res = apply(e)
	compact()
	Nav.Edits[#Nav.Edits + 1] = e
	Nav.SaveEdits()
	return res
end

-- Takes the last edit back: the grid is loaded again without it.
function Nav.UndoEdit()
	Nav.Edits = Nav.Edits or Nav.LoadEdits()
	local e = table.remove(Nav.Edits)
	if not e then return "nothing to undo" end
	Nav.SaveEdits()
	if not Nav.Load() then
		I.reset()
		Nav.ApplyEdits()
	end
	return "undid " .. e.op
end

----------------------------------------------------------------------------
-- The tool (called from lua/weapons/gmod_tool/stools/ngl_nav.lua)
----------------------------------------------------------------------------

local function allowed(ply) return not IsValid(ply) or ply:IsSuperAdmin() end
local function say(ply, msg)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCENTER, msg) else print("[NGL] " .. msg) end
end

-- mode: "area", "link", "climb" or "connect"; button: "left", "right" or "reload".
function Nav.ToolUse(ply, mode, button, pos, radius)
	if not allowed(ply) then say(ply, "NGL Nav Editor: superadmins only") return false end
	if Nav.Generating() then say(ply, "Nav grid is being generated, wait a moment") return false end
	if button == "reload" then
		ply.NGLNavLinkA = nil
		say(ply, Nav.UndoEdit())
		Nav.SendView(ply)
		return true
	end
	local p = tab(pos)
	local res
	if mode == "link" or mode == "climb" or mode == "connect" then
		if button == "right" then
			ply.NGLNavLinkA = nil
			res = Nav.AddEdit({ op = "unlink", p = p, r = math.min(radius, 256) })
		elseif not ply.NGLNavLinkA then
			ply.NGLNavLinkA = p
			say(ply, mode == "climb" and "Climb start set: now click the other end"
				or mode == "connect" and "First point set: now click the point to connect it to"
				or "Jump start set: now click where it lands")
			Nav.SendView(ply)
			return true
		else
			res = Nav.AddEdit({ op = mode == "link" and "link" or mode, a = ply.NGLNavLinkA, b = p })
			ply.NGLNavLinkA = nil
		end
	else
		res = Nav.AddEdit({ op = button == "right" and "remove" or "add", p = p, r = radius })
	end
	say(ply, res)
	Nav.SendView(ply)
	return true
end

concommand.Add("ngl_nav_edit_clear", function(ply)
	if not allowed(ply) then return end
	Nav.Edits = {}
	Nav.SaveEdits()
	if not Nav.Load() then I.reset() end
	say(ply, "All nav edits removed")
end)

----------------------------------------------------------------------------
-- What the tool shows: the grid inside a sphere round the player (its size
-- is the player's ngl_nav_view_radius, big enough for the whole map), sent
-- only to superadmins with the tool out, and only again when the player has
-- moved, the size changed or the grid changed. It goes as one compressed
-- text of numbers, in pieces of at most VIEW_PIECE bytes, one piece a tick.
----------------------------------------------------------------------------

util.AddNetworkString("ngl_nav_view")
local VIEW_MIN, VIEW_MAX_RADIUS = 200, 20000
local VIEW_MAX_NODES = 30000
local VIEW_MAX_LINKS = 2000
local VIEW_PIECE = 60000

-- The numbers the client draws from, in this order:
--   node count, then x y z for each node (whole units)
--   triangle count, then three node numbers for each (the areas, filled)
--   outline count, then two node numbers for each (the areas' sides)
--   line count, then two node numbers for each (walkable, not inside an area)
--   link count, then ax ay az bx by bz kind for each (Nav.KindCode)
--   1 and x y z of the link start being placed, or 0
function Nav.ViewData(center, radius, linkA)
	local out, n = {}, 0
	local function put(v) n = n + 1; out[n] = v end
	local list, idx = {}, {}
	if Nav.Loaded then
		local NX, NY, NZ, OX, OY, dead = Nav.NX, Nav.NY, Nav.NZ, Nav.OX, Nav.OY, Nav.Dead
		local S = Nav.S
		local r2 = radius * radius
		local cx, cy, cz = center.x, center.y, center.z
		local dist = {}
		for i = 1, Nav.Count do
			if not dead[i] then
				local dx, dy, dz = NX[i] * S + OX[i] - cx, NY[i] * S + OY[i] - cy, NZ[i] - cz
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 <= r2 then list[#list + 1] = i; dist[i] = d2 end
			end
		end
		-- Too many: the nearest ones, so the grid round the player shows.
		if #list > VIEW_MAX_NODES then
			table.sort(list, function(a, b) return dist[a] < dist[b] end)
			for k = #list, VIEW_MAX_NODES + 1, -1 do list[k] = nil end
		end
		for k, i in ipairs(list) do idx[i] = k end
	end
	-- Areas reaching out of the sphere are drawn whole: their far corners too.
	do
		local Areas, AreaOf = Nav.Areas or {}, Nav.AreaOf or {}
		local seen = {}
		for k = 1, #list do
			local a = AreaOf[list[k]]
			local A = a and Areas[a]
			if A and A.big and not seen[a] then
				seen[a] = true
				for _, c in ipairs({ A.c00, A.c10, A.c11, A.c01 }) do
					if not idx[c] then list[#list + 1] = c; idx[c] = #list end
				end
			end
		end
	end
	put(#list)
	for _, i in ipairs(list) do
		local p = Nav.NodePos(i)
		put(floor(p.x + 0.5)); put(floor(p.y + 0.5)); put(floor(p.z + 0.5))
	end
	-- Areas (see Nav.BuildAreas): each rectangle with all four corners in the
	-- sphere, as two triangles and its four sides.
	local tris, outline = {}, {}
	local Areas, AreaOf = Nav.Areas or {}, Nav.AreaOf or {}
	local seen = {}
	for k, i in ipairs(list) do
		local a = AreaOf[i]
		local A = a and Areas[a]
		if A and A.big and not seen[a] then
			seen[a] = true
			local c00, c10, c11, c01 = idx[A.c00], idx[A.c10], idx[A.c11], idx[A.c01]
			if c00 and c10 and c11 and c01 then
				for _, v in ipairs({ c00, c10, c11, c00, c11, c01 }) do tris[#tris + 1] = v end
				for _, v in ipairs({ c00, c10, c10, c11, c11, c01, c01, c00 }) do outline[#outline + 1] = v end
			end
		end
	end
	put(#tris / 3)
	for _, v in ipairs(tris) do put(v) end
	put(#outline / 2)
	for _, v in ipairs(outline) do put(v) end
	-- Walkable connections that aren't inside one rectangle.
	local lines = {}
	for k, i in ipairs(list) do
		local nb = Nav.NB[i]
		local a = AreaOf[i]
		local inBig = a and Areas[a] and Areas[a].big
		for m = 1, #nb, 2 do
			local j = idx[nb[m]]
			if j and j > k and not (inBig and AreaOf[nb[m]] == a) then lines[#lines + 1] = k; lines[#lines + 1] = j end
		end
	end
	put(#lines / 2)
	for _, v in ipairs(lines) do put(v) end
	local links = {}
	if #list > 0 then
		for _, L in ipairs(Nav.Links) do
			if idx[L.a] or idx[L.b] then links[#links + 1] = L end
			if #links >= VIEW_MAX_LINKS then break end
		end
	end
	put(#links)
	for _, L in ipairs(links) do
		local a, b = Nav.NodePos(L.a), Nav.NodePos(L.b)
		put(floor(a.x + 0.5)); put(floor(a.y + 0.5)); put(floor(a.z + 0.5))
		put(floor(b.x + 0.5)); put(floor(b.y + 0.5)); put(floor(b.z + 0.5))
		put(Nav.KindCode[L.kind] or 1)
	end
	if linkA then
		put(1); put(floor(linkA[1] + 0.5)); put(floor(linkA[2] + 0.5)); put(floor(linkA[3] + 0.5))
	else
		put(0)
	end
	return out
end

local sending = {} -- player -> { pieces, next piece, id }
local viewId = 0

-- Sends the view to ply now (after an edit), or when it has changed
-- (`ifChanged`, on the tool's requests).
function Nav.SendView(ply, radius, ifChanged)
	if not (IsValid(ply) and allowed(ply)) then return end
	radius = math.Clamp(radius or ply.NGLNavViewR or 1500, VIEW_MIN, VIEW_MAX_RADIUS)
	local p = ply:GetPos()
	local last = ply.NGLNavViewSent
	local a = ply.NGLNavLinkA
	local aKey = a and table.concat(a, " ") or ""
	if ifChanged and last and last.r == radius and last.ver == Nav.Version and last.a == aKey
		and last.pos:DistToSqr(p) < math.max(128, radius * 0.2) ^ 2 then
		return
	end
	ply.NGLNavViewR = radius
	ply.NGLNavViewSent = { pos = p, r = radius, ver = Nav.Version, a = aKey }
	local data = util.Compress(table.concat(Nav.ViewData(p, radius, a), " ")) or ""
	local pieces = {}
	for k = 1, math.max(1, math.ceil(#data / VIEW_PIECE)) do
		pieces[k] = string.sub(data, (k - 1) * VIEW_PIECE + 1, k * VIEW_PIECE)
	end
	viewId = (viewId + 1) % 65536
	sending[ply] = { pieces = pieces, k = 1, id = viewId }
	Nav.SendViewPieces()
end

-- One piece per player per tick, so a big view doesn't overflow the network.
function Nav.SendViewPieces()
	for ply, s in pairs(sending) do
		if not IsValid(ply) then
			sending[ply] = nil
		else
			local piece = s.pieces[s.k]
			net.Start("ngl_nav_view")
			net.WriteUInt(s.id, 16)
			net.WriteUInt(s.k, 8)
			net.WriteUInt(#s.pieces, 8)
			net.WriteUInt(#piece, 32)
			net.WriteData(piece, #piece)
			net.Send(ply)
			s.k = s.k + 1
			if s.k > #s.pieces then sending[ply] = nil end
		end
	end
end
hook.Add("Think", "NGL.NavViewSend", function()
	if next(sending) then Nav.SendViewPieces() end
end)

-- The tool asks about once a second while it's out, with its view size.
net.Receive("ngl_nav_view", function(_, ply)
	if not allowed(ply) then return end
	local radius = net.ReadUInt(16)
	local now = CurTime()
	if now < (ply.NGLNavViewT or 0) then return end
	ply.NGLNavViewT = now + 0.5
	if Nav.Generating() then return end
	Nav.SendView(ply, radius, true)
end)

-- Edits saved for this map go on the grid that's already loaded.
Nav.LoadEdits()
if Nav.Loaded and #Nav.Edits > 0 then Nav.Load() end
