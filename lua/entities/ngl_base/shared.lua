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
ENT.StandChance = 0.3           -- chance, each time it picks a new spot while fighting, to just stand and shoot instead of sidestepping
ENT.AIMode = "balanced"         -- how it fights (sv_aimodes.lua): "balanced", "assault" (pushes forward no matter what),
--                                 "flanker" (attacks from out of your sight), "defender" (holds its ground), your own
--                                 NGL.RegisterAIMode, or weights for a random pick: { balanced = 2, flanker = 1 }
ENT.DefendRadius = nil          -- "defender" mode: how far it may move from where the fight started (default 500)
ENT.Group = nil                 -- NPCs without ENT.Squad team up with allies of their faction nearby: { Max = 6, Radius = 800, Formation = "loose" }
--                                 (these defaults when nil); false = always alone (zombies, animals).
--                                 loose: members stand about near the leader and stroll after it;
--                                 or "wedge", "line", "column" for a set formation
-- Jumping, climbing and doors (sv_nav.lua, sv_doors.lua). The nav grid links
-- ledges up and down; paths use the ones this NPC can take. Only short
-- jumps: nobody leaps off a roof to get at you.
ENT.JumpDown = 200              -- jumps down ledges up to this high (units); 0 = never
ENT.JumpUp = 72                 -- jumps up onto ledges up to this high; 0 = never
ENT.JumpGap = true              -- jumps across gaps (jump links placed with the NGL Nav Editor tool)
ENT.Climb = 0                   -- climbs up and down climb links up to this high (placed with the tool;
								-- for fast zombies, antlions and the like); 0 = never
ENT.ClimbRate = 250             -- units per second up or down a climb
--                                 (ngl_nav_generate puts climb links at walls too high to jump,
--                                 up to ngl_nav_max_climb: only there, not on open ledges)
ENT.OpenDoors = true            -- opens closed doors in its way
ENT.DoorBreach = false          -- kicks doors in instead, locked ones too (Combine, rebels); see ngl_door_breach
ENT.Squad = nil                 -- set to lead a squad on its own, see sv_squad.lua:
--                                 { Max = 10, Recruit = { "ngl_combine_soldier" }, RecruitRadius = 1500,
--                                   Scouts = 3, ScoutRadius = 400, ScoutTime = 20, LostDelay = 2 }
ENT.NavWidth = nil              -- half width for path-finding when wider than a person (vehicles: ~80)
ENT.Hull = nil                  -- { mins, maxs } collision box when not a person's (headcrabs: small)
ENT.DriveLikeVehicle = false    -- turns to face where it goes before moving, never strafes
ENT.Commandable = false         -- squad leaders of its faction nearby may order it (vehicles)
ENT.OrderKinds = nil            -- { mykind = true }: extra order kinds this NPC runs itself (in OnAIThink)
ENT.EnemyMemory = 8             -- seconds it keeps hunting an enemy it can't see (heads to where it last saw it)
ENT.AlertRadius = 1500          -- allies this close with nothing to do come to help when it spots an enemy; 0 = never
ENT.WanderRadius = 600          -- idle NPCs stroll around their home spot (where they spawned or last fought); 0 = stand still
ENT.WanderDelay = { 4, 10 }     -- seconds it stands around between strolls

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
-- 	HitDelay = 0.4,             -- seconds from the start of the swing to the blow; a list ({ 0.2, 0.45 })
-- 	                            -- for several blows. Models with HL2 zombie hit events (AE_ZOMBIE_ATTACK_*)
-- 	                            -- hit on those instead, one blow each; UseEvents = false to turn that off
-- 	DamageType = DMG_SLASH,
-- 	Force = 200,                -- knockback
-- 	Anim = nil,                 -- activity or sequence name; default Anims.Melee
-- 	Gesture = false,            -- true: play Anim over the body and keep moving
-- 	Duration = 1,               -- seconds the NPC is busy when there's no full-body animation
-- 	HitSound = nil, MissSound = nil, -- sound or list of sounds
-- }
ENT.Melee = nil

-- Leap attack (headcrabs, fast zombies; sv_leap.lua); nil for none. An NPC
-- with no Weapon leaps at an enemy it can see between MinDist and MaxDist
-- when the way is clear, and hurts it if it touches it on the way.
-- ENT.LeapAttack = {
-- 	Damage = 10,
-- 	MinDist = 0, MaxDist = 250,   -- leaps at enemies this far away
-- 	MaxRise = 96,                 -- not at enemies more than this above it
-- 	Delay = 3,                    -- seconds between leaps
-- 	Chance = 1,                   -- chance to leap each time it could (0.5 checks a second later otherwise)
-- 	Reach = 32,                   -- touching distance in flight
-- 	DamageType = DMG_SLASH, Force = 200,
-- 	Poison = false,               -- true: HL2 poison bite, takes a player down to 1 health (NPCs take NPCDamage)
-- 	NPCDamage = nil,              -- damage to NPCs when Poison
-- 	Anim = nil, LandAnim = nil,   -- activity, sequence name or a list tried in order (Anim: in the air)
-- 	Velocity = nil,               -- "hl2": HL2's jump (at the target's middle, 16..120 up, max 1000 u/s);
-- 	                              -- nil: the engine's gap jump at its feet
-- 	WindUp = nil,                 -- seconds gathering itself before it springs (nil: at once), playing
-- 	WindUpAnim = nil,             -- this, and springing at the model's WindUpEvent when it has it
-- 	WindUpEvent = nil,            -- (e.g. "AE_FASTZOMBIE_LEAP"); keeps turning to face the target
-- 	WindUpSound = nil,            -- Sounds kind or sound path, when it starts winding up
-- 	Sound = nil,                  -- Sounds kind ("Leap") or a sound path, at take-off
-- 	HitSound = nil,               -- sound or list, when it hits
-- 	Recover = 0.4,                -- seconds after landing before it does anything else
-- }
ENT.LeapAttack = nil

-- Zombies: the headcrab that comes off when it dies (sv_zombies.lua), an
-- NGL headcrab class, or nil. Not when the head was hit or it was blown up
-- (HL2 rules). ngl_zombie_headcrabs 0 turns it off, ngl_headcrab_max caps
-- the crabs alive at once.
ENT.Headcrab = nil
ENT.HeadcrabBodygroup = nil     -- bodygroup that shows the crab on the model (1 on HL2 zombies)

-- Voice. Each kind is a sound or a list (one picked at random). Kinds:
-- Alert (new enemy), Idle (now and then when idle), Pain, Death, Reload,
-- Attack (melee swing), Lost (gave up on an enemy), Kill (its enemy died),
-- Ack (answering a squad order); squad leaders also Halt, Search, Engage,
-- StandDown, Reinforce, CallFire. Only played when a player is within
-- ngl_ai_visual_range; lines don't overlap (VoiceCooldown).
ENT.Sounds = {}
-- Radio clicks around voice lines: { On = { ... }, Off = { ... } } or nil.
ENT.Radio = nil
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
	-- Jumping (nav links), climbing (ENT.Climb) and breaking a door in
	-- (DoorBreach). Each NPC class can have its own: put your faction's
	-- jump here. Sequence names work too, like activities. JumpUp: onto a
	-- ledge (falls back to Jump). Kick: HL2's Combine hit the door with the
	-- rifle butt.
	Jump    = { "jump_holding_jump", ACT_JUMP },
	JumpUp  = { "jump_holding_jump", ACT_JUMP },
	Glide   = { "jump_holding_glide", ACT_GLIDE },
	Land    = { "jump_holding_land", ACT_LAND },
	ClimbUp   = { ACT_CLIMB_UP },
	ClimbDown = { ACT_CLIMB_DOWN, ACT_CLIMB_UP },
	Kick    = { ACT_MELEE_ATTACK1, ACT_MELEE_ATTACK_SWING },
	-- Squad leader hand signals (see ENT.Squad): an upper-body gesture when
	-- the model has one, otherwise the full-body signal while standing.
	SignalHalt      = { ACT_GESTURE_SIGNAL_HALT, ACT_SIGNAL_HALT },
	SignalSearch    = { ACT_GESTURE_SIGNAL_FORWARD, ACT_SIGNAL_FORWARD },
	SignalEngage    = { ACT_GESTURE_SIGNAL_ADVANCE, ACT_SIGNAL_ADVANCE },
	SignalStandDown = { ACT_GESTURE_SIGNAL_GROUP, ACT_SIGNAL_GROUP },
	SignalReinforce = { ACT_GESTURE_SIGNAL_GROUP, ACT_SIGNAL_GROUP },
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
-- ENT:OnAttack(enemy, kind)         about to attack, kind = "ranged", "leap" or
--                                   "melee"; return true to skip it (do your own)
-- ENT:OnMeleeHit(target, hit)       a melee blow landed (hit = true) or missed
-- ENT:OnLeapHit(target, hit)        a leap hit (hit = true) or landed without
--                                   touching anyone; OnAttack(enemy, "leap")
--                                   runs before each leap
-- ENT:OnAlerted(ally, pos)          an ally spotted an enemy at pos; return
--                                   true to stay put
-- ENT:OnReload()                    started reloading
-- ENT:OnOrder(order)                given an order; return true to handle it
--                                   yourself (it is not stored)
-- ENT:OnOrderDone(order, reason)    an order ended ("timeout", "done",
--                                   "contact", "replaced", "cleared")
-- ENT:OnLeaderThink(squad, now)     squad leaders (ENT.Squad), twice a second
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
--              self:Leap(entOrPos, def)  self:CanLeap(ent)  self:IsLeaping()
--   Animation: self:PlayAnim(actOrSequence, lock, rate)  self:PlayGesture(actOrSequence)
--   Sound:     self:Speak(kindOrPath)
--   State:     self:IsNearPlayer()  self:IsDetailed()  self:IsBusy()
--   Orders:    self:GiveOrder(order)  self:GetOrder()  self:ClearOrder()
--   Signals:   self:NGLSignal("Halt" | "Search" | "Engage" | "StandDown" | "Reinforce")
--   AI mode:   self:SetAIMode(name)  self:GetAIMode()
--   Squads:    self:MakeSquad(max)  self:GetSquad()  self:IsSquadLeader()
--              self:LeaveSquad()  squad:Add(npc)  squad:Order(who, order)
--              squad:Nearest(pos, n)  squad:Members()  NGL.NewSquad(leader, max)

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "NGLDead")
end
