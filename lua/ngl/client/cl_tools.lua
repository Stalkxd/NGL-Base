-- Client side of the NGL NPC Tracker and NGL NPC Mover tools (see
-- sv_tools.lua): what tracked NPCs are doing and where they're going, and
-- rings under the NPCs picked with the mover.
NGL.ToolView = NGL.ToolView or { track = {}, trackUntil = 0, selected = {} }
local V = NGL.ToolView

local cvAlways = CreateClientConVar("ngl_track_always", "0", true, false,
	"Show NPCs tracked with the NGL NPC Tracker even when not holding the tool.", 0, 1)

local TRAIL_LEN = 50 -- positions kept per NPC (10 s at 5 a second)

net.Receive("ngl_track", function()
	local old = V.track
	local track = {}
	for _ = 1, net.ReadUInt(4) do
		local t = { id = net.ReadUInt(16), pos = net.ReadVector(), state = net.ReadString() }
		if net.ReadBool() then t.jumpTo = net.ReadVector() end
		t.pts, t.moves = {}, {}
		for k = 1, net.ReadUInt(6) do
			t.pts[k] = net.ReadVector()
			t.moves[k] = net.ReadUInt(2)
		end
		if net.ReadBool() then t.orderPos = net.ReadVector() end
		-- Where it has been: kept here, nothing extra sent.
		local prev = old[t.id]
		t.trail = prev and prev.trail or {}
		local last = t.trail[#t.trail]
		if not last or last:DistToSqr(t.pos) > 4 then
			t.trail[#t.trail + 1] = t.pos
			if #t.trail > TRAIL_LEN then table.remove(t.trail, 1) end
		end
		track[t.id] = t
	end
	V.track = track
	V.trackUntil = CurTime() + 1
end)

net.Receive("ngl_move_sel", function()
	local sel = {}
	for _ = 1, net.ReadUInt(6) do sel[#sel + 1] = net.ReadUInt(16) end
	V.selected = sel
end)

local function toolMode()
	local ply = LocalPlayer()
	local w = IsValid(ply) and ply:GetActiveWeapon()
	if not (IsValid(w) and w:GetClass() == "gmod_tool") then return nil end
	local t = ply:GetTool()
	return t and t.Mode
end

local function showTrack()
	return CurTime() < V.trackUntil and (cvAlways:GetBool() or toolMode() == "ngl_track")
end

local PATH, TRAIL, GOAL, ORDER = Color(0, 220, 255), Color(255, 255, 255, 90), Color(60, 255, 90), Color(255, 80, 200)
local MOVE_COLOR = { Color(255, 210, 0), Color(255, 130, 0), Color(200, 90, 255) } -- jump, up, climb
local SEL = Color(60, 255, 90)
local UP = Vector(0, 0, 4)

local function ring(pos, r, col)
	local prev
	for i = 0, 16 do
		local a = i / 16 * math.pi * 2
		local p = pos + Vector(math.cos(a) * r, math.sin(a) * r, 3)
		if prev then render.DrawLine(prev, p, col, false) end
		prev = p
	end
end

hook.Add("PostDrawTranslucentRenderables", "NGL.ToolView", function(depth, _, sky) -- 3D skybox pass (the 2nd is true on maps without one)
	if sky then return end
	if showTrack() then
		render.SetColorMaterial()
		for id, t in pairs(V.track) do
			local ent = Entity(id)
			local pos = IsValid(ent) and ent:GetPos() or t.pos
			-- Where it has been.
			local tr = t.trail
			for k = 2, #tr do render.DrawLine(tr[k - 1] + UP, tr[k] + UP, TRAIL, true) end
			-- Where it's going: path points, jumps in their colours.
			local prev = pos + UP
			if t.jumpTo then
				render.DrawLine(prev, t.jumpTo + UP, MOVE_COLOR[1], false)
				prev = t.jumpTo + UP
			end
			for k, p in ipairs(t.pts) do
				local q = p + UP
				local m = t.moves[k - 1]
				local col = (k > 1 and m and m > 0) and MOVE_COLOR[m] or PATH
				render.DrawLine(prev, q, col, false)
				render.DrawWireframeBox(q, angle_zero, Vector(-3, -3, 0), Vector(3, 3, 6), col, false)
				prev = q
			end
			if #t.pts > 0 then ring(t.pts[#t.pts], 16, GOAL) end
			if t.orderPos then ring(t.orderPos, 28, ORDER) end
		end
	end
	if toolMode() == "ngl_move" then
		render.SetColorMaterial()
		for _, id in ipairs(V.selected) do
			local e = Entity(id)
			if IsValid(e) then ring(e:GetPos(), 24, SEL) end
		end
	end
end)

hook.Add("HUDPaint", "NGL.ToolView", function()
	if not showTrack() then return end
	for id, t in pairs(V.track) do
		local ent = Entity(id)
		local pos = (IsValid(ent) and ent:GetPos() or t.pos) + Vector(0, 0, 84)
		local s = pos:ToScreen()
		if s.visible then
			draw.SimpleTextOutlined(t.state, "DermaDefault", s.x, s.y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
		end
	end
end)
