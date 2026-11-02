-- Combine dropship: brings reinforcements to a squad leader (sv_reinforce.lua).
-- Not a NextBot (those walk): a scripted entity that flies itself along the
-- air layer (sv_air.lua) from the edge of the sky to a checked landing spot,
-- sets its troop pod down, opens it and lets the soldiers climb out one by
-- one into the leader's squad (or sets down the APC it carries under it),
-- then climbs and leaves the way it came. The pod's gun fires at enemies
-- near the ship. There are only ever a few of them (ngl_dropship_max), so
-- moving them every tick is cheap.
--
-- Animations, pose parameters, attachments and sounds are the ones HL2's
-- npc_combinedropship uses, so the stock models look and sound as in HL2.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Combine Dropship (NGL)"
ENT.Spawnable = false
ENT.AutomaticFrameAdvance = true

ENT.Model = "models/combine_dropship.mdl"
ENT.PodModel = "models/combine_dropship_container.mdl" -- troop pod with a gun; false for none
ENT.Speed = 900          -- cruise speed
ENT.TurnRate = 70        -- degrees per second
ENT.HoverHeight = 180    -- ship height above the ground while unloading without a pod
ENT.PodHoverHeight = 60  -- ...with the pod: the pod stands on the ground
ENT.ClimbSpeed = 260
ENT.DeploySequence = "Dropship_Deploy" -- soldiers' climb-out animation (HL2 Combine models)
ENT.DropDelay = 0.6      -- seconds between soldiers when there is no climb-out animation
ENT.MaxLife = 150        -- removed after this long whatever happens
ENT.StartHealth = 1500   -- only with ngl_dropship_vulnerable 1

-- Pod gun (HL2: 5 damage, bursts of 10-20 rounds, 20 a second).
ENT.Gun = {
	Range = 2000,
	Damage = 5,
	Delay = 0.05,
	Burst = { 10, 20 },
	Spread = 0.035,       -- about 2 degrees
	TurnSpeed = 180,      -- degrees per second
	Tracer = "HelicopterTracer",
	Muzzle = "ChopperMuzzleFlash",
}

-- Carrying a vehicle: until it is set down it is only a model hanging under
-- the ship (no NPC, no thinking); the real NPC is created on the ground.
-- HL2 hangs the APC 25 units under the ship, turned 90 degrees (Source
-- vehicle models face +Y).
ENT.CarryOffset = Vector(0, 0, -25)
ENT.CarryYaw = -90
ENT.CarryHoverHeight = 70  -- ship height above the ground when setting it down
ENT.CarryReleaseTime = 1.5 -- seconds on the ground before climbing away

-- Sounds (HL2 files; played on clients, faded by distance like HL2 does).
local SND = "npc/combine_gunship/"
ENT.Sounds = {
	Far = SND .. "dropship_engine_distant_loop1.wav",
	Near = SND .. "dropship_engine_near_loop1.wav",
	Ground = SND .. "dropship_onground_loop1.wav",
	Descend = SND .. "dropship_dropping_pod_loop1.wav",
	Fire = SND .. "gunship_fire_loop1.wav",
}

-- Phase, for clients: 0 flying, 1 coming down, 2 on the ground, 3 going up.
local PH_FLY, PH_DOWN, PH_GROUND, PH_UP = 0, 1, 2, 3

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Phase")
	self:NetworkVar("Bool", 0, "Firing")
end

if CLIENT then
	local NEAR_MIN, NEAR_MAX = 1000, 2500 -- HL2's near/far crossfade

	local function loop(self, key, level)
		local path = self.Sounds[key]
		if not path then return nil end
		local s = CreateSound(self, path)
		s:SetSoundLevel(level)
		s:PlayEx(0, 100)
		return s
	end

	function ENT:Initialize()
		self.NGLLoops = {
			Far = loop(self, "Far", 140),
			Near = loop(self, "Near", 100),
			Ground = loop(self, "Ground", 90),
			Descend = loop(self, "Descend", 95),
			Fire = loop(self, "Fire", 100),
		}
	end

	function ENT:Think()
		local L = self.NGLLoops
		if not L then return end
		local d = EyePos():Distance(self:GetPos())
		local near = 1 - math.Clamp((d - NEAR_MIN) / (NEAR_MAX - NEAR_MIN), 0, 1)
		local phase = self:GetPhase()
		local ground = phase == PH_GROUND
		local thrust = ground and 0.4 or 1
		local function vol(s, v) if s then s:ChangeVolume(v, 0.3) end end
		vol(L.Far, thrust * (1 - near))
		vol(L.Near, thrust * near)
		vol(L.Ground, ground and near or 0)
		vol(L.Descend, phase == PH_DOWN and near * 0.8 or 0)
		vol(L.Fire, self:GetFiring() and 1 or 0)
		self:SetNextClientThink(CurTime() + 0.2)
		return true
	end

	function ENT:OnRemove()
		for _, s in pairs(self.NGLLoops or {}) do s:Stop() end
	end
	return
end

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
	self.NGLDeploying = {}
	self.NGLNextShot, self.NGLBurst, self.NGLNextTarget = 0, 0, 0
	-- The model's sequences by activity name (HL2's are private activities,
	-- so there are no ACT_ numbers for them in Lua).
	self.NGLActSeq = {}
	for i = 0, (self:GetSequenceCount() or 1) - 1 do
		local name = self:GetSequenceActivityName(i)
		if name and name ~= "" and not self.NGLActSeq[name] then self.NGLActSeq[name] = i end
	end
	self.NGLPoses = {}
	for _, p in ipairs({ "body_accel", "body_sway", "cargo_body_accel", "cargo_body_sway" }) do
		if self:LookupPoseParameter(p) >= 0 then self.NGLPoses[p] = true end
	end
	self.NGLLastVel = Vector(0, 0, 0)
	self:SetPhase(PH_FLY)
end

-- Plays the sequence of one of the dropship's activities (looping).
function ENT:NGLAnim(actName)
	local seq = self.NGLActSeq[actName] or self.NGLActSeq.ACT_DROPSHIP_FLY_IDLE or self:LookupSequence("idle")
	if seq and seq >= 0 and seq ~= self.NGLSeq then
		self.NGLSeq = seq
		self:ResetSequence(seq)
	end
end

function ENT:NGLCarrying() return IsValid(self.NGLPod) or IsValid(self.NGLCarried) end

-- trip = { entry, landing (ground pos), hover (air pos above it), enemyPos,
--          leader, squad, cargo (class), count, vehicle (class or nil) }
function ENT:NGLStartTrip(trip)
	self.Trip = trip
	local path = NGL.Air.Path(trip.entry, trip.hover) or {}
	path[#path + 1] = trip.hover
	self.NGLPath, self.NGLIdx = path, 1
	self.NGLState = "inbound"
	if trip.vehicle then
		self:NGLHang(trip.vehicle)
	elseif self.PodModel and (trip.count or 0) > 0 then
		self:NGLAttachPod()
	end
	self:NGLAnim(self:NGLCarrying() and "ACT_DROPSHIP_FLY_IDLE_CARGO" or "ACT_DROPSHIP_FLY_IDLE_EXAGG")
	self:NextThink(CurTime())
end

-- The troop pod, parented to the ship (HL2 puts it at the ship's origin).
function ENT:NGLAttachPod()
	local p = ents.Create("prop_dynamic")
	if not IsValid(p) then return end
	p:SetModel(self.PodModel)
	p:SetPos(self:GetPos())
	p:SetAngles(self:GetAngles())
	p:SetParent(self)
	p:Spawn()
	p:SetSolid(SOLID_NONE)
	self.NGLPod = p
	local function att(name) local id = p:LookupAttachment(name); return id and id > 0 and id or nil end
	self.NGLPodAtt = {
		start = att("Deploy_Start"), land = att("deploy_landpoint"),
		muzzle = att("muzzle"), base = att("gun_base"),
	}
	local function pose(name) return p:LookupPoseParameter(name) >= 0 and name or nil end
	self.NGLGunYaw, self.NGLGunPitch = pose("weapon_yaw"), pose("weapon_pitch")
	self.NGLAimYaw, self.NGLAimPitch = 0, 0
	self:NGLPodSequence("close_idle")
end

function ENT:NGLPodSequence(name)
	local p = self.NGLPod
	if not IsValid(p) then return end
	local seq = p:LookupSequence(name)
	if seq and seq >= 0 then p:ResetSequence(seq) end
end

-- The model of the carried vehicle, parented under the ship.
function ENT:NGLHang(class)
	local t = scripted_ents.Get(class)
	local mdl = t and t.Model
	if not mdl then return end
	local p = ents.Create("prop_dynamic")
	if not IsValid(p) then return end
	p:SetModel(mdl)
	p:SetPos(self:LocalToWorld(self.CarryOffset))
	local a = self:GetAngles()
	p:SetAngles(Angle(0, a.y + self.CarryYaw, 0))
	p:SetParent(self)
	p:Spawn()
	p:SetSolid(SOLID_NONE)
	self.NGLCarried = p
end

-- Sets the vehicle down: the hanging model goes, the real NPC appears on the
-- ground (turned the same way as the hanging model) and takes the leader's
-- orders.
function ENT:NGLDropVehicle()
	local T = self.Trip
	local yaw = self:GetAngles().y + self.CarryYaw
	if IsValid(self.NGLCarried) then self.NGLCarried:Remove() end
	self.NGLCarried = nil
	self:SetNotSolid(true) -- don't trap the vehicle in the ship's box
	local leader = IsValid(T.leader) and not T.leader.NGLDying and T.leader or nil
	local R = NGL.Reinforce
	local v = R.Spawn(T.vehicle, T.landing + Vector(0, 0, 8), leader, nil, yaw)
	if IsValid(v) and leader then
		R.AttachVehicle(v, leader, T.squad)
		if v.MoveTo then v:MoveTo(leader:GetPos(), false) end
	end
	self.NGLVehicleOut = true
end

-- One soldier climbs out of the pod: created inside it (Deploy_Start), plays
-- the climb-out animation while we slide it to the landing point, then
-- joins the squad. Without a pod or the animation it appears on the ground.
-- Returns seconds until the next one may go.
function ENT:NGLDropOne()
	local T = self.Trip
	local k = self.NGLDropped
	self.NGLDropped = k + 1
	local sq = T.squad
	local leader = IsValid(T.leader) and not T.leader.NGLDying and T.leader or nil
	local R = NGL.Reinforce
	local pod, A = self.NGLPod, self.NGLPodAtt
	if IsValid(pod) and A and A.start and A.land then
		local s = pod:GetAttachment(A.start)
		local l = pod:GetAttachment(A.land)
		if s and l then
			local land = Vector(l.Pos.x, l.Pos.y, T.landing.z + 4)
			local e = R.Spawn(T.cargo, s.Pos, leader, leader and sq or nil, s.Ang.y)
			if not IsValid(e) then return self.DropDelay end
			local dur = e.PlayAnim and e:PlayAnim(self.DeploySequence, true)
			if dur then
				self.NGLDeploying[e] = { from = s.Pos, to = land, t0 = CurTime(), dur = dur, leader = leader }
				return dur * 0.7
			end
			e:SetPos(land)
			if leader and e.MoveTo then e:MoveTo(leader:GetPos(), true) end
			return self.DropDelay
		end
	end
	local ang = k * 2.4 -- spread them around the landing spot
	local p = T.landing + Vector(math.cos(ang) * (90 + 20 * (k % 3)), math.sin(ang) * (90 + 20 * (k % 3)), 8)
	local e = R.Spawn(T.cargo, p, leader, leader and sq or nil, self:GetAngles().y)
	if IsValid(e) and leader and e.MoveTo then e:MoveTo(leader:GetPos(), true) end
	return self.DropDelay
end

-- Slides climbing soldiers along their path; lets them go when done.
function ENT:NGLUpdateDeploying(now)
	for e, d in pairs(self.NGLDeploying) do
		if not IsValid(e) or e.NGLDying then
			self.NGLDeploying[e] = nil
		else
			local f = math.min((now - d.t0) / d.dur, 1)
			e:SetPos(LerpVector(f, d.from, d.to))
			if e.loco then e.loco:SetVelocity(vector_origin) end
			if f >= 1 then
				self.NGLDeploying[e] = nil
				if IsValid(d.leader) and e.MoveTo then e:MoveTo(d.leader:GetPos(), true) end
			end
		end
	end
end

-- Pod gun ------------------------------------------------------------------

local function hostileTo(leader, e)
	return IsValid(e) and not e.NGLDying and e:Health() > 0 and NGL.Core.IsHostile(leader, e)
end

local gunTrace = { mask = MASK_SOLID_BRUSHONLY }
local gunResult = {}
gunTrace.output = gunResult

-- The leader's enemy if close enough, else the nearest hostile in range;
-- only if the gun can see it.
function ENT:NGLGunTarget(now, muzzle)
	if now < self.NGLNextTarget then return self.NGLTarget end
	self.NGLNextTarget = now + 0.5
	local leader = self.Trip and self.Trip.leader
	if not (IsValid(leader) and not leader.NGLDying) then self.NGLTarget = nil return nil end
	local range = self.Gun.Range
	local rSqr = range * range
	local best, bestD
	local e = leader.NGLEnemy
	if hostileTo(leader, e) and muzzle:DistToSqr(e:GetPos()) < rSqr then
		best = e
	else
		for _, c in ipairs(NGL.FindInRadius(muzzle, range, function(c) return hostileTo(leader, c) end)) do
			local d = muzzle:DistToSqr(c:GetPos())
			if not bestD or d < bestD then best, bestD = c, d end
		end
		for _, ply in ipairs(player.GetAll()) do
			if hostileTo(leader, ply) then
				local d = muzzle:DistToSqr(ply:GetPos())
				if d < rSqr and (not bestD or d < bestD) then best, bestD = ply, d end
			end
		end
	end
	if best then
		gunTrace.start, gunTrace.endpos = muzzle, best:WorldSpaceCenter()
		util.TraceLine(gunTrace)
		if gunResult.Hit then best = nil end
	end
	self.NGLTarget = best
	return best
end

function ENT:NGLGunThink(now, dt)
	local pod, A, G = self.NGLPod, self.NGLPodAtt, self.Gun
	if not (G and IsValid(pod) and A and A.muzzle) then
		if self:GetFiring() then self:SetFiring(false) end
		return
	end
	local m = pod:GetAttachment(A.muzzle)
	if not m then return end
	local target = self:NGLGunTarget(now, m.Pos)
	if not IsValid(target) then
		if self:GetFiring() then self:SetFiring(false) end
		return
	end
	local aim = target:WorldSpaceCenter()
	-- Turn the gun (pose parameters, in degrees, relative to the pod).
	local base = A.base and pod:GetAttachment(A.base)
	local origin = base and base.Pos or m.Pos
	local loc = WorldToLocal(aim, Angle(0, 0, 0), origin, pod:GetAngles())
	local wantYaw = math.deg(math.atan2(loc.y, loc.x))
	local wantPitch = -math.deg(math.atan2(loc.z, math.sqrt(loc.x * loc.x + loc.y * loc.y)))
	local step = G.TurnSpeed * dt
	self.NGLAimYaw = self.NGLAimYaw + clamp(math.AngleDifference(wantYaw, self.NGLAimYaw), -step, step)
	self.NGLAimPitch = self.NGLAimPitch + clamp(wantPitch - self.NGLAimPitch, -step, step)
	if self.NGLGunYaw then pod:SetPoseParameter(self.NGLGunYaw, self.NGLAimYaw) end
	if self.NGLGunPitch then pod:SetPoseParameter(self.NGLGunPitch, self.NGLAimPitch) end
	local onTarget = math.abs(math.AngleDifference(wantYaw, self.NGLAimYaw)) < 15

	if not onTarget or now < self.NGLNextShot then
		if not onTarget and self:GetFiring() then self:SetFiring(false) end
		return
	end
	if self.NGLBurst <= 0 then
		self.NGLBurst = math.random(G.Burst[1], G.Burst[2])
		self.NGLNextShot = now + self.NGLBurst * 0.1 -- pause as long as the next burst
		self:SetFiring(false)
		return
	end
	self.NGLBurst = self.NGLBurst - 1
	self.NGLNextShot = now + G.Delay
	if not self:GetFiring() then self:SetFiring(true) end
	local dir = aim - m.Pos
	dir:Normalize()
	pod:FireBullets({
		Attacker = self, Inflictor = self,
		Src = m.Pos, Dir = dir, Spread = Vector(G.Spread, G.Spread, 0),
		Num = 1, Damage = G.Damage, Force = 4, Tracer = 1, TracerName = G.Tracer,
		IgnoreEntity = self,
	})
	if G.Muzzle then
		local ed = EffectData()
		ed:SetEntity(pod)
		ed:SetAttachment(A.muzzle)
		ed:SetOrigin(m.Pos)
		ed:SetAngles(dir:Angle())
		ed:SetScale(1)
		util.Effect(G.Muzzle, ed)
	end
end

-- Flight -------------------------------------------------------------------

-- Velocity plus a nose that turns into the flight direction and banks, and
-- the body_accel / body_sway poses HL2 uses to lean the hull.
function ENT:NGLFly(vel, dt)
	self:SetLocalVelocity(vel)
	local ang = self:GetAngles()
	local speed = vel:Length2D()
	local diff = 0
	if speed > 30 then
		local want = vel:Angle().y
		diff = math.AngleDifference(want, ang.y)
		local step = self.TurnRate * dt
		ang.y = ang.y + clamp(diff, -step, step)
		ang.r = clamp(-diff * 0.4, -25, 25)
		ang.p = clamp(speed / self.Speed * 10, 0, 10)
	else
		ang.r, ang.p = ang.r * 0.9, ang.p * 0.9
	end
	self:SetAngles(ang)
	self:NGLLean(vel, dt, diff)
end

function ENT:NGLLean(vel, dt, turn)
	local P = self.NGLPoses
	if not next(P) then return end
	local accel = (vel - self.NGLLastVel):Dot(self:GetForward()) / math.max(dt, 0.001)
	self.NGLLastVel = vel
	local cargo = self:NGLCarrying()
	local function set(name, v)
		if not P[name] then return end
		local lo, hi = self:GetPoseParameterRange(self:LookupPoseParameter(name))
		local want = v >= 0 and v * (hi or 1) or -v * (lo or -1)
		local cur = P[name] == true and 0 or P[name]
		cur = cur + (want - cur) * math.min(dt * 3, 1)
		P[name] = cur
		self:SetPoseParameter(name, cur)
	end
	set(cargo and "cargo_body_accel" or "body_accel", clamp(accel / 300, -1, 1)) -- HL2's DROPSHIP_ACCEL_RATE
	set(cargo and "cargo_body_sway" or "body_sway", clamp((turn or 0) / 45, -1, 1))
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

function ENT:NGLHoverHeight()
	if self.Trip.vehicle then return self.CarryHoverHeight end
	return IsValid(self.NGLPod) and self.PodHoverHeight or self.HoverHeight
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
		if self:NGLFollow(dt, true) then
			self.NGLState = "descend"
			self:SetPhase(PH_DOWN)
			self:NGLAnim("ACT_DROPSHIP_DESCEND_IDLE")
		end

	elseif st == "descend" then
		local pos = self:GetPos()
		local target = T.landing + Vector(0, 0, self:NGLHoverHeight())
		local dz = target.z - pos.z
		if math.abs(dz) < 12 then
			self:SetLocalVelocity(vector_origin)
			self:SetAngles(Angle(0, self:GetAngles().y, 0)) -- flat on landing, like HL2
			self.NGLState = "unload"
			self:SetPhase(PH_GROUND)
			self.NGLNextDrop = now + 1
			self.NGLDropped = 0
			if IsValid(self.NGLPod) then
				self:NGLPodSequence("open_idle")
				self:SetNotSolid(true) -- soldiers climb out through the ship's box
			end
			self:NGLAnim("ACT_DROPSHIP_DEPLOY_IDLE")
		else
			local v = Vector((target.x - pos.x) * 2, (target.y - pos.y) * 2, clamp(dz * 1.5, -self.ClimbSpeed, self.ClimbSpeed))
			self:NGLFly(v, dt)
		end

	elseif st == "unload" then
		self:SetLocalVelocity(vector_origin)
		self:NGLUpdateDeploying(now)
		if now >= self.NGLNextDrop then
			if T.vehicle and not self.NGLVehicleOut then
				self:NGLDropVehicle()
				self.NGLNextDrop = now + self.CarryReleaseTime
			elseif self.NGLDropped < (T.count or 6) then
				self.NGLNextDrop = now + self:NGLDropOne()
			elseif not next(self.NGLDeploying) then
				self.NGLState = "ascend"
				self:SetPhase(PH_UP)
				self:NGLPodSequence("close_idle")
				self:NGLAnim("ACT_DROPSHIP_LIFTOFF")
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
			self:SetPhase(PH_FLY)
			self:SetNotSolid(false)
			self:NGLAnim(self:NGLCarrying() and "ACT_DROPSHIP_FLY_IDLE_CARGO" or "ACT_DROPSHIP_FLY_IDLE_EXAGG")
		else
			self:NGLFly(Vector(0, 0, self.ClimbSpeed), dt)
		end

	elseif st == "outbound" then
		if self:NGLFollow(dt, false) then
			self:Remove()
			return
		end
	end

	if st ~= "idle" then self:NGLGunThink(now, dt) end
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
	if IsValid(self.NGLCarried) then self.NGLCarried:Remove() end
	if IsValid(self.NGLPod) then self.NGLPod:Remove() end
	if NGL.Reinforce then NGL.Reinforce.Active[self] = nil end
end
