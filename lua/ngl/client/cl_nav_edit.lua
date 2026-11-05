-- Draws the NGL nav grid inside a sphere round the player while the NGL Nav
-- Editor tool is out (the server sends it, see sv_nav_edit.lua), and the
-- tool's circle. The sphere's size is ngl_nav_view_radius: turn it up to see
-- the whole map. Every area is drawn as squares, filled, with a faint
-- outline, like GMod's own navmesh, lying on hills and ramps.
NGL.NavView = NGL.NavView or { nodes = {}, links = {}, meshes = {} }
local V = NGL.NavView

local radiusCvar = CreateClientConVar("ngl_nav_view_radius", "1500", true, true,
	"How far round you the NGL Nav Editor shows the grid", 200, 20000)

local UP = 5 -- drawn this far above the ground
local TRIS_PER_MESH = 10000
local LINES_PER_MESH = 15000

local BLUE, WHITE, RED = Color(0, 170, 255), Color(255, 255, 255), Color(255, 60, 60)
local FILL, OUTLINE = Color(0, 170, 255, 28), Color(120, 210, 255, 70)
-- Link colours by kind (Nav.KindCode): drop, gap jump, jump up, climb, walk
-- (joined by hand), vault (over or through something).
local LINK_COLOR = { Color(255, 210, 0), Color(60, 255, 90), Color(255, 130, 0), Color(200, 90, 255),
	Color(0, 170, 255), Color(255, 90, 160) }
V.LINK_COLOR = LINK_COLOR

local mat
local function material()
	mat = mat or CreateMaterial("ngl_nav_view", "UnlitGeneric", {
		["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$nocull"] = 1,
	})
	return mat
end

local function freeMeshes()
	for _, m in ipairs(V.meshes) do if m.mesh and m.mesh.Destroy then m.mesh:Destroy() end end
	V.meshes = {}
end

-- Meshes of `count` pieces (triangles or lines) of `per` corners each.
local function buildMeshes(kind, list, per, color, maxPer)
	local nodes = V.nodes
	local count = #list / per
	local first = 0
	while first < count do
		local n = math.min(maxPer, count - first)
		local m = Mesh()
		mesh.Begin(m, kind, n)
		for k = first * per + 1, (first + n) * per do
			local p = nodes[list[k]]
			mesh.Position(p)
			mesh.Color(color.r or color[1], color.g or color[2], color.b or color[3], color.a or color[4])
			mesh.AdvanceVertex()
		end
		mesh.End()
		V.meshes[#V.meshes + 1] = { mesh = m }
		first = first + n
	end
end

-- Reads what the server sent (see Nav.ViewData) and builds the meshes.
function V.Parse(text)
	local nums, n = {}, 0
	for w in string.gmatch(text, "%S+") do n = n + 1; nums[n] = tonumber(w) end
	local k = 0
	local function get() k = k + 1; return nums[k] or 0 end
	local nodes = {}
	for i = 1, get() do nodes[i] = Vector(get(), get(), get() + UP) end
	local tris, outline, lines, links = {}, {}, {}, {}
	for i = 1, get() * 3 do tris[i] = get() end
	for i = 1, get() * 2 do outline[i] = get() end
	for i = 1, get() * 2 do lines[i] = get() end
	for i = 1, get() do
		links[i] = { a = Vector(get(), get(), get() + UP), b = Vector(get(), get(), get() + UP), kind = get() }
	end
	V.linkA = get() == 1 and Vector(get(), get(), get()) or nil
	local points = {}
	for i = 1, get() do points[i] = Vector(get(), get(), get() + UP) end
	V.points = points
	V.nodes, V.links = nodes, links
	V.tris, V.outline, V.lines = tris, outline, lines
	freeMeshes()
	if Mesh then
		buildMeshes(MATERIAL_TRIANGLES, tris, 3, FILL, TRIS_PER_MESH)
		buildMeshes(MATERIAL_LINES, outline, 2, OUTLINE, LINES_PER_MESH)
		buildMeshes(MATERIAL_LINES, lines, 2, BLUE, LINES_PER_MESH)
	end
end

local pieces = {}
net.Receive("ngl_nav_view", function()
	local id, k, total = net.ReadUInt(16), net.ReadUInt(8), net.ReadUInt(8)
	local data = net.ReadData(net.ReadUInt(32))
	if pieces.id ~= id then pieces = { id = id } end
	pieces[k] = data
	for i = 1, total do if not pieces[i] then return end end
	local text = util.Decompress(table.concat(pieces, "", 1, total))
	pieces = {}
	if text then V.Parse(text) end
end)

local function holdingTool()
	local ply = LocalPlayer()
	local w = IsValid(ply) and ply:GetActiveWeapon()
	if not (IsValid(w) and w:GetClass() == "gmod_tool") then return false end
	local t = ply:GetTool()
	return t and t.Mode == "ngl_nav"
end
V.HoldingTool = holdingTool

hook.Add("PostDrawTranslucentRenderables", "NGL.NavView", function(depth, _, sky) -- 3D skybox pass (the 2nd is true on maps without one)
	if sky or not holdingTool() then return end
	if #V.meshes > 0 then
		render.SetMaterial(material())
		for _, m in ipairs(V.meshes) do m.mesh:Draw() end
	end
	render.SetColorMaterial()
	for _, L in ipairs(V.links) do
		local c = LINK_COLOR[L.kind] or LINK_COLOR[1]
		render.DrawLine(L.a, L.b, c, false)
		render.DrawWireframeBox(L.b, angle_zero, Vector(-4, -4, 0), Vector(4, 4, 8), c, false)
	end
	if V.linkA then render.DrawWireframeSphere(V.linkA, 12, 8, 8, RED, false) end
	-- The tool's circle where we aim.
	local ply = LocalPlayer()
	local tr = ply:GetEyeTrace()
	if tr.Hit then
		local r = GetConVarNumber("ngl_nav_radius")
		local mode = GetConVarString("ngl_nav_mode")
		if mode ~= "area" and mode ~= "squares" then
			r = 24
			-- The grid point a click here would use.
			local now = CurTime()
			if now >= (V.snapT or 0) then
				V.snapT = now + 0.1
				local best, bd = nil, 160 * 160
				for _, p in ipairs(V.points or {}) do
					local d = p:DistToSqr(tr.HitPos)
					if d < bd then best, bd = p, d end
				end
				V.snap = best
			end
			if V.snap then render.DrawWireframeSphere(V.snap, 8, 6, 6, WHITE, false) end
		end
		local prev
		for i = 0, 24 do
			local a = i / 24 * math.pi * 2
			local p = tr.HitPos + Vector(math.cos(a) * r, math.sin(a) * r, 4)
			if prev then render.DrawLine(prev, p, WHITE, false) end
			prev = p
		end
	end
end)
