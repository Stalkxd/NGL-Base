-- Draws the NGL nav grid round the player while the NGL Nav Editor tool is
-- out (the server sends it, see sv_nav_edit.lua), and the tool's circle.
-- Open squares (NPCs walk straight across them) are filled with a faint
-- outline; elsewhere the walk links are drawn as lines.
NGL.NavView = NGL.NavView or { nodes = {}, squares = {}, edges = {}, links = {}, until_ = 0 }
local V = NGL.NavView

local UP = Vector(0, 0, 3)

net.Receive("ngl_nav_view", function()
	local nodes, squares, edges, links = {}, {}, {}, {}
	for i = 1, net.ReadUInt(12) do nodes[i] = net.ReadVector() + UP end
	for i = 1, net.ReadUInt(12) do
		squares[i] = { net.ReadUInt(12), net.ReadUInt(12), net.ReadUInt(12), net.ReadUInt(12) }
	end
	for i = 1, net.ReadUInt(14) * 2 do edges[i] = net.ReadUInt(12) end
	for i = 1, net.ReadUInt(10) do
		links[i] = { a = net.ReadVector() + UP, b = net.ReadVector() + UP, kind = net.ReadUInt(3) }
	end
	V.linkA = net.ReadBool() and net.ReadVector() or nil
	V.nodes, V.squares, V.edges, V.links = nodes, squares, edges, links
	V.until_ = CurTime() + 2
end)

local BLUE, WHITE, RED = Color(0, 170, 255), Color(255, 255, 255), Color(255, 60, 60)
local FILL, OUTLINE = Color(0, 170, 255, 28), Color(120, 210, 255, 70)
-- Link colours by kind (Nav.KindCode): drop, gap jump, jump up, climb.
local LINK_COLOR = { Color(255, 210, 0), Color(60, 255, 90), Color(255, 130, 0), Color(200, 90, 255) }

local function holdingTool()
	local ply = LocalPlayer()
	local w = IsValid(ply) and ply:GetActiveWeapon()
	if not (IsValid(w) and w:GetClass() == "gmod_tool") then return false end
	local t = ply:GetTool()
	return t and t.Mode == "ngl_nav"
end

hook.Add("PostDrawTranslucentRenderables", "NGL.NavView", function(depth, sky)
	if sky or CurTime() > V.until_ or not holdingTool() then return end
	local nodes, edges = V.nodes, V.edges
	render.SetColorMaterial()
	for _, q in ipairs(V.squares) do
		local a, b, c, d = nodes[q[1]], nodes[q[2]], nodes[q[3]], nodes[q[4]]
		if a and b and c and d then
			render.DrawQuad(a, b, c, d, FILL)
			render.DrawQuad(a, d, c, b, FILL) -- seen from below too
			render.DrawLine(a, b, OUTLINE, true)
			render.DrawLine(b, c, OUTLINE, true)
			render.DrawLine(c, d, OUTLINE, true)
			render.DrawLine(d, a, OUTLINE, true)
		end
	end
	for k = 1, #edges, 2 do
		local a, b = nodes[edges[k]], nodes[edges[k + 1]]
		if a and b then render.DrawLine(a, b, BLUE, true) end
	end
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
		if mode == "link" or mode == "climb" then r = 24 end
		local prev
		for i = 0, 24 do
			local a = i / 24 * math.pi * 2
			local p = tr.HitPos + Vector(math.cos(a) * r, math.sin(a) * r, 4)
			if prev then render.DrawLine(prev, p, WHITE, false) end
			prev = p
		end
	end
end)
