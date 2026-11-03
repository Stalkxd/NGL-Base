# NGL Base

An NPC base for Garry's Mod built for large battles (100+ NPCs) with minimal server CPU load, in singleplayer and multiplayer, across gamemodes.

## Roadmap

1. **Benchmark harness and entity choice** (done). Stress test on a dedicated server, 67 tick, gm_construct: NextBot held 800 NPCs, our lightweight entity 400, stock `npc_combine_s` 200. **NextBot is the foundation.**
2. **NPC base core** (done). Central scheduler with a CPU budget, distance-based think rate, spatial grid, factions and a modding API. `ngl_combine_soldier` holds **1250** NPCs at 67 tick in the typical case (one player watching) and **800** in the worst case (every NPC thinking at 10 Hz and firing real bullets). Stock `npc_combine_s`: 200.
3. **Custom navigation** (done). Our own walk grid generated per map (no navmesh, no AI nodes), path-finding spread over ticks under a CPU budget, shared and cached paths.
3a. **Behaviour, animation and modding** (done). Weapon animations with level of detail, wandering, alerts, enemy memory; melee, entity-free projectiles, voice lines, and building blocks for custom behaviour. `ngl_combine_soldier` holds **800** at 67 tick with full animations (v0.4.1).
3b. **Squads, elite Combine, APC and dropship** (done). Squads and orders (v0.6.0), squad leaders and the elite Combine (v0.7.0), the APC with fire support from the elite (v0.8.0), flying navigation and the dropship bringing reinforcements (v0.9.0), the dropship carrying an APC (v0.10.0).
3c. **AI modes and groups** (done, v0.14.0). Four fighting styles modders can pick or extend, NPCs teaming up on their own, idle pauses, the APC following hills and patrolling.
3d. **Getting around** (done, v0.15.0). NPCs slide past each other instead of stopping, loose groups, jumping down ledges, doors opened or kicked in, the nav grid made on its own and editable with a tool, and an APC that sits on its wheels and gets itself off walls.
3e. **Finer grid, jumps and NPC tools** (done, v0.16.0). The grid gets into narrow halls and doorways, open floor is walked straight across, ledges are jumped up and down instead of walked into, climb links for climbing NPCs, and tools to watch NPCs and send them somewhere.
3f. **Moving well** (done, v0.17.0). Hops over low walls and through windows, stairs walked, paths that stay on one floor, NPCs that don't walk off the grid's edge or get stuck in each other, doors opened normally outside a fight, a nav editor that joins points by hand and shows as much of the grid as you want, the APC gun aimed in its own frame, dropships coming in from near the elite.
3g. **Square areas** (done, v0.18.0, v0.18.1). The grid merged into rectangles like GMod's navmesh, paths searched over them and drawn straight through them, NPCs pushed apart when they overlap, and no more stalling at door frames. In v0.18.1 the whole grid is squares, halls and doorways too: a hall's points stay in one straight row and join into a thin strip of squares.
3h. **Pushing, squares on hills** (done, v0.18.2, v0.18.3). NGL NPCs walk through each other and push each other aside instead of blocking or finding new paths; the editor's squares follow hills and ramps. In v0.18.3 the grid joins up over hilltops and ridges (walk checks follow the ground), and NPCs take shortcuts past waypoints when the way is clear, so paths on hills are straighter.
3i. **Faster nav** (v0.19.0). Unreachable goals fail at once, flow fields for many NPCs going to one place, squad members sharing their leader's path.
4. **Battle test.** Two teams of 100+ soldiers on several maps, singleplayer and dedicated server, tuned against the target.

**Target:** 300 NGL NPCs with real combat AI holding 67 tick (under 1% late ticks, `ngl_bench_limit`) on a local dedicated server on a normal PC. That's 3x the 100 goal, so weaker servers still manage 100+.

## Design rules

1. **Easy to mod, heavily optimized core.** Modders write a short NPC file with fields and optional hooks. They never touch the scheduler, movement or perception.
2. **Hooks run on events or at the AI rate, never every tick.** A mod can't accidentally make every NPC run expensive code 67 times a second.
3. **Pay for what players can see.** NPCs far from every player think less often and shoot with one silent trace instead of real bullets, but deal the same damage over time.
4. **Everything is measured.** Each optimization is checked with `ngl_bench_limit` before and after.

## Making an NPC

An NPC is one file, `lua/entities/<your_class>.lua`, in your own addon. Most NPCs need only fields; hooks and building blocks are there when you want custom behaviour.

```lua
AddCSLuaFile()
ENT.Base = "ngl_base"
ENT.PrintName = "My Soldier"

ENT.Model = { "models/combine_soldier.mdl", "models/combine_soldier_prisonguard.mdl" } -- one picked per NPC
ENT.Faction = "combine"      -- same faction = friends, others = enemies
ENT.StartHealth = 80
ENT.RunSpeed = 210
ENT.WeaponModel = "models/weapons/w_smg1.mdl"
ENT.Weapon = { Damage = 5, Delay = 0.12, Spread = 0.04, Clip = 30, ReloadTime = 2, Sound = "Weapon_SMG1.NPC_Single" }
ENT.Melee = { Damage = 15, Range = 60, Delay = 2, HitDelay = 0.35, DamageType = DMG_CLUB }
ENT.Sounds = {
	Alert = "npc/combine_soldier/vo/contact.wav",
	Pain = { "npc/combine_soldier/pain1.wav", "npc/combine_soldier/pain2.wav" },
	Death = "npc/combine_soldier/die1.wav",
}

list.Set("NPC", "my_soldier", { Name = "My Soldier", Class = "my_soldier", Category = "My NPCs" })
```

Every field, hook and building block is documented in `lua/entities/ngl_base/shared.lua`. Examples shipped (NPC tab, category "NGL Base"):

- `ngl_combine_soldier`: SMG plus a rifle-butt melee, voice lines.
- `ngl_rebel`: random faces, male and female voices via `SoundsByModel`, friendly to players.
- `ngl_zombie`: melee only, no code at all.
- `ngl_apc`: a vehicle NPC that drives like a car: it sits on the ground (the body pitches and rolls with the ground under its four wheels, `TrackWidth`, `MaxTilt`), slows down uphill and a little faster downhill (`SlopeSlow`), speeds up and brakes, steers with its front wheels (a bicycle model with `WheelBase` and `MaxSteer`), can't turn on the spot, and backs up to get round tight corners, away from enemies that get too close, or out of a wall it is stuck on. Wheels spin and steer on clients from how it moves (nothing extra networked), with HL2's APC engine loops. The turret machine gun fires from the barrel (`muzzle` attachment) with HL2's helicopter tracers and muzzle flash; rockets go up out of the launcher (`cannon_muzzle`) at HL2's launch angles, light after 0.3 s and curve onto the target, with a smoke trail. Takes the elite's orders when one is near, its own decisions otherwise: with nobody commanding it, it patrols round where it spawned (`ENT.Patrol = { Radius, MinDist, Pause }`, false to park), and in a fight the turret does the aiming while the body only shifts forward or back along the way it points (`RepositionDelay`, 12 to 20 s, sooner when it's getting hit), and an enemy too close in front makes it reverse, one behind makes it drive on, without swinging round. The wheels sit on the ground with working suspension (each wheel follows the ground under it on clients, with HL2's `vehicle_wheel_*_height` poses), the front wheels steer the right way, and clients turn the turret themselves every frame towards what the server says it aims at, so it tracks smoothly. Bullets throw sparks off it, not blood. Feelers (three short traces a few times a second) steer it round walls ahead; if it still hits something it backs up with the wheels turned so the nose swings to the open side and drives on that way, and after three of those in 20 seconds it gives up on where it was going and picks another way. Any vehicle NPC can drive itself with `ENT:NGLDrive(goal, dt)`; `ENT:NGLMuzzle()` sets where any NPC's shots start; projectiles can be guided (`Homing`, `Trail`).
- `ngl_combine_elite`: the first hard NPC. Super soldier model, AR2, tougher and more accurate, and leads up to 9 Combine soldiers with hand signals (`ENT.Squad`, see Squads and orders). Still no code beyond fields.

### Attacks

- **Gun:** `ENT.Weapon` (damage, fire rate, spread, clip, reload). Near players it fires real bullets with tracers and sound; far away it's one silent trace with the expected damage.
- **Projectiles:** add `Projectile = { Damage, Radius, Speed, Gravity, Model, ... }` to the weapon for rockets, grenades or spit (fields in `lua/ngl/server/sv_projectile.lua`). Projectiles are not entities: each is a table moved with one trace per tick, clients get one message when it's fired and one when it lands and draw it themselves, and far from players it lands at once without flying.
- **Melee:** `ENT.Melee = { Damage, Range, Delay, HitDelay, DamageType, Force, Anim, HitSound, MissSound }`. With no weapon the NPC closes in and swings; with a weapon it swings when the enemy gets into reach. The blow lands `HitDelay` after the swing starts, only if the target is still in reach and in front.
- **Custom:** `OnAttack(enemy, kind)` runs before each attack; return true and do your own with the building blocks below.

### Sounds

`ENT.Sounds` takes a sound or a list per kind: `Alert`, `Idle`, `Pain`, `Death`, `Reload`, `Attack` (melee swing), `Lost`. `ENT.SoundsByModel` adds overrides for models whose path contains a key (e.g. `["female"]`). Lines only play when a player is within `ngl_ai_visual_range`, never overlap (`VoiceCooldown`), and `Idle` lines come every `IdleSoundDelay` seconds.

### Hooks

| Hook | When | Return true to |
| --- | --- | --- |
| `OnSpawned()` | after spawning | |
| `OnSeeEnemy(enemy)` / `OnLoseEnemy(old)` | enemy gained / lost | |
| `OnAIThink(dt)` | every AI think | skip all default behaviour |
| `OnIdle()` | thinking with no enemy | skip investigate and wander |
| `OnCombat(enemy, dist, visible)` | thinking with an enemy | skip chase, strafe and attack |
| `OnAttack(enemy, kind)` | before a `"ranged"` or `"melee"` attack | skip that attack |
| `OnMeleeHit(target, hit)` | a blow landed or missed | |
| `OnAlerted(ally, pos)` | an ally spotted an enemy | stay put |
| `OnDamaged(dmginfo)` | taking damage | ignore the damage |
| `OnReload()`, `OnDeath(dmginfo)` | reload started, dying | |

Hooks run at the AI think rate or on events, never every tick, so a mod can't accidentally cost 67 calls a second per NPC.

### Building blocks

The default behaviour is built from these, so custom behaviour built from them gets the same optimizations (budgeted path-finding, grid enemy search, silent shots and no animation detail far from players).

| | |
| --- | --- |
| Movement | `self:MoveTo(pos, run)`, `self:StopMoving()`, `self:IsMoving()`, `self:SetRunning(bool)`, `self:LookAt(posOrEnt)`, `self:SetCrouching(bool)`, `self:IsCrouching()` |
| Targets | `self:GetEnemy()`, `self:SetEnemy(ent)`, `self:FindEnemy()`, `self:CanSee(ent)`, `self:IsEnemyVisible()`, `self:GetLastSeenPos()`, `self:IsHostileTo(ent)`, `self:GetAllies(radius)`, `NGL.FindInRadius(pos, radius, filter)` |
| Combat | `self:FireWeapon(ent, shots)`, `self:MeleeAttack(ent)`, `self:FireProjectile(entOrPos, def)`, `self:DealDamage(ent, amount, type, force)` |
| Animation | `self:PlayAnim(actOrSequence, lock, rate)` (whole body, returns duration), `self:PlayGesture(actOrSequence)` |
| Sound | `self:Speak(kindOrPath)` |
| State | `self:IsNearPlayer()`, `self:IsDetailed()`, `self:IsBusy()` |
| Orders | `self:GiveOrder(order)`, `self:GetOrder()`, `self:ClearOrder()` |
| AI mode | `self:SetAIMode(name)`, `self:GetAIMode()` |
| Squads | `self:MakeSquad(max)`, `self:GetSquad()`, `self:IsSquadLeader()`, `self:LeaveSquad()`, `squad:Add(npc)`, `squad:Order(who, order)`, `squad:Nearest(pos, n)`, `squad:Members()` |

Example: a brute that roars and charges when its enemy is far, and otherwise fights normally.

```lua
function ENT:OnCombat(enemy, dist, visible)
	if visible and dist > 600 and CurTime() > (self.NextCharge or 0) then
		self.NextCharge = CurTime() + 8
		self:Speak("Alert")
		self:PlayAnim(ACT_SIGNAL1)              -- roar; stands still and skips AI until done
		return true
	end
	if self.NextCharge and CurTime() < self.NextCharge - 6 then
		self:MoveTo(enemy:GetPos(), true)     -- charge for 2 s after the roar
		return true
	end
end
```

### AI modes

Each NPC fights in one of these styles, picked when it spawns from `ENT.AIMode` (a name, or weights for a random pick like `{ balanced = 3, flanker = 2, assault = 1, defender = 1 }`, which is what the Combine soldiers use):

| Mode | What it does |
| --- | --- |
| `balanced` | The default. Stands, crouches or sidesteps while shooting (`StandChance`, `CrouchChance`), chases what it loses sight of. |
| `assault` | Pushes forward no matter what: runs at the enemy shooting, never crouches or hides, and keeps pressing to where you went when it loses sight of you. |
| `flanker` | Attacks from out of your sight: circles round to a spot at your side or back that you can't see, opens fire from there, and moves to a new hidden spot after a few seconds. |
| `defender` | Holds the ground where the fight started (`DefendRadius`, 500): crouches and shoots from there, ducks out of sight when below half health, doesn't chase. |

Your own mode, from any addon:

```lua
NGL.RegisterAIMode("sniper", {
	StandChance = 0.8, CrouchChance = 0.2,          -- used by the default fight
	Fight = function(npc, enemy, dist, visible, now, dt)
		-- every think while it has an enemy and no order; return true when
		-- you handled it, nothing for the default fight
	end,
})
ENT.AIMode = "sniper"
```

`Fight` gets `visible = false` while the enemy is out of sight. Build it from the same pieces the built-in modes use (`NGL.Core.Chase`, `Shoot`, `Strafe`, `StopMoving`, `FindHiddenSpot`, `HiddenFrom`, `EyeOf`, `FacingYaw`, `GridSpot`, all in `sv_aimodes.lua` and `sv_core.lua`) or the building blocks above. Like every hook it runs at the AI rate. Testing (superadmin): `ngl_ai_mode <mode>` sets the NPC you look at, `ngl_ai_mode <mode> all` every NGL NPC; `ngl_ai_mode_override <mode>` makes every new NPC use one (empty = their own).

### Squads and orders

**Groups.** NPCs that don't lead a squad team up on their own with allies of the same faction nearby (`ENT.Group = { Max = 6, Radius = 800, Formation = "loose" }` by default; `false` keeps one alone, as the zombie does). A group nearby with room is joined first, so allies end up in one group rather than in pairs. The nearest ally leads; the others stand about near it, each at its own spot 90 to 240 units away, looking around, and only when the leader has moved off (380 units) do they stroll after it, each a moment apart, to new spots. No set places or marching in step: that's for real squads (the elite's wedge, line or column), or set `Formation` to one of those. They come to help when one of them spots an enemy; when the leader dies another member takes over, and a real squad leader (`ENT.Squad`, like the elite) nearby takes the group over. It costs one grid lookup every 3 to 5 seconds per idle NPC without a group.

A squad is a leader plus members (`max` counts the leader). Members keep formation around the leader when there's nothing to fight (each squad picks a wedge, a line or a column at random; `ENT.Squad.Formations` limits the choice, `squad:SetFormation(name)` changes it), and when one of them spots an enemy the others go to look, however far away they are. A squad is a plain table, not an entity: it adds no per-tick work, members follow and obey inside their normal think.

An order takes over an NPC's behaviour until it ends (`time` seconds, or a default per kind):

| Order | Fields | What the NPC does |
| --- | --- | --- |
| `hold` | `face`, `crouch = false` to stand | Stays put (crouched if it can), watches `face`, fights back from there |
| `move` | `pos`, `run`, `radius`, `hold = true` | Goes to `pos`, shooting what it sees on the way, then holds there if `hold` |
| `search` | `pos`, `radius` (400), `run = false` | Goes to `pos` and sweeps around it; seeing an enemy ends the order |
| `fire_at` | `pos`, `spread` (150) | Shoots at the area, seen or not |

Every order can carry `onDone = function(npc, order, reason)`; `OnOrderDone(order, reason)` gets the same reasons (`timeout`, `done`, `contact`, `replaced`, `cleared`). `OnOrder(order)` returning true means the NPC handles it itself. Extra kinds go in `ENT.OrderKinds = { mykind = true }` and run in your `OnAIThink`.

```lua
local sq = leader:MakeSquad(10)
for _, ally in ipairs(leader:GetAllies(1500)) do sq:Add(ally) end
sq:Order(sq:Nearest(lastSeen, 3), { kind = "search", pos = lastSeen, time = 20 })
```

**Leaders.** Any NPC with `ENT.Squad` set leads a squad on its own, twice a second inside its think:

```lua
ENT.Squad = {
	Max = 10,                            -- squad size, leader included
	Recruit = { "ngl_combine_soldier" }, -- classes it takes (nil = any ally)
	RecruitRadius = 1500,
	Scouts = 3, ScoutRadius = 400, ScoutTime = 20,
	LostDelay = 2,                       -- s out of sight before the squad halts
}
```

- **Recruiting:** every 2 seconds, until full, it takes the nearest allies of those classes that have no leader.
- **Target lost, not killed:** after `LostDelay` seconds with nobody in the squad seeing it, the leader signals halt and the whole squad holds, crouched, watching the last seen spot. 1.5 seconds later it signals forward and sends the `Scouts` nearest soldiers to search there. If anyone sees the enemy, the leader signals advance and everyone engages. If the scouts find nothing, it signals regroup and the squad forgets the target and falls back into formation.
- **Signals and voice:** hand signals come from `Anims.SignalHalt`, `SignalSearch`, `SignalEngage`, `SignalStandDown` and `SignalReinforce` (an upper-body gesture when the model has one; stock HL2 models only have full-body signals, so the leader stops for the second the signal takes). Voice lines come from `Sounds.Halt`, `Search`, `Engage`, `StandDown` and `Reinforce`, and always play, even right after another line. One member answers each order (`Sounds.Ack`). With `ENT.Radio` every voice line has a radio click before and after, as the Combine examples do. Members act half a second after the signal, so players see it first.
- **Vehicles:** NPCs with `ENT.Commandable` of the leader's faction within `CommandRadius` (3000) report to it, without joining the squad. The leader calls a `fire_at` order on the nearest free one when the target hides (before the scouts go in) and when 3 or more enemies are packed around its target, at most every `FireSupportDelay` seconds (voice line `Sounds.CallFire`). Idle vehicles follow behind their commander.
- **Reinforcements:** with `Reinforce = { Ship, Cargo, Count, OnFootCount, When }` in `ENT.Squad`, a leader in a fight with `When` (3) or fewer members left calls more. On maps with open sky a dropship (`ngl_dropship`) flies in from the edge of the sky, sets its HL2 troop pod down at a checked spot behind the squad, and `Count` soldiers climb out of it (HL2's `Dropship_Deploy` animation) and join the squad. The pod's gun fires at enemies within 2000 units while the ship is around. The ship uses HL2's flight, landing and liftoff animations, leans with `body_accel`/`body_sway`, and plays HL2's engine sounds on clients (near and far loops faded by distance, landing and on-ground loops). Or `OnFootCount` soldiers appear on foot close to the leader (700 to 1600 units away, its side away from the enemy first) at a spot neither the enemy nor any player can see (head and feet checked), never within 500 units of a player, and run to it. `ngl_reinforce_onfoot` picks: 0 = dropship under open sky, on foot only when it must; 1 = mixed, each wave at random (default, `ngl_reinforce_onfoot_chance` 0.5); 2 = always on foot. Under a roof, when the ship can't land near the leader, and on maps with no open sky they always come on foot. Server settings: `ngl_reinforce_limit` (3 waves per leader, -1 unlimited), `ngl_reinforce_cooldown` (90 s), `ngl_dropship_max` (2 in the air at once), `ngl_dropship_vulnerable` (0; 1 lets players shoot it down). Voice line `Sounds.Reinforce`.
- **Vehicle drops:** add `Vehicle = "ngl_apc"` (plus `VehicleLimit`, 1, and `VehicleThreat`, 4) and a wave can be a vehicle instead of soldiers: the dropship carries it under it and sets it down, and it joins the leader as a commandable asset. The leader asks for one when it has no vehicle left and the fight is heavy (the target is a player or a vehicle, or `VehicleThreat` enemies stand near it); `ChooseVehicle = function(leader, squad, enemy)` overrides that. With no open sky the vehicle drives in from out of sight. If it can't come, soldiers come instead. Setting `ngl_reinforce_apc` (1; 0 turns vehicle drops off).
- `OnLeaderThink(squad, now)` runs at the same rate for your own commands.

Testing in game (superadmin): `ngl_squad_make [size]` makes the NGL NPC you look at lead the nearest allies; `ngl_squad_order <hold|move|search|fire_at> [n]` orders that squad (or only the `n` nearest) at the spot you look at; `ngl_squad_info` lists squads.

### Behaviour

- **Idle:** strolls around its home spot (where it spawned or last fought) at walking pace with relaxed weapon animations, then stands a while (`WanderDelay`, 4 to 10 s) and looks around now and then before the next stroll (`WanderRadius`, `WalkSpeed`; `WanderRadius = 0` stands still). Group members hang about near their leader.
- **Crowds and pushing:** NGL NPCs don't collide with each other (`COLLISION_GROUP_NPC_SCRIPTED`; bullets, players, props and other NPCs still hit them), so in a group nobody blocks anybody and nobody has to find a new path. Instead an NPC walking into another one pushes it aside: the one in front (closer than their two widths to its line, touching or nearly) is moved off that line, to the side it's already on (right on the line: the walker's right, so two meeting head on slide past each other), and a little forward, for a third of a second at a time while they touch. Only when the walker is catching up with it (faster than it moves away). The walker keeps its path and speed. It uses the spatial grid and positions from each NPC's last think: no traces to find who's in front, and a short world-only hull trace a tick for the one being pushed, so it isn't pushed into a wall.
- **Pushing apart:** two NPCs standing inside each other (sidestepping in a fight, walking to the same spot) are both moved apart slowly until they're clear; nobody's path or goal changes. Right on top of each other, they agree which way each goes. An NPC spawned on top of another (spawn menu, squads, dropships) is moved to the nearest free spot round it on its first think.
- **Sidestepping** in a fight goes to one side, else the other, else half as far: somewhere with nobody standing there or halfway, room to walk there (one hull trace) and ground at the end (one trace down).
- **Drops:** walking anywhere not along a path (straight at an enemy, sidestepping, stepping aside), an NPC looks 40 units ahead with one trace down (again every 24 units walked or 0.25 s) and stops instead of walking off a drop deeper than 36; going straight at an enemy it then takes a path for the next 5 s. It's a trace, not the grid, so a patchy grid at a door frame doesn't stop anyone.
- **Door frames and corners:** in narrow places (grid points that aren't part of an open area) an NPC gets within 16 units of each waypoint before turning, instead of 40, so it doesn't cut the corner into the frame. Caught on something for a second anyway, one hull trace finds the wall and it slides along it, the way it was heading.
- **Ledges:** only short jumps, so nobody leaps off a roof to get at you. Paths jump down ledges up to `ENT.JumpDown` (200; zombies 250), up onto ledges up to `ENT.JumpUp` (72; zombies 0), over low walls, through windows and over small holes (vaults, as high as `JumpUp`) and across gaps (`ENT.JumpGap`). Down and across use the engine's jump with the `Jump`, `Glide` and `Land` animations; up is a short hop that rises first and then goes over the edge (`JumpUp`, then `Land`). Each NPC class can have its own jump animations in its `ENT.Anims` (HL2's `jump_holding_*` by default), so factions can jump differently. `ENT.JumpDown = 0`, `JumpUp = 0` and `JumpGap = false` keep an NPC off them (the APC).
- **Climbing:** `ENT.Climb` (0 = never) lets an NPC climb up and down climb links up to that high, placed with the NGL Nav Editor: straight up the wall and over the top, or over the edge and down, at `ENT.ClimbRate` units a second with the `ClimbUp` and `ClimbDown` animations. Meant for fast zombies, antlions and the like (none ship yet). Climbers can also climb ledges too high for them to jump.
- **Doors:** a closed door in the way is opened (`ENT.OpenDoors`, on for people, off for zombies and the APC). NPCs with `ENT.DoorBreach` (Combine and rebels) open it normally too, unless they're in a fight (an enemy, or one seen in the last 8 s) or it's locked: then they kick it in. Kicking, the NPC faces it and hits it with its melee animation (`Anims.Kick`; HL2's Combine use the rifle butt; models without one, like citizens, give it a shove), and the door flies off its hinges as a physics prop. The map's doors are put in a small grid once, so the check is a table lookup unless a door is right ahead. `ngl_door_breach` 2 = off the hinges (default), 1 = burst open, 0 = just open it; `ngl_door_respawn` (120 s, 0 = never) puts kicked-off doors back so map logic keeps working.
- **Alerted:** when an NPC spots an enemy, allies within `AlertRadius` (1500) that have nothing to do run over to look.
- **Fighting:** depends on the AI mode (above). The default runs at the enemy with the weapon raised until in `AttackRange`, then shoots while sidestepping at walking pace, standing still (`StandChance`, 0.3) or crouching to hold the spot (`CrouchChance`, 0.35; crouched it sees and shoots from `CrouchEyeHeight`). Reloads after `Weapon.Clip` shots (`Weapon.ReloadTime` seconds without firing).
- **Enemy out of sight:** heads for where it last saw the enemy (no seeing through walls), and gives up after `EnemyMemory` seconds or once it gets there and finds nobody.
- **Animations:** idle, alert idle, walk, run, aimed walk and aimed run, crouched idle, aim and walk picked per state; firing, reload and flinch gestures; upper body aims at the enemy. Strafing keeps the body on the target while the legs swing smoothly (every tick, eased) to the direction of travel, anywhere a player can see the NPC (`ngl_ai_visual_range`); standing or crouched, the upper body aims and the feet stay planted until the target is more than 45° off; running always faces where the NPC goes, with the gun raised only when the target is ahead. Walk/run cycles play at the speed the NPC actually moves. Models without crouch animations simply don't crouch. See the level of detail below.
- **Animation level of detail:** within `ngl_anim_detail_range` (1500) of a player, NPCs get everything above. Further out they play only the plain idle, walk and run cycles: no aim pose, no gestures, no aimed variants with their extra aim layers, and their poses are reset once when they leave the range. This saves server time and, more importantly, drawing time on every client. Clients also skip drawing NPC weapons beyond `ngl_cl_weapon_range` (4000, client setting; 0 = always).

Examples shipped: `ngl_combine_soldier`, `ngl_combine_elite`, `ngl_apc`, `ngl_rebel` and `ngl_zombie` (NPC tab, category "NGL Base").

### How the core keeps it cheap

- **Per tick**, each NPC only steers towards its current goal (`BehaveUpdate`: one `Approach`, one `FaceTowards`) and advances its animation. The stock NextBot coroutine is not used. The aim pose updates at the think rate within `ngl_anim_detail_range`; the leg (strafe) pose every tick within `ngl_ai_visual_range`. Beyond that NPCs face where they walk, so their legs need no pose.
- **Decisions** (targets, chase or strafe, shooting) run in one central hook under a CPU budget (`ngl_ai_budget`, default 3 ms per tick). NPCs that don't fit think on the next tick.
- **Think rate depends on the nearest player**: every 0.1 s within 1500 units, 0.3 s within 4000, 1 s further away (`ngl_ai_near`, `ngl_ai_mid`, `ngl_ai_rate_*`).
- **Enemy search uses a 1024-unit spatial grid**, so cost depends on nearby NPCs, not all of them. Line of sight is checked for at most the 3 closest candidates, once per second.
- **Far from players** (`ngl_ai_visual_range`, 3000), shots are one silent trace dealing the expected damage, so far battles cost almost nothing but still play out.
- **Death ragdolls are client-side** by default (`ngl_ragdolls 1`), and the weapon model is client-only.
- `ngl_status` prints the NPC count and grid usage.

## Navigation

NGL NPCs use their own walk grid instead of the navmesh or AI nodes.

1. On a map with no grid it's made on its own a few seconds after the map loads (or when the first player spawns, on maps without spawn points). `ngl_nav_auto 0` turns that off; then run `ngl_nav_generate` (server console or superadmin), which also rebuilds it any time. It flood-fills the walkable area from the map's spawn points and every player, spending at most `ngl_nav_gen_budget` ms per tick, and prints progress. On gm_construct expect a minute or two. Doors don't block it (NPCs open or kick them).
   - **Spacing:** points every `ngl_nav_spacing` units (64 by default), close enough for small staircases and tight spots.
   - **Narrow places:** a point that doesn't fit at its spot in the grid (a person-sized box, 26 wide) is moved within its square to the nearest spot that fits, so halls and doorways narrower than the grid spacing get points too, and so do the edges of rooms. Over a hilltop or a ridge the straight line between two points goes into the ground, so when that one hull trace hits something the walk check tries again in short pieces that follow the ground; the hill stays one big area instead of breaking up into moved points. Going along a hall it first tries the spot in line with the point it came from, so the hall's points stay in one straight row; and a moved spot right next to a point that's already there is skipped, so a hall never gets two rows side by side.
   - **Only real walking:** two points are linked for walking only when the ground between them has no step higher than a person can step (more on slopes, as steep as the ground) and no hole. A ledge too high to step up is a jump: up to `ngl_nav_max_up` (72) gets a jump-up link, and a drop with ground further down (up to `ngl_nav_max_drop`, 250) a jump-down link (`ngl_nav_drops 0` turns both off). Something in the way at the same level (a low wall, a window sill, a hole) gets a vault link when a crouched hop over it fits, as low as it can go and no higher than `ngl_nav_max_up`, with room to stand on the far side. Stairs are walked: where two ground samples differ by more than a step, the grid looks in between, so several small steps pass and one big one doesn't.
   - **Areas:** the grid is merged into rectangles, like the areas of GMod's own navmesh: a block of points (up to 16 squares a side) where every square inside is open floor, so anywhere in it can be walked to in a straight line. Points that don't fit in one are joined into strips: a straight row of points (a hall, a doorway, the edge of a room or a ledge) is one long thin area, one square wide. Whatever's left is a single square. Every area is a square or a rectangle of squares, reaching half a square past its points where there's floor next to it and 16 units where there's a wall. Paths are searched over areas, far fewer than points (an open 60 x 60 test map: 3721 points, 186 areas), and drawn straight through them: the path goes through the edges between areas the shortest way (a "funnel"), so it only turns at real corners. In narrow places it goes point to point, and NPCs get within 16 units of those points before turning. Wide NPCs (`ENT.NavWidth`) still search point by point, so their width is checked everywhere.
   - **Open triangles:** three points all linked to each other (two sides of a grid square and its diagonal) close a triangle of open floor, and two of them make a square. Paths cut straight across open areas instead of following the grid lines, but only through triangles that share a corner with the last one, so a straight line never jumps between two floors (under a walkway and onto it, say); NPCs follow the lines in narrower places.
2. The grid is saved to `garrysmod/data/ngl_nav/<map>.dat` and loaded automatically on that map from then on. Ship the file with your addon or server. Grids from before v0.17.0 are made again on their own (edits are kept).
3. Fix it in game with the **NGL Nav Editor** tool (Q menu, Tools, NGL Base; superadmins). While the tool is out it shows the grid inside a sphere round you, as big as **View distance** in its panel (`ngl_nav_view_radius`, 200 to 20000, so you can see the whole map): every area, halls and doorways included, as a faintly filled square or rectangle with a see-through outline, like GMod's navmesh (drawn whole when they reach out of the sphere; each grid point's square is four triangles from the point itself to corners at the height of the points round it, so the squares lie on hills and ramps), points joined by hand as blue lines, yellow jumps down, orange jumps up, green gap jumps, purple climbs, pink vaults, and a circle where you aim (in the two-click modes, a small sphere on the grid point a click would use). It's sent again only when you move, change the size or the grid changes, compressed, in pieces. **Walkable area mode:** left click adds walkable area right where you click and round it (flood-filled within the radius, joined up with the grid around it; works in tight spots); when nothing is added it says what stopped it (walls, steps too high, ledges). Right click removes the grid there (only on that floor). **Jump links mode:** left click where the jump starts, then where it lands: a jump down if it's lower, a jump up if it's higher (up to 128), a gap jump both ways if it's level. **Climb links mode:** left click one end, then the other: a climb both ways, any height, for NPCs with `ENT.Climb`. **Connect mode:** left click a grid point, then another (up to 512 away): NPCs walk between them both ways, for a doorway or a narrow place the grid didn't get through. In the link and connect modes right click removes links near the spot. Reload undoes the last edit. Edits are saved apart from the grid (`garrysmod/data/ngl_nav/<map>_edits.txt`, by position) and put back on whenever it's loaded or made again; `ngl_nav_edit_clear` removes them all.

How NPCs use it:

- Enemy in view on the same level (or a short hop to its squad spot): straight line, no path-finding, as long as the grid says nothing's in the way. That check is table lookups along the line (open squares, or point to linked point), at most once a second per NPC; a ledge, wall or drop in the way means a path round it instead, so followers go round to their leader rather than walking into a wall.
- Otherwise: an A* path is requested in the background. All searches share `ngl_nav_budget` ms per tick (default 2). Requests from roughly the same spot (within 3 grid cells) to roughly the same goal share one search, and results are cached for 4 s, so a squad chasing the same target pays for one or a few paths.
- **Islands:** after the grid or its links change, one pass labels which points can reach which (walking, and walking plus any jump, drop or climb). A path to a spot that can't be reached (another floor with no way up, a fenced-off yard, down a cliff for an NPC that can't jump) fails at once instead of searching everything first.
- **Flow fields:** when 4 requests from different places want the same goal region within 3 s (a squad or a horde chasing one player), one search goes outward from the goal over the areas (up to 8000 of them) and every NPC's path is read off it from its own area, no search of its own; later requests for that goal come back at once. A field lasts 4 s; NPCs beyond its reach search as before. Paths are as short as their own search would give.
- **Squad path sharing:** a squad member chasing where its leader's path goes (within 300 units of the same target) joins that path at the point nearest it (within 160 units, on the same floor, straight there by the grid) instead of asking for one, as long as it has the same jumps and width.
- An NPC never stands still waiting for a path. It walks straight at the target until the path arrives, gives up after 3 s, and walks straight for 3 s after a failed search.
- Paths take the jumps and climbs the NPC can (`JumpDown`, `JumpUp`, `JumpGap`, `Climb`; see Behaviour), costing a little more than walking; NPCs that can't never get them.
- Paths are smoothed: across open areas an NPC walks straight to the next corner instead of along each grid line.
- **Shortcuts:** where the grid is patchy (hills, rubble) and the path zig-zags from point to point, an NPC checks every 0.4 s whether it can walk straight past its next waypoint to one up to 3 further on: one hull trace there and the ground under the line every 32 units (no hole, no drop, nothing steeper than 45 degrees). Never past a jump, drop or climb on the path, and not for wide NPCs.
- Wide NPCs (`ENT.NavWidth`, half width in units, e.g. 80 for the APC) get paths they fit through: their searches also test each grid point they reach with a box that wide, once, and remember the answer for later searches.
- **Air layer** for flying NPCs: built automatically in the background from the grid once it loads (no file, a few hundred traces). Every 4th grid point with open sky above gets one air node up to 1200 units over the ground, linked to its neighbours when a dropship fits between them; nodes at the edge of the sky are where ships come and go: the one about 3000 units from where the ship lands (by the elite who called it), on the side away from the enemy, with a little chance in it. Landing spots are checked when needed: flat ground and a clear column straight down from the air layer. `ngl_air_info` prints its state.
- Searches nobody is waiting for any more are dropped, and when `ngl_nav_max_queue` searches are queued new requests fail at once, so a flood of requests can't build a backlog.
- Waypoints advance in the per-tick steering, so far-away NPCs that think once a second still walk paths smoothly.
- An NPC that hasn't moved for 1 s slides along whatever it's caught on (see Behaviour); after 2.5 s it drops its path and decides again. If it got stuck walking straight, it uses the grid for the next 5 s even with the enemy in view.
- No grid for the map: NPCs fall back to straight lines.
- Idle NPCs stroll along the grid with a random walk (a few table reads, no path search).
- Generating the grid takes effect at once; no restart needed.

| Command / ConVar | Meaning |
| --- | --- |
| `ngl_nav_generate` | Build and save the grid for the current map |
| `ngl_nav_auto` (1) | Make the grid on its own for maps that have none |
| `ngl_nav_drops` (1) | Link ledges up and down when generating |
| `ngl_nav_max_drop` (250) | Highest ledge linked for jumping down |
| `ngl_nav_max_up` (72) | Highest ledge linked for jumping up |
| `ngl_nav_edit_clear` | Remove all NGL Nav Editor edits for this map |
| `ngl_nav_info` | Points, jump links, edits, spacing, queued searches, cached paths, and counts of found, failed, cached, dropped and rejected paths |
| `ngl_nav_draw [radius]` | Draw the grid around you for 15 s (listen server with `developer 1`) |
| `ngl_nav_reload` | Reload the saved grid |
| `ngl_nav_spacing` (64) | Grid spacing for generation. Smaller = more precise, more points |
| `ngl_nav_max_nodes` (300000) | Generation stops at this many points |
| `ngl_nav_budget` (2) | ms per tick for path-finding |
| `ngl_nav_max_expand` (16000) | A search gives up after this many points |
| `ngl_nav_max_queue` (64) | Requests beyond this many queued searches fail at once (the NPC walks straight) |

## NPC tools

Two tools in the Q menu (Tools, NGL Base; superadmins):

- **NGL NPC Tracker:** left click NGL NPCs to track them (up to 8; again to stop), right click to stop all. For each one you see where it has been (white trail), its path ahead (blue, with jumps down in yellow, jumps up in orange, climbs in purple), where it's heading (green ring), where a player sent it (pink ring), and a line over its head: class, AI mode, order, squad, enemy and how it's moving. Shown while the tool is out, or always with the tool's checkbox (`ngl_track_always 1`). Only tracked NPCs cost anything: they're sent five times a second to whoever tracks them.
- **NGL NPC Mover:** left click NGL NPCs to pick them (green rings), then right click (or left click the ground) to send them there. They spread out round the spot, find their way along the grid, shoot enemies on the way, and with "Stay there" hold the spot for a minute. Their squad leader can't call them off it until they arrive. Reload drops the picked ones.

## Installing

Copy (or clone) this folder into `garrysmod/addons/ngl-base`, then restart the map.

## Running the benchmark

Commands need superadmin (the host in singleplayer) or the server console. Look at an open flat area first, since NPCs spawn where you aim. `gm_flatgrass` or `gm_construct` work well.

| Command | What it does |
| --- | --- |
| `ngl_bench <class> <count>` | One run, e.g. `ngl_bench ngl_bench_light 100` |
| `ngl_bench_compare [count]` | `ngl_combine_soldier` vs bench NextBot vs `npc_combine_s` at the same count (default 100) |
| `ngl_bench_sweep <class> <c1,c2,...>` | Several counts in a row, e.g. `ngl_bench_sweep ngl_bench_light 25,50,100,200` |
| `ngl_bench_limit [class\|all] [start]` | Stress test: climbs 100, 200, 300 ... 2000 NPCs until more than 1% of ticks are late, and prints the highest count that held. `all` (default) does `ngl_combine_soldier`, the bench NextBot and `npc_combine_s` |
| `ngl_bench_stop` | Abort and remove everything |
| `ngl_bench_clear` | Remove benchmark NPCs |

Each run samples the empty server, spawns the NPCs in two facing teams, waits for warmup, then samples while they chase, strafe and shoot. The report shows:

- **Server frame, empty / loaded**: the engine's own server frame time, which includes engine AI, physics, networking and Lua. `engine.ServerFrameTime()` is client-only, so the client that ran the command (or the first player, for console runs) samples the value net_graph shows and reports it back. A dedicated-server run from the server console with nobody connected only gets Lua time.
- **Added by NPCs**: loaded minus empty, per tick and per NPC, and the share of the tick budget used.
- **Bench AI Lua only**: time spent in our own Lua for the two test entities.
- **Late ticks, empty / loaded**: ticks that arrived more than 1.5x the tick interval late. Compare the two: in singleplayer, late ticks often come from a low client FPS rather than the NPCs.
- **Client FPS**: the reporting client's framerate during the loaded phase.

Results are also saved as JSON in `garrysmod/data/ngl_bench/`.

### Settings

| ConVar | Default | Meaning |
| --- | --- | --- |
| `ngl_bench_baseline` | 5 | Seconds of empty sampling |
| `ngl_bench_warmup` | 5 | Seconds after spawning before sampling |
| `ngl_bench_duration` | 20 | Seconds of loaded sampling |
| `ngl_bench_gap` | 1600 | Distance between the teams at spawn |
| `ngl_bench_spacing` | 60 | Spacing inside a team |
| `ngl_bench_god` | 1 | Huge health, so the NPC count stays constant |
| `ngl_bench_bullets` | 0 | 1 = real `FireBullets` with tracers, 0 = one trace per shot |
| `ngl_bench_keep` | 0 | Keep NPCs after the run |
| `ngl_bench_weapon` | weapon_smg1 | Weapon for engine `npc_*` classes |

### The two test entities

Both run the same decision code (`lua/ngl/server/sv_bench_ai.lua`), so the comparison is about the foundation, not the AI.

- `ngl_bench_nextbot`: stock NextBot with engine locomotion and animation. It moves with `loco:Approach` and no path-finding, so a real path-finding NextBot costs more.
- `ngl_bench_light`: `base_anim` entity with no per-entity Think. One `Tick` hook drives all of them, movement is `SetPos` plus one ground trace, collision is a bounding box, and animation plays on the client.

### Getting trustworthy numbers

On singleplayer or a listen server the "server frame" is really the whole game frame, including rendering, so only the Lua line means anything there. The harness prints a warning in that case, and also when the game window lost focus (GMod sleeps 50 ms per frame in the background).

For real numbers, run a local dedicated server on the same PC:

1. Download [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD), then at its prompt run `force_install_dir C:\gmodserver`, `login anonymous`, `app_update 4020 validate`.
2. Copy this addon into its `garrysmod/addons/` folder.
3. Start it with a `start.bat` in that folder containing `srcds.exe -console -game garrysmod +map gm_flatgrass +maxplayers 2` (`srcds_win64.exe` if your game is on the x86-64 branch, `srcds_run` on Linux). Without `-console` you get a GUI window whose console is on the "Console" tab.
4. Join it from your game with `connect localhost`.
5. Type commands in the **server console window**. NPCs spawn where the first player is looking, so stand somewhere open; gm_flatgrass fits the big counts.

On a dedicated server the frame time reported by net_graph is wall time per frame **including the idle sleep**, so it sits at the tick interval (about 15 ms at 66 tick) until the server overloads. The useful numbers there are late ticks and the `ngl_bench_limit` stress test, which finds the NPC count where the server can no longer keep its tick rate.

## Results

| Date | Map | Server | Class | Count | Added ms/tick | us/NPC | Late ticks |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |
