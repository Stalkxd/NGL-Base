-- Draws NGL projectiles (see sv_projectile.lua). The server sends one
-- message when a projectile is fired and one when it lands; in between the
-- client moves it on its own, so flight costs no network traffic.

local list = {}
local glow = Material("sprites/light_glow02_add")
local glowColor = Color(255, 200, 120)

local function kill(id)
	local p = list[id]
	if not p then return end
	if IsValid(p.ent) then p.ent:Remove() end
	list[id] = nil
end

net.Receive("ngl_proj", function()
	local id = net.ReadUInt(16)
	local pos = net.ReadVector()
	local vel = net.ReadVector()
	local g = net.ReadFloat()
	local model = net.ReadString()
	local life = net.ReadFloat()

	kill(id)
	local p = { pos = pos, vel = vel, g = g, die = CurTime() + life + 0.5 }
	if model ~= "" then
		local ent = ClientsideModel(model, RENDERGROUP_OPAQUE)
		if IsValid(ent) then
			ent:SetPos(pos)
			ent:SetAngles(vel:Angle())
			p.ent = ent
		end
	end
	list[id] = p
end)

net.Receive("ngl_proj_end", function()
	kill(net.ReadUInt(16))
end)

hook.Add("Think", "NGL.Proj", function()
	if next(list) == nil then return end
	local dt = FrameTime()
	local now = CurTime()
	for id, p in pairs(list) do
		if now > p.die then
			kill(id)
		else
			local vel = p.vel
			if p.g ~= 0 then vel.z = vel.z - p.g * dt end
			p.pos = p.pos + vel * dt
			if IsValid(p.ent) then
				p.ent:SetPos(p.pos)
				p.ent:SetAngles(vel:Angle())
			end
		end
	end
end)

hook.Add("PostDrawTranslucentRenderables", "NGL.Proj", function(depth, skybox)
	if skybox or next(list) == nil then return end
	render.SetMaterial(glow)
	for _, p in pairs(list) do
		if not p.ent then render.DrawSprite(p.pos, 24, 24, glowColor) end
	end
end)
