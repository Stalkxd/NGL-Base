-- NGL base NPC.
--
-- Every NGL NPC derives from this. To make your own, create
-- lua/entities/<your_class>.lua in your addon with ENT.Base = "ngl_base" and
-- override the fields and hooks below. See lua/entities/ngl_combine_soldier.lua.
--
-- Rule of the base: the core (scheduler, movement, perception) is optimized and
-- you never need to touch it. Your hooks run on events or at the AI rate, never
-- every tick, so a mod can't accidentally cost 67 calls a second per NPC.

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "NGL Base NPC"
ENT.Category = "NGL Base"
ENT.Spawnable = false
ENT.IsNGLNPC = true

----------------------------------------------------------------------------
-- Definition fields (override these in your NPC)
----------------------------------------------------------------------------

ENT.Model = "models/combine_soldier.mdl"
ENT.StartHealth = 100           -- (not "Health": that name is taken by Entity:Health())
ENT.Faction = "neutral"         -- same faction = friends, different = enemies, unless NGL.SetRelation says otherwise
ENT.RunSpeed = 200
ENT.SightRange = 4000           -- how far it looks for enemies
ENT.AttackRange = 1200          -- closer than this it stops chasing and fights
ENT.EyeHeight = 64

ENT.WeaponModel = "models/weapons/w_smg1.mdl" -- drawn on the client only; nil for none
ENT.Weapon = {
	Damage = 5,
	Delay = 0.12,               -- seconds between shots
	Spread = 0.04,
	Accuracy = 0.6,             -- hit chance used when nobody is close enough to see the bullets
	Sound = "Weapon_SMG1.NPC_Single",
}

ENT.Anims = {
	Idle = ACT_IDLE,
	Run = ACT_RUN,
}

----------------------------------------------------------------------------
-- Hooks (override any of these; all are optional)
----------------------------------------------------------------------------
-- ENT:OnSpawned()                   after Initialize
-- ENT:OnSeeEnemy(enemy)             got a new enemy
-- ENT:OnLoseEnemy(oldEnemy)         no enemy any more
-- ENT:OnDamaged(dmginfo)            return true to ignore the damage
-- ENT:OnDeath(dmginfo)              just before the body is removed
-- ENT:OnAIThink(interval)           runs at the AI rate (10 Hz near players,
--                                   ~1 Hz far away); return true to skip the
--                                   default combat behaviour this think

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "NGLDead")
end
