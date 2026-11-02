-- Combine dropship: brings reinforcements to a squad leader (sv_reinforce.lua).
-- Not a NextBot (those walk): a scripted entity that flies itself along the
-- air layer (sv_air.lua) from the edge of the sky to a checked landing spot,
-- hovers low while the soldiers jump out one by one into the leader's squad,
-- then climbs and leaves the way it came. There are only ever a few of them
-- (ngl_dropship_max), so moving them every tick is cheap.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Combine Dropship (NGL)"
ENT.Spawnable = false

ENT.Model = "models/combine_dropship.mdl"
ENT.Speed = 900          -- cruise speed
ENT.TurnRate = 70        -- degrees per second
ENT.HoverHeight = 180    -- height above the ground while unloading
ENT.ClimbSpeed = 260
ENT.DropDelay = 0.6      -- seconds between soldiers jumping out
ENT.MaxLife = 150        -- removed after this long whatever happens
ENT.StartHealth = 1500   -- only with ngl_dropship_vulnerable 1
ENT.EngineSound = "NPC_CombineDropship.RotorLoop"

if CLIENT then return end

local cvVulnerable = CreateConVar("ngl_dropship_vulnerable", "0", FCVAR_ARCHIVE,
	"1 = NGL dropships can be shot down (rockets and explosives do full damage, bullets a fifth).", 0, 1)

local CurTime, IsValid = CurTime, IsValid
local clamp = math.Clamp

function ENT:Initialize()
	self:SetModel(self.Model)
	self:SetMoveType(MOVETYPE_NOCLIP)
	self:SetSolid(SOLID_BBOX)
	self:SetHealth(self.StartHealth)
	self.NGLState = "idle"
	self.NGLBorn = CurTime()
	if self.EngineSound then
		self.NGLEngine = CreateSound(self, self.EngineSound)
		if self.NGLEngine then self.NGLEngine:Play() end
	end
end

-- trip = { entry, landing (ground pos), hover (air pos above it), enemyPos,
--          leader, squad, cargo (class), count }
function ENT:NGLStartTrip(trip)
	self.Trip = trip
	local path = NGL.Air.Path(trip.entry, trip.hover) or {}
	path[#path + 1] = trip.hover
	self.NGLPath, self.NGLIdx = path, 1
	self.NGLState = "inbound"
	self:NextThink(CurTime())
end

-- Velocity plus a nose that turns into the flight direction and banks.
function ENT:NGLFly(vel, dt)
	self:SetLocalVelocity(vel)
	local ang = self:GetAngles()
	local speed = vel:Length2D()
	if speed > 30 then
		local want = vel:Angle().y
		local diff = math.AngleDifference(want, ang.y)
		local step = self.TurnRate * dt
		ang.y = ang.y + clamp(diff, -step, step)
		ang.r = clamp(-diff * 0.4, -25, 25)
		ang.p = clamp(speed / self.Speed * 10, 0, 10)
	else
		ang.r, ang.p = ang.r * 0.9, ang.p * 0.9
	end
	self:SetAngles(ang)
end

-- Follow NGLPath; true once the last point is reached.
function ENT:NGLFollow(dt, slowAtEnd)
	local path = self.NGLPath
	local wp = path[self.NGLIdx]
	if not wp then return true end
	local pos = self:GetPos()
	local to = wp - pos
	local d = to:Length()
	local last = self.NGLIdx == #path
	if d < (last and 48 or 260) then
		self.NGLIdx = self.NGLIdx + 1
		return self.NGLIdx > #path
	end
	local speed = self.Speed
	if last and slowAtEnd then speed = math.min(speed, 80 + d * 0.9) end
	self:NGLFly(to * (speed / d), dt)
	return false
end

function ENT:NGLDropOne()
	local T = self.Trip
	local k = self.NGLDropped
	local ang = k * 2.4 -- spread them around the landing spot
	local p = T.landing + Vector(math.cos(ang) * (90 + 20 * (k % 3)), math.sin(ang) * (90 + 20 * (k % 3)), 8)
	local sq = T.squad
	local leader = IsValid(T.leader) and not T.leader.NGLDying and T.leader or nil
	local e = NGL.Reinforce.Spawn(T.cargo, p, leader, leader and sq or nil, self:GetAngles().y)
	if IsValid(e) and leader and e.MoveTo then e:MoveTo(leader:GetPos(), true) end
	self.NGLDropped = k + 1
end

function ENT:Think()
	local now = CurTime()
	local dt = engine.TickInterval()
	local st = self.NGLState
	local T = self.Trip

	if now - self.NGLBorn > self.MaxLife then
		self:Remove()
		return
	end

	if st == "inbound" then
		if self:NGLFollow(dt, true) then self.NGLState = "descend" end

	elseif st == "descend" then
		local pos = self:GetPos()
		local target = T.landing + Vector(0, 0, self.HoverHeight)
		local dz = target.z - pos.z
		if math.abs(dz) < 16 then
			self:SetLocalVelocity(vector_origin)
			self.NGLState = "unload"
			self.NGLNextDrop = now + 1
			self.NGLDropped = 0
		else
			local v = Vector((target.x - pos.x) * 2, (target.y - pos.y) * 2, clamp(dz * 1.5, -self.ClimbSpeed, self.ClimbSpeed))
			self:NGLFly(v, dt)
		end

	elseif st == "unload" then
		self:SetLocalVelocity(vector_origin)
		if now >= self.NGLNextDrop then
			if self.NGLDropped < (T.count or 6) then
				self:NGLDropOne()
				self.NGLNextDrop = now + self.DropDelay
			else
				self.NGLState = "ascend"
			end
		end

	elseif st == "ascend" then
		local pos = self:GetPos()
		local dz = T.hover.z - pos.z
		if dz < 24 then
			local exit = NGL.Air.EntryPoint(T.hover, T.enemyPos) or T.entry
			local path = NGL.Air.Path(T.hover, exit) or {}
			path[#path + 1] = exit
			self.NGLPath, self.NGLIdx = path, 1
			self.NGLState = "outbound"
		else
			self:NGLFly(Vector(0, 0, self.ClimbSpeed), dt)
		end

	elseif st == "outbound" then
		if self:NGLFollow(dt, false) then
			self:Remove()
			return
		end
	end

	self:NextThink(now)
	return true
end

function ENT:OnTakeDamage(dmg)
	if not cvVulnerable:GetBool() or self.NGLDead then return 0 end
	local amount = dmg:GetDamage()
	if dmg:IsBulletDamage() then amount = amount * 0.2 end
	self:SetHealth(self:Health() - amount)
	if self:Health() <= 0 then
		self.NGLDead = true
		local pos = self:WorldSpaceCenter()
		local ed = EffectData()
		ed:SetOrigin(pos)
		util.Effect("Explosion", ed)
		util.BlastDamage(self, IsValid(dmg:GetAttacker()) and dmg:GetAttacker() or self, pos, 400, 120)
		self:Remove()
	end
	return amount
end

function ENT:OnRemove()
	if self.NGLEngine then self.NGLEngine:Stop() end
	if NGL.Reinforce then NGL.Reinforce.Active[self] = nil end
end
