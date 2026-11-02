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

ENT.Model = "models/combine_soldier.mdl" -- or a list, one picked at random per NPC: { "a.mdl", "b.mdl" }
ENT.StartHealth = 100           -- (not "Health": that name is taken by Entity:Health())
ENT.Faction = "neutral"         -- same faction = friends, different = enemies, unless NGL.SetRelation says otherwise
ENT.RunSpeed = 200              -- chasing, investigating
ENT.WalkSpeed = 80              -- wandering, strafing while shooting
ENT.SightRange = 4000           -- how far it looks for enemies
ENT.AttackRange = 1200          -- closer than this it stops chasing and fights
ENT.EyeHeight = 64
ENT.EnemyMemory = 8             -- seconds it keeps hunting an enemy it can't see (heads to where it last saw it)
ENT.AlertRadius = 1500          -- allies this close with nothing to do come to help when it spots an enemy; 0 = never
ENT.WanderRadius = 600          -- idle NPCs stroll around their home spot (where they spawned or last fought); 0 = stand still
ENT.WanderDelay = { 4, 10 }     -- seconds between strolls

ENT.WeaponModel = "models/weapons/w_smg1.mdl" -- drawn on the client only; nil for none
ENT.Weapon = {
	Damage = 5,
	Delay = 0.12,               -- seconds between shots
	Spread = 0.04,
	Accuracy = 0.6,             -- hit chance used when nobody is close enough to see the bullets
	Sound = "Weapon_SMG1.NPC_Single",
	Clip = 30,                  -- shots before reloading; 0 = never reload
	ReloadTime = 2,
}

-- Animations. Each entry is an activity or a list tried in order; the first
-- one the model has is used, so the same table works for Combine, citizens
-- and most HL2-style models. Entries you leave out keep these defaults.
ENT.Anims = {
	Idle    = { ACT_IDLE_SMG1_RELAXED, ACT_IDLE_SMG1, ACT_IDLE },   -- calm, nothing going on
	IdleAim = { ACT_IDLE_ANGRY_SMG1, ACT_IDLE_ANGRY, ACT_IDLE_SMG1, ACT_IDLE }, -- standing and fighting
	Walk    = { ACT_WALK_RIFLE_RELAXED, ACT_WALK_RIFLE, ACT_WALK },  -- wandering
	WalkAim = { ACT_WALK_AIM_RIFLE, ACT_WALK_RIFLE, ACT_WALK },      -- strafing while shooting
	Run     = { ACT_RUN_RIFLE, ACT_RUN },                            -- chasing out of sight
	RunAim  = { ACT_RUN_AIM_RIFLE, ACT_RUN_RIFLE, ACT_RUN },         -- running with the enemy in view
	-- Gestures, played over the body. Only for NPCs near a player.
	Fire    = { ACT_GESTURE_RANGE_ATTACK_SMG1, ACT_GESTURE_RANGE_ATTACK1 },
	Reload  = { ACT_GESTURE_RELOAD_SMG1, ACT_GESTURE_RELOAD },
	Flinch  = { ACT_GESTURE_SMALL_FLINCH, ACT_GESTURE_FLINCH_CHEST },
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
--                                   default behaviour this think
-- ENT:OnAlerted(ally, pos)          an ally spotted an enemy at pos; return
--                                   true to stay put
-- ENT:OnReload()                    started reloading

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "NGLDead")
end
