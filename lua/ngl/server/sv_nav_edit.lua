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
--   unlink { p, r }  jump and climb links starting or ending within r of p taken out

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
	I.flood(queue, I.maxNodes(), inside, I.maxDrop())
	return string.format("added %d points", Nav.Count - before)
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

-- mode: "area", "link" or "climb"; button: "left", "right" or "reload".
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
	if mode == "link" or mode == "climb" then
		if button == "right" then
			ply.NGLNavLinkA = nil
			res = Nav.AddEdit({ op = "unlink", p = p, r = math.min(radius, 256) })
		elseif not ply.NGLNavLinkA then
			ply.NGLNavLinkA = p
			say(ply, mode == "climb" and "Climb start set: now click the other end" or "Jump start set: now click where it lands")
			Nav.SendView(ply)
			return true
		else
			res = Nav.AddEdit({ op = mode == "climb" and "climb" or "link", a = ply.NGLNavLinkA, b = p })
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
-- What the tool shows: the grid round the player, sent on request while the
-- tool is out (about once a second), only to superadmins.
----------------------------------------------------------------------------

util.AddNetworkString("ngl_nav_view")
local VIEW_RADIUS = 1400
local VIEW_MAX = 1500

function Nav.SendView(ply)
	if not (IsValid(ply) and allowed(ply)) then return end
	local p = ply:GetPos()
	local list, idx = {}, {}
	if Nav.Loaded then
		eachNodeNear(Vector(p.x, p.y, p.z), VIEW_RADIUS, function(i)
			if #list < VIEW_MAX then list[#list + 1] = i; idx[i] = #list end
		end)
	end
	net.Start("ngl_nav_view")
	net.WriteUInt(#list, 12)
	for _, i in ipairs(list) do net.WriteVector(Nav.NodePos(i)) end
	-- Open squares (drawn filled), as their four corners.
	local squares, inSquare = {}, {}
	local NX, NY = Nav.NX, Nav.NY
	local function corner(i, dx, dy)
		local nb = Nav.NB[i]
		for m = 1, #nb, 2 do
			local j = nb[m]
			if NX[j] - NX[i] == dx and NY[j] - NY[i] == dy then return j end
		end
	end
	for k, i in ipairs(list) do
		if Nav.SQ[i] then
			local e, n, ne = corner(i, 1, 0), corner(i, 0, 1), corner(i, 1, 1)
			local ke, kn, kne = idx[e], idx[n], idx[ne]
			if ke and kn and kne then
				squares[#squares + 1] = { k, ke, kne, kn }
				local function mark(a, b) inSquare[math.min(a, b) * 4096 + math.max(a, b)] = true end
				mark(k, ke); mark(ke, kne); mark(kne, kn); mark(kn, k); mark(k, kne); mark(ke, kn)
			end
		end
	end
	net.WriteUInt(#squares, 12)
	for _, q in ipairs(squares) do
		for c = 1, 4 do net.WriteUInt(q[c], 12) end
	end
	-- Walk links not part of an open square (drawn as lines).
	local edges = {}
	for k, i in ipairs(list) do
		local nb = Nav.NB[i]
		for m = 1, #nb, 2 do
			local j = idx[nb[m]]
			if j and j > k and not inSquare[k * 4096 + j] then edges[#edges + 1] = k; edges[#edges + 1] = j end
		end
	end
	net.WriteUInt(#edges / 2, 14)
	for _, v in ipairs(edges) do net.WriteUInt(v, 12) end
	local links = {}
	for _, L in ipairs(Nav.Links) do
		if idx[L.a] or idx[L.b] then links[#links + 1] = L end
		if #links >= 500 then break end
	end
	net.WriteUInt(#links, 10)
	for _, L in ipairs(links) do
		net.WriteVector(Nav.NodePos(L.a))
		net.WriteVector(Nav.NodePos(L.b))
		net.WriteUInt(Nav.KindCode[L.kind] or 1, 3)
	end
	local a = ply.NGLNavLinkA
	net.WriteBool(a ~= nil)
	if a then net.WriteVector(vec(a)) end
	net.Send(ply)
end

net.Receive("ngl_nav_view", function(_, ply)
	if not allowed(ply) then return end
	local now = CurTime()
	if now < (ply.NGLNavViewT or 0) then return end
	ply.NGLNavViewT = now + 0.8
	Nav.SendView(ply)
end)

-- Edits saved for this map go on the grid that's already loaded.
Nav.LoadEdits()
if Nav.Loaded and #Nav.Edits > 0 then Nav.Load() end
