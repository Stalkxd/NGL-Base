-- Example NGL NPC: a rebel who fights the Combine and is friendly to players.
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Rebel (NGL)"
ENT.Spawnable = false

ENT.Model = "models/Humans/Group03/male_07.mdl"
ENT.Faction = "rebels"
ENT.StartHealth = 70
ENT.RunSpeed = 220
ENT.WeaponModel = "models/weapons/w_smg1.mdl"
ENT.Weapon = {
	Damage = 4,
	Delay = 0.1,
	Spread = 0.05,
	Accuracy = 0.55,
	Sound = "Weapon_SMG1.NPC_Single",
}

list.Set("NPC", "ngl_rebel", {
	Name = "Rebel (NGL)",
	Class = "ngl_rebel",
	Category = "NGL Base",
})

if SERVER then
	NGL.SetRelation("rebels", "player", D_LI)
end
