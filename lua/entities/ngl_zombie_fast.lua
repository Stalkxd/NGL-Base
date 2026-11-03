-- NGL fast zombie. Comes at you from out of sight: while you watch it, it
-- runs off to a spot at your side or back you can't see (the "ambusher" AI
-- mode, sv_aimodes.lua), waits for you to look away, then rushes and leaps
-- at you (ENT.LeapAttack) and claws. Climbs walls too high to jump: the
-- climb links ngl_nav_generate puts at high walls (sv_nav_climb.lua).
-- Fields only, no code.
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Fast Zombie (NGL)"
ENT.Spawnable = false

ENT.Model = "models/zombie/fast.mdl"
ENT.Faction = "zombies"
ENT.StartHealth = 50
ENT.RunSpeed = 320
ENT.WalkSpeed = 90
ENT.SightRange = 4000
ENT.EyeHeight = 50
ENT.CrouchChance = 0
ENT.WanderRadius = 400
ENT.EnemyMemory = 15            -- keeps track of you while it hides
ENT.AIMode = "ambusher"
ENT.Group = false
ENT.JumpDown = 400              -- drops off roofs to get at you
ENT.JumpUp = 72
ENT.JumpGap = true
ENT.Climb = 400                 -- climbs walls up to this high (climb links)
ENT.ClimbRate = 320
ENT.OpenDoors = false
ENT.Headcrab = "ngl_headcrab_fast"
ENT.HeadcrabBodygroup = 1

ENT.WeaponModel = false
ENT.Weapon = false
ENT.Melee = {
	Damage = 10,
	Range = 55,
	Delay = 0.9,
	HitDelay = 0.25,
	DamageType = DMG_SLASH,
	Force = 80,
	HitSound = { "npc/fast_zombie/claw_strike1.wav", "npc/fast_zombie/claw_strike2.wav", "npc/fast_zombie/claw_strike3.wav" },
	MissSound = { "npc/fast_zombie/claw_miss1.wav", "npc/fast_zombie/claw_miss2.wav" },
}
ENT.LeapAttack = {
	Damage = 15,
	MinDist = 160,
	MaxDist = 650,
	MaxRise = 200,
	MaxDrop = 400,
	Delay = 4,
	Chance = 0.8,
	Reach = 40,
	DamageType = DMG_SLASH,
	Force = 300,
	Anim = { "LeapStrike", ACT_RANGE_ATTACK1, ACT_JUMP },
	Sound = "Leap",
	HitSound = { "npc/fast_zombie/claw_strike1.wav", "npc/fast_zombie/claw_strike2.wav", "npc/fast_zombie/claw_strike3.wav" },
	Recover = 0.3,
}

ENT.Anims = {
	Idle = ACT_IDLE, IdleAim = ACT_IDLE,
	Walk = ACT_WALK, WalkAim = ACT_WALK,
	Run = { ACT_RUN, ACT_WALK }, RunAim = { ACT_RUN, ACT_WALK },
	Melee = { ACT_MELEE_ATTACK1 },
	Flinch = { ACT_GESTURE_FLINCH_HEAD, ACT_GESTURE_FLINCH_CHEST },
	Fire = false, Reload = false,
	CrouchIdle = false, CrouchAim = false, CrouchWalk = false,
	Jump = { "LeapStrike", ACT_JUMP, ACT_RANGE_ATTACK1 }, JumpUp = { ACT_CLIMB_UP, "LeapStrike", ACT_JUMP },
	Glide = { ACT_GLIDE, "leap_loop" }, Land = { ACT_LAND, "leap_end" },
	ClimbUp = { ACT_CLIMB_UP, "climbloop" },
	ClimbDown = { ACT_CLIMB_DOWN, ACT_CLIMB_UP, "climbloop" },
	Kick = false,
}

ENT.Sounds = {
	Alert = { "npc/fast_zombie/fz_alert_far1.wav", "npc/fast_zombie/fz_alert_close1.wav" },
	Idle = { "npc/fast_zombie/idle1.wav", "npc/fast_zombie/idle2.wav", "npc/fast_zombie/idle3.wav" },
	Pain = { "npc/fast_zombie/wake1.wav" },
	Death = { "npc/fast_zombie/fz_scream1.wav" },
	Attack = { "npc/fast_zombie/fz_frenzy1.wav" },
	Leap = { "npc/fast_zombie/leap1.wav" },
}
ENT.IdleSoundDelay = { 6, 14 }

list.Set("NPC", "ngl_zombie_fast", {
	Name = "Fast Zombie (NGL)",
	Class = "ngl_zombie_fast",
	Category = "NGL Base",
})
