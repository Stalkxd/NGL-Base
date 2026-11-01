-- Example NGL NPC. This whole file is all a modder needs to write.
AddCSLuaFile()

ENT.Base = "ngl_base"
ENT.PrintName = "Combine Soldier (NGL)"
ENT.Spawnable = false -- spawn it from the NPC tab instead

ENT.Model = "models/combine_soldier.mdl"
ENT.Faction = "combine"
ENT.StartHealth = 80
ENT.RunSpeed = 210
ENT.WeaponModel = "models/weapons/w_smg1.mdl"

list.Set("NPC", "ngl_combine_soldier", {
	Name = "Combine Soldier (NGL)",
	Class = "ngl_combine_soldier",
	Category = "NGL Base",
})

if SERVER then
	-- Example hook: shout when an enemy shows up (runs once per new enemy, not per tick).
	function ENT:OnSeeEnemy(enemy)
		self:EmitSound("npc/combine_soldier/vo/contact.wav", 75, 100, 0.6)
	end
end
