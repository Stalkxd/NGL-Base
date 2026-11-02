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
ENT.Weapon = {
	Damage = 4,
	Delay = 0.1,
	Spread = 0.05,
	Accuracy = 0.55,
	Sound = "Weapon_SMG1.NPC_Single",
	Clip = 45,
	ReloadTime = 2.2,
}

list.Set("NPC", "ngl_rebel", {
	Name = "Rebel (NGL)",
	Class = "ngl_rebel",
	Category = "NGL Base",
})

if SERVER then
	NGL.SetRelation("rebels", "player", D_LI)
end
