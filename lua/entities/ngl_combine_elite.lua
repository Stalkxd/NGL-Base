-- Elite Combine: the first hard NGL NPC. A tougher, more accurate soldier
-- with an AR2 that leads up to 9 Combine soldiers (squad of 10 with itself):
-- it recruits them, they follow it in formation, and when the target slips
-- out of sight it halts the squad and sends 3 of them to search, by hand
-- signal. All of the leading comes from ENT.Squad (sv_squad.lua), so any
-- custom NPC can lead the same way.
AddCSLuaFile()

ENT.Base = "ngl_combine_soldier"
ENT.PrintName = "Combine Elite (NGL)"
ENT.Spawnable = false

ENT.Model = "models/combine_super_soldier.mdl"
ENT.StartHealth = 160
ENT.SightRange = 5000
ENT.EnemyMemory = 12
ENT.AttackRange = 1400
ENT.CrouchChance = 0.25

ENT.WeaponModel = "models/weapons/w_irifle.mdl"
ENT.Weapon = {
	Damage = 8,
	Delay = 0.1,
	Spread = 0.025,
	Accuracy = 0.75,
	Sound = "Weapon_AR2.Single",
	Clip = 30,
	ReloadTime = 2,
}

ENT.Squad = {
	Max = 10,                          -- the elite plus 9 soldiers
	Recruit = { "ngl_combine_soldier" },
	RecruitRadius = 1500,
	Scouts = 3,
	ScoutRadius = 400,
	ScoutTime = 20,
	LostDelay = 2,
}

local VO = "npc/combine_soldier/vo/"
ENT.Sounds = {
	Alert = VO .. "contact.wav",
	Reload = VO .. "coverme.wav",
	Halt = { VO .. "lostcontact.wav", VO .. "hardenthatposition.wav" },
	Search = { VO .. "sweepingin.wav", VO .. "motioncheckallradials.wav" },
	Engage = { VO .. "movein.wav", VO .. "gosharp.wav" },
	StandDown = { VO .. "reportingclear.wav", VO .. "thatsitwrapitup.wav" },
	Pain = { "npc/combine_soldier/pain1.wav", "npc/combine_soldier/pain2.wav", "npc/combine_soldier/pain3.wav" },
	Death = { "npc/combine_soldier/die1.wav", "npc/combine_soldier/die2.wav", "npc/combine_soldier/die3.wav" },
}

list.Set("NPC", "ngl_combine_elite", {
	Name = "Combine Elite (NGL)",
	Class = "ngl_combine_elite",
	Category = "NGL Base",
})
