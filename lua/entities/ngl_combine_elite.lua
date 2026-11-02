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
ENT.AIMode = "balanced"         -- the leader stays with its squad

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
	CommandRadius = 3000,              -- APCs (ENT.Commandable) this close take its orders
	FireSupportDelay = 12,             -- s between rocket barrages it calls in
	-- Down to 3 soldiers or fewer in a fight: a dropship with 6 more, or 4
	-- on foot from out of sight indoors or with no place to land (sv_reinforce.lua;
	-- ngl_reinforce_limit, ngl_reinforce_cooldown, ngl_dropship_max).
	Reinforce = {
		Ship = "ngl_dropship", Cargo = "ngl_combine_soldier", Count = 6, OnFootCount = 4, When = 3,
		Vehicle = "ngl_apc", VehicleLimit = 1, VehicleThreat = 4, -- an APC instead, when the fight is heavy
	},
}

local VO = "npc/combine_soldier/vo/"
local function vo(...)
	local t = {}
	for i, name in ipairs({ ... }) do t[i] = VO .. name .. ".wav" end
	return t
end
ENT.SoundLevel = 90 -- the squad has to hear the orders
ENT.Radio = { On = vo("on1", "on2"), Off = vo("off1", "off2", "off3") }
ENT.Sounds = {
	Alert = vo("contact", "contactconfirmprosecuting", "prepforcontact"),
	Lost = vo("lostcontact", "targetmyradial"),
	Kill = vo("onedown", "affirmativewegothimnow", "cleaned"),
	Idle = vo("stayalert", "reportallpositionsclear", "sightlineisclear", "sectorisnotsecure"),
	Reload = vo("coverme"),
	Halt = vo("lostcontact", "hardenthatposition"),
	Search = vo("sweepingin", "motioncheckallradials"),
	Engage = vo("movein", "gosharp", "readyweapons"),
	StandDown = vo("reportingclear", "thatsitwrapitup"),
	Reinforce = vo("overwatchrequestreinforcement"),
	CallFire = vo("callhotpoint", "prosecuting"), -- ordering the APC to fire
	Pain = { "npc/combine_soldier/pain1.wav", "npc/combine_soldier/pain2.wav", "npc/combine_soldier/pain3.wav" },
	Death = { "npc/combine_soldier/die1.wav", "npc/combine_soldier/die2.wav", "npc/combine_soldier/die3.wav" },
}

list.Set("NPC", "ngl_combine_elite", {
	Name = "Combine Elite (NGL)",
	Class = "ngl_combine_elite",
	Category = "NGL Base",
})
