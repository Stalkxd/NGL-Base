-- Example NGL NPC: a melee-only zombie. No gun, no code: just fields.
-- Its headcrab jumps off when it dies (ENT.Headcrab).
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Zombie (NGL)"
ENT.Spawnable = false

ENT.Model = "models/zombie/classic.mdl"
ENT.Faction = "zombies"         -- hostile to everyone else, players included
ENT.StartHealth = 100
ENT.RunSpeed = 60               -- classic zombies shamble even when chasing
ENT.WalkSpeed = 35
ENT.SightRange = 3000
ENT.EyeHeight = 60
ENT.WanderRadius = 300
ENT.Group = false               -- zombies shamble alone, no formations
ENT.JumpDown = 250              -- drops off ledges, but doesn't jump gaps or open doors
ENT.JumpGap = false
ENT.JumpUp = 0                  -- too clumsy to jump up
ENT.OpenDoors = false
ENT.Headcrab = "ngl_headcrab"   -- the crab comes off when it dies (not after a head shot)
ENT.HeadcrabBodygroup = 1

ENT.WeaponModel = false
ENT.Weapon = false
ENT.Melee = {
	Damage = 20,
	Range = 55,
	Delay = 1.6,
	HitDelay = 0.6,
	DamageType = DMG_SLASH,
	Force = 150,
	HitSound = { "npc/zombie/claw_strike1.wav", "npc/zombie/claw_strike2.wav", "npc/zombie/claw_strike3.wav" },
	MissSound = { "npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav" },
}

ENT.Anims = {
	Idle = ACT_IDLE, IdleAim = ACT_IDLE,
	Walk = ACT_WALK, WalkAim = ACT_WALK,
	Run = ACT_WALK, RunAim = ACT_WALK,
	Melee = ACT_MELEE_ATTACK1,
	Flinch = { ACT_GESTURE_FLINCH_HEAD, ACT_GESTURE_FLINCH_CHEST },
	Fire = false, Reload = false,
}

ENT.Sounds = {
	Alert = { "npc/zombie/zombie_alert1.wav", "npc/zombie/zombie_alert2.wav", "npc/zombie/zombie_alert3.wav" },
	Idle = { "npc/zombie/zombie_voice_idle1.wav", "npc/zombie/zombie_voice_idle2.wav", "npc/zombie/zombie_voice_idle3.wav",
		"npc/zombie/zombie_voice_idle4.wav", "npc/zombie/zombie_voice_idle5.wav", "npc/zombie/zombie_voice_idle6.wav" },
	Pain = { "npc/zombie/zombie_pain1.wav", "npc/zombie/zombie_pain2.wav", "npc/zombie/zombie_pain3.wav",
		"npc/zombie/zombie_pain4.wav", "npc/zombie/zombie_pain5.wav", "npc/zombie/zombie_pain6.wav" },
	Death = { "npc/zombie/zombie_die1.wav", "npc/zombie/zombie_die2.wav", "npc/zombie/zombie_die3.wav" },
	Attack = { "npc/zombie/zo_attack1.wav", "npc/zombie/zo_attack2.wav" },
}
ENT.IdleSoundDelay = { 5, 12 }

list.Set("NPC", "ngl_zombie", {
	Name = "Zombie (NGL)",
	Class = "ngl_zombie",
	Category = "NGL Base",
})
