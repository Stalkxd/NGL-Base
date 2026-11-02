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

list.Set("NPC", "ngl_combine_soldier", {
	Name = "Combine Soldier (NGL)",
	Class = "ngl_combine_soldier",
	Category = "NGL Base",
})

if SERVER then
	-- Example hooks: radio chatter. They run on events, never per tick.
	function ENT:OnSeeEnemy(enemy)
		self:EmitSound("npc/combine_soldier/vo/contact.wav", 75, 100, 0.6)
	end

	function ENT:OnReload()
		if math.random(3) == 1 then self:EmitSound("npc/combine_soldier/vo/coverme.wav", 70, 100, 0.5) end
	end
end
