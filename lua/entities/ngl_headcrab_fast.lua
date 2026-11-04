-- NGL fast headcrab: quick on its legs, leaps from further away and more
-- often, bites for less. Built on ngl_headcrab.
AddCSLuaFile()

ENT.Base = "ngl_headcrab"
ENT.PrintName = "Fast Headcrab (NGL)"
ENT.Spawnable = false

ENT.Model = "models/headcrab.mdl"
ENT.StartHealth = 5             -- one crowbar swing
ENT.RunSpeed = 280
ENT.WalkSpeed = 80
ENT.AttackRange = 350

ENT.LeapAttack = {
	Damage = 5,
	MinDist = 0,
	MaxDist = 360,
	MaxRise = 110,
	Delay = 1.5,
	Chance = 0.8,
	Reach = 26,
	DamageType = DMG_SLASH,
	Force = 100,
	Anim = { ACT_RANGE_ATTACK1, "attack" },
	Sound = "Attack",
	HitSound = "npc/headcrab/headbite.wav",
	Recover = 0.3,
}

ENT.Sounds = {
	Alert = { "npc/headcrab_fast/idle1.wav", "npc/headcrab_fast/idle2.wav" },
	Idle = { "npc/headcrab_fast/idle1.wav", "npc/headcrab_fast/idle2.wav", "npc/headcrab_fast/idle3.wav" },
	Pain = { "npc/headcrab_fast/pain1.wav", "npc/headcrab_fast/pain2.wav", "npc/headcrab_fast/pain3.wav" },
	Death = { "npc/headcrab_fast/die1.wav", "npc/headcrab_fast/die2.wav" },
	Attack = { "npc/headcrab_fast/attack1.wav", "npc/headcrab_fast/attack2.wav", "npc/headcrab_fast/attack3.wav" },
}

list.Set("NPC", "ngl_headcrab_fast", {
	Name = "Fast Headcrab (NGL)",
	Class = "ngl_headcrab_fast",
	Category = "NGL Base",
})
