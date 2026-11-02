-- Draws the NGL nav grid round the player while the NGL Nav Editor tool is
-- out (the server sends it, see sv_nav_edit.lua), and the tool's circle.
NGL.NavView = NGL.NavView or { nodes = {}, edges = {}, links = {}, until_ = 0 }
local V = NGL.NavView

net.Receive("ngl_nav_view", function()
	local nodes, edges, links = {}, {}, {}
	for i = 1, net.ReadUInt(12) do nodes[i] = net.ReadVector() + Vector(0, 0, 3) end
	for i = 1, net.ReadUInt(14) * 2 do edges[i] = net.ReadUInt(12) end
	for i = 1, net.ReadUInt(10) do
		links[i] = { a = net.ReadVector() + Vector(0, 0, 3), b = net.ReadVector() + Vector(0, 0, 3), jump = net.ReadBool() }
	end
	V.linkA = net.ReadBool() and net.ReadVector() or nil
	V.nodes, V.edges, V.links = nodes, edges, links
	V.until_ = CurTime() + 2
end)

local BLUE, YELLOW, GREEN, WHITE, RED = Color(0, 170, 255), Color(255, 210, 0), Color(60, 255, 90), Color(255, 255, 255), Color(255, 60, 60)

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
	for k = 1, #edges, 2 do
		local a, b = nodes[edges[k]], nodes[edges[k + 1]]
		if a and b then render.DrawLine(a, b, BLUE, true) end
	end
	for _, L in ipairs(V.links) do
		local c = L.jump and GREEN or YELLOW
		render.DrawLine(L.a, L.b, c, false)
		render.DrawWireframeBox(L.b, angle_zero, Vector(-4, -4, 0), Vector(4, 4, 8), c, false)
	end
	if V.linkA then render.DrawWireframeSphere(V.linkA, 12, 8, 8, RED, false) end
	-- The tool's circle where we aim.
	local ply = LocalPlayer()
	local tr = ply:GetEyeTrace()
	if tr.Hit then
		local r = GetConVarNumber("ngl_nav_radius")
		if GetConVarString("ngl_nav_mode") == "link" then r = 24 end
		local prev
		for i = 0, 24 do
			local a = i / 24 * math.pi * 2
			local p = tr.HitPos + Vector(math.cos(a) * r, math.sin(a) * r, 4)
			if prev then render.DrawLine(prev, p, WHITE, false) end
			prev = p
		end
	end
end)
