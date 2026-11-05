-- NGL poison headcrab: slow and tough for a crab. Before it leaps it rears
-- up and rattles (a warning, like in HL2), and its bite is poison: a player
-- is taken down to 1 health and gets it back over the next seconds. Poison
-- zombies carry and throw these. Built on ngl_headcrab.
AddCSLuaFile()

ENT.Base = "ngl_headcrab"
ENT.PrintName = "Poison Headcrab (NGL)"
ENT.Spawnable = false

ENT.Model = "models/headcrabblack.mdl"
ENT.StartHealth = 35
ENT.RunSpeed = 75
ENT.WalkSpeed = 40
ENT.AttackRange = 250

ENT.LeapAttack = {
	Damage = 10,             -- players: down to 1 health instead (Poison)
	NPCDamage = 40,
	Poison = true,
	MinDist = 0,
	MaxDist = 250,
	MaxRise = 96,
	Delay = 3,
	Chance = 1,
	Reach = 26,
	Bounce = true,            -- off the target after the bite (sv_leap.lua)
	Force = 80,
	-- Ready to jump: HL2's warning hiss (NPC_BlackHeadcrab.Telegraph) while
	-- it gathers itself, then the jump at the model's AE_HEADCRAB_JUMPATTACK.
	WindUp = 0.5,
	WindUpAnim = { ACT_RANGE_ATTACK1 },
	WindUpEvent = "AE_HEADCRAB_JUMPATTACK",
	WindUpSound = "Telegraph",
	Anim = false,            -- the wind-up animation carries on in the air
	Sound = "Leap",
	HitSound = { "npc/headcrab_poison/ph_poisonbite1.wav", "npc/headcrab_poison/ph_poisonbite2.wav", "npc/headcrab_poison/ph_poisonbite3.wav" },
	Recover = 0.8,
}
ENT.ThreatAnim = { "Threatdisplay", "threatdisplay", ACT_IDLE_ANGRY }
ENT.ThreatTime = 1.2       -- seconds of rattling before the leap

ENT.Sounds = {
	Alert = { "npc/headcrab_poison/ph_talk1.wav", "npc/headcrab_poison/ph_talk2.wav", "npc/headcrab_poison/ph_talk3.wav" },
	Idle = { "npc/headcrab_poison/ph_idle1.wav", "npc/headcrab_poison/ph_idle2.wav", "npc/headcrab_poison/ph_idle3.wav" },
	Pain = { "npc/headcrab_poison/ph_pain1.wav", "npc/headcrab_poison/ph_pain2.wav", "npc/headcrab_poison/ph_pain3.wav" },
	Death = { "npc/headcrab_poison/ph_rattle1.wav", "npc/headcrab_poison/ph_rattle2.wav" },
	Leap = { "npc/headcrab_poison/ph_jump1.wav", "npc/headcrab_poison/ph_jump2.wav", "npc/headcrab_poison/ph_jump3.wav" },
	Rattle = { "npc/headcrab_poison/ph_rattle1.wav", "npc/headcrab_poison/ph_rattle2.wav", "npc/headcrab_poison/ph_rattle3.wav" },
	Telegraph = { "npc/headcrab_poison/ph_warning1.wav", "npc/headcrab_poison/ph_warning2.wav", "npc/headcrab_poison/ph_warning3.wav" },
}

if SERVER then
	-- Rattle first: the leap only comes on the next try after the warning.
	function ENT:OnAttack(enemy, kind)
		if kind ~= "leap" then return end
		local now = CurTime()
		if now - (self.NGLRattled or -100) < 4 then return end -- warned just now: leap
		self.NGLRattled = now
		self:StopMoving()
		self:LookAt(enemy)
		self:Speak("Rattle")
		local dur = false
		for _, a in ipairs(self.ThreatAnim) do
			dur = self:PlayAnim(a, true)
			if dur then break end
		end
		local t = self.ThreatTime
		self.NGLBusyUntil = math.max(self.NGLBusyUntil or 0, now + t)
		self.NGLNextLeap = now + t
		return true
	end
end

list.Set("NPC", "ngl_headcrab_poison", {
	Name = "Poison Headcrab (NGL)",
	Class = "ngl_headcrab_poison",
	Category = "NGL Base",
	NGLGroup = "Headcrabs", -- its group in the NGL Base spawn menu tab (cl_spawnmenu.lua)
	IconOverride = "entities/npc_headcrab_black.png",
})
