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
	local now = CurTime()
	local p = { pos = pos, vel = vel, g = g, die = now + life + 0.5 }
	if net.ReadBool() then -- homing: steer the same way the server does
		p.lit = now + net.ReadFloat()
		p.turn, p.speed, p.accel = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
		p.dst = net.ReadVector()
		p.target = net.ReadEntity()
		p.trail = net.ReadBool()
	end
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

local function steer(vel, from, goal, turn, speed, accel, dt)
	local cur = vel:Length()
	local dir = vel / math.max(cur, 0.001)
	local want = goal - from
	want:Normalize()
	local a = math.acos(math.Clamp(dir:Dot(want), -1, 1))
	local step = math.rad(turn) * dt
	if a > step and a > 1e-4 then
		local s = math.sin(a)
		dir = dir * (math.sin(a - step) / s) + want * (math.sin(step) / s)
	else
		dir = want
	end
	cur = cur < speed and math.min(speed, cur + accel * dt) or speed
	return dir * cur
end

local emitter
local function smoke(p, now)
	if now < (p.nextPuff or 0) then return end
	p.nextPuff = now + 0.02
	emitter = emitter or ParticleEmitter(p.pos)
	if not emitter then return end
	local part = emitter:Add("particle/smokesprites_000" .. math.random(1, 9), p.pos)
	if part then
		part:SetVelocity(VectorRand() * 10)
		part:SetDieTime(1.2)
		part:SetStartAlpha(120)
		part:SetEndAlpha(0)
		part:SetStartSize(6)
		part:SetEndSize(28)
		part:SetRoll(math.Rand(0, 360))
		part:SetColor(180, 180, 180)
	end
end

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
			if p.lit and now >= p.lit then
				local t = p.target
				local goal = IsValid(t) and t:WorldSpaceCenter() or p.dst
				vel = steer(vel, p.pos, goal, p.turn, p.speed, p.accel, dt)
				p.vel = vel
				if p.trail then smoke(p, now) end
			end
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
