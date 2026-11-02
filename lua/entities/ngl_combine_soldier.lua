-- Example NGL NPC. This whole file is all a modder needs to write.
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Combine Soldier (NGL)"
ENT.Spawnable = false -- spawn it from the NPC tab instead

ENT.Model = { "models/combine_soldier.mdl", "models/combine_soldier_prisonguard.mdl" }
ENT.Faction = "combine"
ENT.StartHealth = 80
ENT.RunSpeed = 210
ENT.WeaponModel = "models/weapons/w_smg1.mdl"

-- Rifle butt when an enemy gets too close; the SMG (base default) otherwise.
ENT.Melee = {
	Damage = 15,
	Range = 60,
	Delay = 2,
	HitDelay = 0.35,
	DamageType = DMG_CLUB,
	Force = 300,
	HitSound = "Flesh.ImpactHard",
}

ENT.SoundLevel = 75
ENT.Sounds = {
	Alert = "npc/combine_soldier/vo/contact.wav",
	Reload = "npc/combine_soldier/vo/coverme.wav",
	Pain = { "npc/combine_soldier/pain1.wav", "npc/combine_soldier/pain2.wav", "npc/combine_soldier/pain3.wav" },
	Death = { "npc/combine_soldier/die1.wav", "npc/combine_soldier/die2.wav", "npc/combine_soldier/die3.wav" },
}

list.Set("NPC", "ngl_combine_soldier", {
	Name = "Combine Soldier (NGL)",
	Class = "ngl_combine_soldier",
	Category = "NGL Base",
})
