-- NGL fast zombie. Runs straight at you (the "assault" AI mode), leaps at
-- you from 200 to 300 units (ENT.LeapAttack) and claws. The "tricky" mode
-- (sv_aimodes.lua) is still there: it gets out of your sight first, lies
-- low a few seconds and then comes at you when you don't expect it, but its
-- hiding-spot searches cost a lot in big hordes, so it's no longer the
-- default. ENT.AIMode = "tricky" in your own class, or ngl_ai_mode tricky
-- all, brings it back. Climbs walls too high to jump: the
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
ENT.AIMode = "assault"         -- runs at you; "tricky" hides first, then a surprise attack (sv_aimodes.lua)
ENT.Group = false
ENT.JumpDown = 400              -- drops off roofs to get at you
ENT.JumpUp = 72
ENT.JumpGap = true
ENT.Climb = 400                 -- climbs walls up to this high (climb links)
ENT.ClimbRate = 320
ENT.OpenDoors = false
ENT.DoorBreach = "always"       -- beats doors down (any door), fight or not
ENT.DoorHits = 4                -- blows a door takes (light claws)
ENT.Headcrab = "ngl_headcrab_fast"
ENT.HeadcrabBodygroup = 1

ENT.WeaponModel = false
ENT.Weapon = false
-- HL2's numbers (npc_fastzombie.cpp): 3 damage a claw, two claws a swing
-- (on the model's AE_ZOMBIE_ATTACK events when it has them), 5 for the leap.
ENT.Melee = {
	Damage = 3,
	Range = 55,
	Delay = 0.4,                 -- swings follow each other as fast as the animation goes
	HitDelay = { 0.2, 0.4 },     -- when the model has no hit events
	DamageType = DMG_SLASH,
	Force = 80,
	HitSound = { "npc/fast_zombie/claw_strike1.wav", "npc/fast_zombie/claw_strike2.wav", "npc/fast_zombie/claw_strike3.wav" },
	MissSound = { "npc/fast_zombie/claw_miss1.wav", "npc/fast_zombie/claw_miss2.wav" },
}
-- HL2's leap: from 200 to 300 units, at most 128 up or down, facing you; it
-- crouches (ACT_RANGE_ATTACK1) and springs at its AE_FASTZOMBIE_LEAP event,
-- flies at your middle on a ballistic arc (at most 1000 units/s) and claws
-- you on touch. It leaps whether or not you are looking at it.
ENT.LeapAttack = {
	Damage = 5,
	MinDist = 200,
	MaxDist = 300,
	MaxRise = 128,
	MaxDrop = 128,
	Delay = 3,                   -- HL2: 2 s after the leap, 1 more after landing
	Chance = 1,
	Reach = 40,
	DamageType = DMG_SLASH,
	Force = 500,
	Velocity = "hl2",
	WindUp = 0.4,                -- seconds, when the model has no AE_FASTZOMBIE_LEAP event
	WindUpAnim = { ACT_RANGE_ATTACK1 },
	WindUpEvent = "AE_FASTZOMBIE_LEAP",
	WindUpSound = "NPC_FastZombie.RangeAttack",
	Anim = { "LeapStrike", ACT_JUMP },
	Sound = "NPC_FastZombie.LeapAttack",
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
	NGLGroup = "Zombies", -- its group in the NGL Base spawn menu tab (cl_spawnmenu.lua)
	IconOverride = "entities/npc_fastzombie.png",
})
