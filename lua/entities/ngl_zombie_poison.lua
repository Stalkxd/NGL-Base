-- NGL poison zombie, like HL2's: big, slow, tough. Carries up to three
-- poison headcrabs on its back (shown on the model) and throws them at
-- enemies a little way off; each one lands and goes for them. Claws what
-- gets close. When it dies its own crab and the ones still on its back come
-- off (sv_zombies.lua; capped by ngl_headcrab_max).
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Poison Zombie (NGL)"
ENT.Spawnable = false

ENT.Model = "models/zombie/poison.mdl"
ENT.Faction = "zombies"
ENT.StartHealth = 175
ENT.RunSpeed = 45                -- never hurries
ENT.WalkSpeed = 35
ENT.SightRange = 3000
ENT.EyeHeight = 64
ENT.CrouchChance = 0
ENT.WanderRadius = 250
ENT.Group = false
ENT.JumpDown = 120
ENT.JumpGap = false
ENT.JumpUp = 0
ENT.OpenDoors = false
ENT.Headcrab = "ngl_headcrab_poison"
ENT.HeadcrabBodygroup = 1

-- The crabs on its back, and throwing them.
ENT.Crabs = 3                    -- carried at spawn (HL2: up to 3)
ENT.CrabBodygroups = { 2, 3, 4 } -- one per crab on the back
ENT.CrabClass = "ngl_headcrab_poison"
ENT.Throw = {
	MinDist = 260, MaxDist = 800,
	MaxRise = 200,
	Delay = { 5, 9 },            -- seconds between throws
	ReleaseAt = 0.9,             -- seconds into the throw the crab leaves its hand
	FlightTime = 0.9,            -- seconds in the air
	Anim = { ACT_RANGE_ATTACK2, "Throw", "throw" },
}

ENT.WeaponModel = false
ENT.Weapon = false
ENT.Melee = {
	Damage = 20,
	Range = 60,
	Delay = 2,
	HitDelay = 0.5,              -- only when the model has no hit events (the blow lands on its AE_ZOMBIE_ATTACK event)
	DamageType = DMG_SLASH,
	Force = 250,
	HitSound = { "npc/zombie/claw_strike1.wav", "npc/zombie/claw_strike2.wav", "npc/zombie/claw_strike3.wav" },
	MissSound = { "npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav" },
}

ENT.Anims = {
	Idle = ACT_IDLE, IdleAim = ACT_IDLE,
	Walk = ACT_WALK, WalkAim = ACT_WALK,
	Run = ACT_WALK, RunAim = ACT_WALK,
	Melee = { ACT_MELEE_ATTACK1 },
	Flinch = { ACT_GESTURE_FLINCH_HEAD, ACT_GESTURE_FLINCH_CHEST },
	Fire = false, Reload = false,
	CrouchIdle = false, CrouchAim = false, CrouchWalk = false,
}

ENT.Sounds = {
	Alert = { "npc/zombie_poison/pz_alert1.wav", "npc/zombie_poison/pz_alert2.wav" },
	Idle = { "npc/zombie_poison/pz_idle2.wav", "npc/zombie_poison/pz_idle3.wav", "npc/zombie_poison/pz_idle4.wav" },
	Pain = { "npc/zombie_poison/pz_pain1.wav", "npc/zombie_poison/pz_pain2.wav", "npc/zombie_poison/pz_pain3.wav" },
	Death = { "npc/zombie_poison/pz_die1.wav", "npc/zombie_poison/pz_die2.wav" },
	Attack = { "npc/zombie_poison/pz_warn1.wav", "npc/zombie_poison/pz_warn2.wav" },
	Throw = { "npc/zombie_poison/pz_throw2.wav", "npc/zombie_poison/pz_throw3.wav" },
}
ENT.IdleSoundDelay = { 6, 14 }

if SERVER then
	local THROW_EVENT = { AE_ZOMBIE_POISON_THROW_CRAB = true }

	-- Which back crabs are still there (bodygroups on the model).
	function ENT:NGLShowBackCrabs()
		local bgs, n = self.CrabBodygroups, self.NGLCrabs or 0
		local count = self:GetNumBodyGroups()
		for k, bg in ipairs(bgs) do
			if bg < count then self:SetBodygroup(bg, k <= n and 1 or 0) end
		end
	end

	function ENT:OnSpawned()
		self.NGLCrabs = math.min(self.Crabs or 0, #self.CrabBodygroups)
		self:NGLShowBackCrabs()
		local d = self.Throw.Delay
		self.NGLNextThrow = CurTime() + math.Rand(1, d[1])
	end

	-- Throws a crab when the enemy is in view a little way off.
	function ENT:OnCombat(enemy, dist, visible)
		local th = self.Throw
		local now = CurTime()
		if not visible or (self.NGLCrabs or 0) <= 0 or now < (self.NGLNextThrow or 0) then return end
		if dist < th.MinDist or dist > th.MaxDist then return end
		local dz = enemy:GetPos().z - self:GetPos().z
		if math.abs(dz) > th.MaxRise then return end
		local d = th.Delay
		self.NGLNextThrow = now + math.Rand(d[1], d[2])
		if not NGL.Zombie.CanSpawnCrab() then return end
		if self:OnAttack(enemy, "throw") == true then return true end

		self:StopMoving()
		self:LookAt(enemy)
		local dur = false
		for _, a in ipairs(th.Anim) do
			dur = self:PlayAnim(a, true)
			if dur then break end
		end
		-- The crab leaves the hand on the model's own throw event (HL2's
		-- AE_ZOMBIE_POISON_THROW_CRAB), not after a set time; ReleaseAt
		-- only without one.
		local at = th.ReleaseAt
		local ev = dur and self:NGLEventTimes(self.NGLAnimSeq, dur, THROW_EVENT)
		if ev and ev[1] then at = ev[1] end
		if self.NGLLiveEvents then at = at + 0.35 end -- the event itself throws it (OnAnimEventName)
		if not dur then self.NGLBusyUntil = now + at + 0.3 end
		if GetConVar("ngl_debug_melee"):GetBool() then
			print(string.format("[NGL] %s throw %s (%.2f s): crab leaves at %.2f s (%s)", self:GetClass(),
				dur and self:GetSequenceName(self.NGLAnimSeq) or "?", dur or 0, at, (ev and ev[1]) and "model event" or "ReleaseAt"))
		end
		self:Speak("Throw")
		local id = (self.NGLThrowId or 0) + 1
		self.NGLThrowId = id
		self.NGLThrowAt = enemy
		timer.Simple(at, function()
			if IsValid(self) and self.NGLThrowId == id then self:NGLReleaseCrab() end
		end)
		return true
	end

	-- The crab in its hand goes: lands just short of the target, then goes for it.
	function ENT:NGLReleaseCrab()
		local enemy = self.NGLThrowAt
		self.NGLThrowAt = nil
		self.NGLThrowId = (self.NGLThrowId or 0) + 1 -- a later timer does nothing
		if self.NGLDying or (self.NGLCrabs or 0) <= 0 or enemy == nil then return end
		local target = IsValid(enemy) and enemy or self.NGLEnemy
		if not IsValid(target) then return end
		local th = self.Throw
		local pos = self:GetPos()
		local fwd = target:GetPos() - pos
		fwd.z = 0
		fwd:Normalize()
		local src = Vector(pos.x + fwd.x * 24, pos.y + fwd.y * 24, pos.z + 70)
		local tp = target:GetPos()
		local dst = tp - fwd * 40
		local crab = NGL.Zombie.SpawnCrab(self.CrabClass, src, fwd:Angle().y, target, { throwTo = dst, time = th.FlightTime })
		if crab then
			self.NGLCrabs = self.NGLCrabs - 1
			self:NGLShowBackCrabs()
		end
	end

	function ENT:OnAnimEventName(name)
		if name == "AE_ZOMBIE_POISON_THROW_CRAB" and self.NGLThrowAt ~= nil then self:NGLReleaseCrab() end
	end

	-- Crabs still on its back come off with it.
	function ENT:OnDeath(dmginfo)
		local n = self.NGLCrabs or 0
		if n <= 0 or dmginfo:IsDamageType(DMG_BLAST) then return end
		local pos = self:GetPos()
		local enemy = self.NGLEnemy
		for k = 1, n do
			local a = math.rad(self:GetAngles().y + 180 + (k - 2) * 50)
			local p = Vector(pos.x + math.cos(a) * 24, pos.y + math.sin(a) * 24, pos.z + 40)
			if not NGL.Zombie.SpawnCrab(self.CrabClass, p, math.deg(a), enemy, { leap = false }) then break end
		end
		self.NGLCrabs = 0
		self:NGLShowBackCrabs()
	end
end

list.Set("NPC", "ngl_zombie_poison", {
	Name = "Poison Zombie (NGL)",
	Class = "ngl_zombie_poison",
	Category = "NGL Base",
	NGLGroup = "Zombies", -- its group in the NGL Base spawn menu tab (cl_spawnmenu.lua)
	IconOverride = "entities/npc_poisonzombie.png",
})
