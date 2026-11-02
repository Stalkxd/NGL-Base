-- NGL base NPC.
--
-- Every NGL NPC derives from this. To make your own, create
-- lua/entities/<your_class>.lua in your addon with ENT.Base = "ngl_base" and
-- override the fields and hooks below. Examples: ngl_combine_soldier.lua
-- (gun + rifle-butt melee), ngl_rebel.lua (random faces, per-model voices),
-- ngl_zombie.lua (melee only).
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
ENT.CrouchEyeHeight = 40
ENT.CrouchChance = 0.35         -- chance, each time it picks a new spot while fighting, to crouch and hold position instead; 0 = never
ENT.EnemyMemory = 8             -- seconds it keeps hunting an enemy it can't see (heads to where it last saw it)
ENT.AlertRadius = 1500          -- allies this close with nothing to do come to help when it spots an enemy; 0 = never
ENT.WanderRadius = 600          -- idle NPCs stroll around their home spot (where they spawned or last fought); 0 = stand still
ENT.WanderDelay = { 4, 10 }     -- seconds between strolls

ENT.WeaponModel = "models/weapons/w_smg1.mdl" -- drawn on the client only; false for none
-- Ranged weapon; false for none. Add `Projectile = { ... }` to fire
-- projectiles instead of bullets (fields listed in lua/ngl/server/sv_projectile.lua),
-- e.g. Projectile = { Damage = 80, Radius = 180, Speed = 1200, Model = "models/weapons/w_missile_closed.mdl" }.
ENT.Weapon = {
	Damage = 5,
	Delay = 0.12,               -- seconds between shots
	Spread = 0.04,
	Accuracy = 0.6,             -- hit chance used when nobody is close enough to see the bullets
	Sound = "Weapon_SMG1.NPC_Single",
	Clip = 30,                  -- shots before reloading; 0 = never reload
	ReloadTime = 2,
}

-- Melee attack; nil/false for none. An NPC with Melee and no Weapon closes in
-- and swings; one with both shoots, and swings when the enemy is in reach.
-- ENT.Melee = {
-- 	Damage = 20,
-- 	Range = 70,                 -- reach in units (the blow lands up to 1.3x this, in front of the NPC)
-- 	Delay = 1.5,                -- seconds between swings
-- 	HitDelay = 0.4,             -- seconds from the start of the swing to the blow
-- 	DamageType = DMG_SLASH,
-- 	Force = 200,                -- knockback
-- 	Anim = nil,                 -- activity or sequence name; default Anims.Melee
-- 	Gesture = false,            -- true: play Anim over the body and keep moving
-- 	Duration = 1,               -- seconds the NPC is busy when there's no full-body animation
-- 	HitSound = nil, MissSound = nil, -- sound or list of sounds
-- }
ENT.Melee = nil

-- Voice. Each kind is a sound or a list (one picked at random). Kinds:
-- Alert (new enemy), Idle (now and then when idle), Pain, Death, Reload,
-- Attack (melee swing), Lost (gave up on an enemy). Only played when a player
-- is within ngl_ai_visual_range; lines don't overlap (VoiceCooldown).
ENT.Sounds = {}
-- Extra Sounds for some models, matched by part of the model path:
-- ENT.SoundsByModel = { ["female"] = { Pain = { ... } } }
ENT.SoundsByModel = nil
ENT.SoundLevel = 80
ENT.SoundPitch = 100
ENT.VoiceCooldown = 1.5         -- seconds after a voice line before the next one
ENT.IdleSoundDelay = { 8, 20 }  -- seconds between Idle lines

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
	Flinch  = { ACT_GESTURE_SMALL_FLINCH, ACT_GESTURE_FLINCH_CHEST, ACT_GESTURE_FLINCH_HEAD },
	-- Crouching (see CrouchChance). Models without these don't crouch.
	CrouchIdle = { ACT_COVER_LOW, ACT_CROUCHIDLE, ACT_RANGE_AIM_SMG1_LOW, ACT_RANGE_AIM_AR2_LOW },
	CrouchAim  = { ACT_RANGE_AIM_SMG1_LOW, ACT_RANGE_AIM_AR2_LOW, ACT_RANGE_AIM_LOW, ACT_COVER_LOW, ACT_CROUCHIDLE },
	CrouchWalk = { ACT_WALK_CROUCH_AIM_RIFLE, ACT_WALK_CROUCH_RIFLE, ACT_WALK_CROUCH },
	-- Full-body melee swing (see ENT.Melee).
	Melee   = { ACT_MELEE_ATTACK1, ACT_MELEE_ATTACK_SWING },
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
--                                   ~1 Hz far away); return true to skip all
--                                   of the default behaviour this think
-- ENT:OnIdle()                      no enemy; return true to skip the default
--                                   (investigate alerts, wander)
-- ENT:OnCombat(enemy, dist, visible) has an enemy; return true to skip the
--                                   default (chase, strafe, attack)
-- ENT:OnAttack(enemy, kind)         about to attack, kind = "ranged" or
--                                   "melee"; return true to skip it (do your own)
-- ENT:OnMeleeHit(target, hit)       a melee blow landed (hit = true) or missed
-- ENT:OnAlerted(ally, pos)          an ally spotted an enemy at pos; return
--                                   true to stay put
-- ENT:OnReload()                    started reloading
--
-- Building blocks (server; call them from hooks, see the end of init.lua):
--   Movement:  self:MoveTo(pos, run)  self:StopMoving()  self:IsMoving()
--              self:SetRunning(bool)  self:LookAt(posOrEnt)
--              self:SetCrouching(bool)  self:IsCrouching()
--   Targets:   self:GetEnemy()  self:SetEnemy(ent)  self:FindEnemy()
--              self:CanSee(ent)  self:IsEnemyVisible()  self:GetLastSeenPos()
--              self:IsHostileTo(ent)  self:GetAllies(radius)
--              NGL.FindInRadius(pos, radius, filter)
--   Combat:    self:FireWeapon(ent, shots)  self:MeleeAttack(ent)
--              self:FireProjectile(entOrPos, def)  self:DealDamage(ent, amount, type, force)
--   Animation: self:PlayAnim(actOrSequence, lock, rate)  self:PlayGesture(actOrSequence)
--   Sound:     self:Speak(kindOrPath)
--   State:     self:IsNearPlayer()  self:IsDetailed()  self:IsBusy()

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "NGLDead")
end
