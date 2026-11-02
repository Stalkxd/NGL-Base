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
-- A mix of fighting styles (sv_aimodes.lua): most fight normally, some
-- sneak round to your side, some rush you, some hold their ground.
ENT.AIMode = { balanced = 3, flanker = 2, assault = 1, defender = 1 }
ENT.Rappel = true               -- ropes down ledges too high to jump
ENT.DoorBreach = true           -- kicks doors in

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

-- Combine radio chatter: every voice line comes with a radio click.
ENT.SoundLevel = 85
local VO = "npc/combine_soldier/vo/"
local function vo(...)
	local t = {}
	for i, name in ipairs({ ... }) do t[i] = VO .. name .. ".wav" end
	return t
end
ENT.Radio = { On = vo("on1", "on2"), Off = vo("off1", "off2", "off3") }
ENT.Sounds = {
	Alert = vo("contact", "contactconfim", "contactconfirmprosecuting", "weaponsoffsafeprepforcontact", "engaging"),
	Lost = vo("lostcontact", "targetmyradial", "stayalertreportsightlines"),
	Kill = vo("onedown", "onecontained", "cleaned", "flatline", "affirmativewegothimnow"),
	Idle = vo("stayalert", "reportallpositionsclear", "reportallradialsfree", "sightlineisclear", "teamdeployedandscanning", "stabilizationteamholding"),
	Ack = vo("copy", "copythat", "affirmative", "affirmative2"),
	Reload = vo("coverme", "suppressing"),
	Pain = { "npc/combine_soldier/pain1.wav", "npc/combine_soldier/pain2.wav", "npc/combine_soldier/pain3.wav" },
	Death = { "npc/combine_soldier/die1.wav", "npc/combine_soldier/die2.wav", "npc/combine_soldier/die3.wav" },
}

list.Set("NPC", "ngl_combine_soldier", {
	Name = "Combine Soldier (NGL)",
	Class = "ngl_combine_soldier",
	Category = "NGL Base",
})
