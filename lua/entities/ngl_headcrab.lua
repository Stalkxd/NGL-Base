-- NGL headcrab: small, leaps at your face. HL2's headcrab with fields only;
-- the leap is ENT.LeapAttack (sv_leap.lua). Zombies drop one when they die
-- (ENT.Headcrab, sv_zombies.lua). ngl_headcrab_fast and ngl_headcrab_poison
-- are built on this one.
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Headcrab (NGL)"
ENT.Spawnable = false

ENT.Model = "models/headcrabclassic.mdl"
ENT.Faction = "zombies"
ENT.StartHealth = 5             -- one crowbar swing kills it, even with damage scaled down on hard (HL2: 10)
ENT.RunSpeed = 130
ENT.WalkSpeed = 50
ENT.SightRange = 2000
ENT.AttackRange = 250
ENT.EyeHeight = 10
ENT.CrouchEyeHeight = 10
ENT.CrouchChance = 0
ENT.WanderRadius = 250
ENT.EnemyMemory = 10
ENT.Group = false
ENT.Hull = { Vector(-12, -12, 0), Vector(12, 12, 20) }
ENT.JumpDown = 250
ENT.JumpUp = 48
ENT.JumpGap = true
ENT.OpenDoors = false
ENT.AlertRadius = 600
ENT.SoundLevel = 70

ENT.WeaponModel = false
ENT.Weapon = false
ENT.Melee = nil

ENT.LeapAttack = {
	Damage = 10,
	MinDist = 0,
	MaxDist = 260,
	MaxRise = 96,
	Delay = 2.5,
	Chance = 0.7,
	Reach = 26,
	Bounce = true,            -- off the target after the bite (sv_leap.lua)
	DamageType = DMG_SLASH,
	Force = 120,
	Anim = { ACT_RANGE_ATTACK1, "jumpattack_broadcast" },
	Sound = "Attack",
	HitSound = "npc/headcrab/headbite.wav",
	Recover = 0.6,
}

ENT.Anims = {
	Idle = ACT_IDLE, IdleAim = ACT_IDLE,
	Walk = ACT_WALK, WalkAim = ACT_WALK,
	Run = { ACT_RUN, ACT_WALK }, RunAim = { ACT_RUN, ACT_WALK },
	Melee = false,
	Flinch = false, Fire = false, Reload = false,
	CrouchIdle = false, CrouchAim = false, CrouchWalk = false,
	Jump = { ACT_RANGE_ATTACK1, ACT_JUMP }, JumpUp = { ACT_RANGE_ATTACK1, ACT_JUMP },
	Glide = false, Land = false,
	ClimbUp = false, ClimbDown = false, Kick = false,
}

ENT.Sounds = {
	Alert = "npc/headcrab/alert1.wav",
	Idle = { "npc/headcrab/idle1.wav", "npc/headcrab/idle2.wav", "npc/headcrab/idle3.wav" },
	Pain = { "npc/headcrab/pain1.wav", "npc/headcrab/pain2.wav", "npc/headcrab/pain3.wav" },
	Death = { "npc/headcrab/die1.wav", "npc/headcrab/die2.wav" },
	Attack = { "npc/headcrab/attack1.wav", "npc/headcrab/attack2.wav", "npc/headcrab/attack3.wav" },
}
ENT.IdleSoundDelay = { 6, 14 }

list.Set("NPC", "ngl_headcrab", {
	Name = "Headcrab (NGL)",
	Class = "ngl_headcrab",
	Category = "NGL Base",
	NGLGroup = "Headcrabs", -- its group in the NGL Base spawn menu tab (cl_spawnmenu.lua)
	IconOverride = "entities/npc_headcrab.png",
})
