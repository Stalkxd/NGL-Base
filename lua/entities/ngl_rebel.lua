-- Example NGL NPC: a rebel who fights the Combine and is friendly to players.
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Rebel (NGL)"
ENT.Spawnable = false

ENT.Model = { -- a random face per rebel
	"models/Humans/Group03/male_01.mdl", "models/Humans/Group03/male_02.mdl", "models/Humans/Group03/male_03.mdl",
	"models/Humans/Group03/male_04.mdl", "models/Humans/Group03/male_05.mdl", "models/Humans/Group03/male_06.mdl",
	"models/Humans/Group03/male_07.mdl", "models/Humans/Group03/male_08.mdl", "models/Humans/Group03/male_09.mdl",
	"models/Humans/Group03/female_01.mdl", "models/Humans/Group03/female_02.mdl", "models/Humans/Group03/female_03.mdl",
	"models/Humans/Group03/female_04.mdl", "models/Humans/Group03/female_06.mdl", "models/Humans/Group03/female_07.mdl",
}
ENT.Faction = "rebels"
ENT.StartHealth = 70
ENT.RunSpeed = 220
ENT.WalkSpeed = 75
ENT.WeaponModel = "models/weapons/w_smg1.mdl"
-- Mostly the plain fight, which needs no extra traces; the defender and
-- the flanker look for hiding places (traces), so fewer of those.
ENT.AIMode = { balanced = 4, defender = 1, flanker = 1, assault = 1 }
ENT.DoorBreach = true           -- kicks doors in (no kick animation on citizen models: a shove)
-- Fewer, harder shots than before (4 damage every 0.1 s): the same damage
-- over time, a quarter fewer bullets, tracers and sounds near players.
ENT.Weapon = {
	Damage = 5,
	Delay = 0.13,
	Spread = 0.05,
	Accuracy = 0.55,
	Sound = "Weapon_SMG1.NPC_Single",
	Clip = 45,
	ReloadTime = 2.2,
}

-- Voices. Male lines by default, female lines for the female models.
ENT.Sounds = {
	Alert = { "vo/npc/male01/headsup01.wav", "vo/npc/male01/headsup02.wav", "vo/npc/male01/incoming02.wav" },
	Reload = { "vo/npc/male01/coverwhilereload01.wav", "vo/npc/male01/coverwhilereload02.wav" },
	Pain = { "vo/npc/male01/pain01.wav", "vo/npc/male01/pain02.wav", "vo/npc/male01/pain03.wav", "vo/npc/male01/pain04.wav", "vo/npc/male01/pain05.wav", "vo/npc/male01/pain06.wav", "vo/npc/male01/pain07.wav", "vo/npc/male01/pain08.wav", "vo/npc/male01/pain09.wav" },
	Death = { "vo/npc/male01/pain07.wav", "vo/npc/male01/pain08.wav", "vo/npc/male01/pain09.wav" },
	Idle = { "vo/npc/male01/question01.wav", "vo/npc/male01/question02.wav", "vo/npc/male01/question03.wav", "vo/npc/male01/question04.wav", "vo/npc/male01/question05.wav", "vo/npc/male01/question06.wav", "vo/npc/male01/question07.wav", "vo/npc/male01/question08.wav" },
}
ENT.SoundsByModel = {
	["female"] = {
		Alert = { "vo/npc/female01/headsup01.wav", "vo/npc/female01/headsup02.wav", "vo/npc/female01/incoming02.wav" },
		Reload = { "vo/npc/female01/coverwhilereload01.wav", "vo/npc/female01/coverwhilereload02.wav" },
		Pain = { "vo/npc/female01/pain01.wav", "vo/npc/female01/pain02.wav", "vo/npc/female01/pain03.wav", "vo/npc/female01/pain04.wav", "vo/npc/female01/pain05.wav", "vo/npc/female01/pain06.wav", "vo/npc/female01/pain07.wav", "vo/npc/female01/pain08.wav", "vo/npc/female01/pain09.wav" },
		Death = { "vo/npc/female01/pain07.wav", "vo/npc/female01/pain08.wav", "vo/npc/female01/pain09.wav" },
		Idle = { "vo/npc/female01/question01.wav", "vo/npc/female01/question02.wav", "vo/npc/female01/question03.wav", "vo/npc/female01/question04.wav", "vo/npc/female01/question05.wav", "vo/npc/female01/question06.wav", "vo/npc/female01/question07.wav", "vo/npc/female01/question08.wav" },
	},
}

list.Set("NPC", "ngl_rebel", {
	Name = "Rebel (NGL)",
	Class = "ngl_rebel",
	Category = "NGL Base",
	NGLGroup = "Resistance", -- its group in the NGL Base spawn menu tab (cl_spawnmenu.lua)
	IconOverride = "entities/Rebel.png",
})

if SERVER then
	NGL.SetRelation("rebels", "player", D_LI)
end
