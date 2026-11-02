# NGL Base

An NPC base for Garry's Mod built for large battles (100+ NPCs) with minimal server CPU load, in singleplayer and multiplayer, across gamemodes.

## Roadmap

1. **Benchmark harness and entity choice** (done). Stress test on a dedicated server, 67 tick, gm_construct: NextBot held 800 NPCs, our lightweight entity 400, stock `npc_combine_s` 200. **NextBot is the foundation.**
2. **NPC base core** (done). Central scheduler with a CPU budget, distance-based think rate, spatial grid, factions and a modding API. `ngl_combine_soldier` holds **1250** NPCs at 67 tick in the typical case (one player watching) and **800** in the worst case (every NPC thinking at 10 Hz and firing real bullets). Stock `npc_combine_s`: 200.
3. **Custom navigation** (done). Our own walk grid generated per map (no navmesh, no AI nodes), path-finding spread over ticks under a CPU budget, shared and cached paths.
3a. **Behaviour, animation and modding** (done). Weapon animations with level of detail, wandering, alerts, enemy memory; melee, entity-free projectiles, voice lines, and building blocks for custom behaviour. `ngl_combine_soldier` holds **800** at 67 tick with full animations (v0.4.1).
3b. **Squads, elite Combine, APC and dropship** (in progress). Squads and orders (v0.6.0), squad leaders and the elite Combine (v0.7.0), the APC with fire support from the elite (v0.8.0); next flying navigation and the dropship.
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
- `ngl_apc`: a vehicle NPC. Turret machine gun plus rockets, keeps its distance, takes the elite's orders when one is near, its own decisions otherwise (`DriveLikeVehicle`, `NavWidth`, `Commandable`).
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

### Squads and orders

A squad is a leader plus members (`max` counts the leader). Members keep a wedge formation behind the leader when there's nothing to fight, and when one of them spots an enemy the others go to look, however far away they are. A squad is a plain table, not an entity: it adds no per-tick work, members follow and obey inside their normal think.

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
- **Signals and voice:** hand signals come from `Anims.SignalHalt`, `SignalSearch`, `SignalEngage` and `SignalStandDown` (an upper-body gesture when the model has one, else the full-body signal while standing). Voice lines come from `Sounds.Halt`, `Search`, `Engage` and `StandDown`. Members act half a second after the signal, so players see it first.
- **Vehicles:** NPCs with `ENT.Commandable` of the leader's faction within `CommandRadius` (3000) report to it, without joining the squad. The leader calls a `fire_at` order on the nearest free one when the target hides (before the scouts go in) and when 3 or more enemies are packed around its target, at most every `FireSupportDelay` seconds (voice line `Sounds.CallFire`). Idle vehicles follow behind their commander.
- `OnLeaderThink(squad, now)` runs at the same rate for your own commands.

Testing in game (superadmin): `ngl_squad_make [size]` makes the NGL NPC you look at lead the nearest allies; `ngl_squad_order <hold|move|search|fire_at> [n]` orders that squad (or only the `n` nearest) at the spot you look at; `ngl_squad_info` lists squads.

### Behaviour

- **Idle:** strolls around its home spot (where it spawned or last fought) every few seconds at walking pace, with relaxed weapon animations (`WanderRadius`, `WanderDelay`, `WalkSpeed`; `WanderRadius = 0` stands still).
- **Alerted:** when an NPC spots an enemy, allies within `AlertRadius` (1500) that have nothing to do run over to look.
- **Fighting:** runs at the enemy with the weapon raised until in `AttackRange`, then strafes at walking pace and shoots, or now and then crouches and holds the spot (`CrouchChance`, 0.35; crouched it sees and shoots from `CrouchEyeHeight`). Reloads after `Weapon.Clip` shots (`Weapon.ReloadTime` seconds without firing).
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

1. Load the map, stand anywhere walkable, and run `ngl_nav_generate` (server console or superadmin). It flood-fills the walkable area from the map's spawn points and every player, spending at most `ngl_nav_gen_budget` ms per tick, and prints progress. On gm_construct expect around a minute.
2. The grid is saved to `garrysmod/data/ngl_nav/<map>.dat` and loaded automatically on that map from then on. Ship the file with your addon or server.

How NPCs use it:

- Enemy in view on the same level: straight line at any distance, no path-finding at all.
- Otherwise: an A* path is requested in the background. All searches share `ngl_nav_budget` ms per tick (default 2). Requests from roughly the same spot (within 3 grid cells) to roughly the same goal share one search, and results are cached for 4 s, so a squad chasing the same target pays for one or a few paths.
- An NPC never stands still waiting for a path. It walks straight at the target until the path arrives, gives up after 3 s, and walks straight for 3 s after a failed search.
- Wide NPCs (`ENT.NavWidth`, half width in units, e.g. 80 for the APC) get paths they fit through: their searches also test each grid point they reach with a box that wide, once, and remember the answer for later searches.
- Searches nobody is waiting for any more are dropped, and when `ngl_nav_max_queue` searches are queued new requests fail at once, so a flood of requests can't build a backlog.
- Waypoints advance in the per-tick steering, so far-away NPCs that think once a second still walk paths smoothly.
- An NPC that hasn't moved for 2 s drops its path and decides again. If it got stuck walking straight, it uses the grid for the next 5 s even with the enemy in view.
- No grid for the map: NPCs fall back to straight lines.
- Idle NPCs stroll along the grid with a random walk (a few table reads, no path search).
- Generating the grid takes effect at once; no restart needed.

| Command / ConVar | Meaning |
| --- | --- |
| `ngl_nav_generate` | Build and save the grid for the current map |
| `ngl_nav_info` | Points, spacing, queued searches, cached paths, and counts of found, failed, cached, dropped and rejected paths |
| `ngl_nav_draw [radius]` | Draw the grid around you for 15 s (listen server with `developer 1`) |
| `ngl_nav_reload` | Reload the saved grid |
| `ngl_nav_spacing` (96) | Grid spacing for generation. Smaller = more precise, more points |
| `ngl_nav_max_nodes` (150000) | Generation stops at this many points |
| `ngl_nav_budget` (2) | ms per tick for path-finding |
| `ngl_nav_max_expand` (8000) | A search gives up after this many points |
| `ngl_nav_max_queue` (64) | Requests beyond this many queued searches fail at once (the NPC walks straight) |

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
