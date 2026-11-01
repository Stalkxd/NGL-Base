# NGL Base

An NPC base for Garry's Mod built for large battles (100+ NPCs) with minimal server CPU load, in singleplayer and multiplayer, across gamemodes.

## Roadmap

1. **Benchmark harness and entity choice** (done). Stress test on a dedicated server, 67 tick, gm_construct: NextBot held 800 NPCs, our lightweight entity 400, stock `npc_combine_s` 200. **NextBot is the foundation.**
2. **NPC base core** (done). Central scheduler with a CPU budget, distance-based think rate, spatial grid, factions and a modding API. `ngl_combine_soldier` holds **1250** NPCs at 67 tick in the typical case (one player watching) and **800** in the worst case (every NPC thinking at 10 Hz and firing real bullets). Stock `npc_combine_s`: 200.
3. **Custom navigation** (in progress). Our own walk grid generated per map (no navmesh, no AI nodes), path-finding spread over ticks under a CPU budget, shared and cached paths.
4. **Battle test.** Two teams of 100+ soldiers on several maps, singleplayer and dedicated server, tuned against the target.

**Target:** 300 NGL NPCs with real combat AI holding 67 tick (under 1% late ticks, `ngl_bench_limit`) on a local dedicated server on a normal PC. That's 3x the 100 goal, so weaker servers still manage 100+.

## Design rules

1. **Easy to mod, heavily optimized core.** Modders write a short NPC file with fields and optional hooks. They never touch the scheduler, movement or perception.
2. **Hooks run on events or at the AI rate, never every tick.** A mod can't accidentally make every NPC run expensive code 67 times a second.
3. **Pay for what players can see.** NPCs far from every player think less often and shoot with one silent trace instead of real bullets, but deal the same damage over time.
4. **Everything is measured.** Each optimization is checked with `ngl_bench_limit` before and after.

## Making an NPC

Create `lua/entities/<your_class>.lua` in your own addon:

```lua
AddCSLuaFile()
ENT.Base = "ngl_base"
ENT.PrintName = "My Soldier"

ENT.Model = "models/combine_soldier.mdl"
ENT.Faction = "combine"      -- same faction = friends, others = enemies
ENT.StartHealth = 80
ENT.RunSpeed = 210
ENT.WeaponModel = "models/weapons/w_smg1.mdl"
ENT.Weapon = { Damage = 5, Delay = 0.12, Spread = 0.04, Accuracy = 0.6, Sound = "Weapon_SMG1.NPC_Single" }

list.Set("NPC", "my_soldier", { Name = "My Soldier", Class = "my_soldier", Category = "My NPCs" })

if SERVER then
	function ENT:OnSeeEnemy(enemy) self:EmitSound("npc/combine_soldier/vo/contact.wav") end
end
```

Fields and hooks are listed in `lua/entities/ngl_base/shared.lua`. Hooks: `OnSpawned`, `OnSeeEnemy`, `OnLoseEnemy`, `OnDamaged` (return true to ignore), `OnDeath`, `OnAIThink` (return true to skip the default behaviour). Relations between factions: `NGL.SetRelation("rebels", "player", D_LI)`.

Examples shipped: `ngl_combine_soldier` and `ngl_rebel` (NPC tab, category "NGL Base").

### How the core keeps it cheap

- **Per tick**, each NPC only steers towards its current goal (`BehaveUpdate`: one `Approach`, one `FaceTowards`). The stock NextBot coroutine is not used.
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

- Enemy in clear view and within 1500 units: straight line, no path-finding at all.
- Otherwise: an A* path is requested in the background. All searches share `ngl_nav_budget` ms per tick (default 2), identical requests share one search, and results are cached for 4 s, so a squad chasing the same target pays for one path.
- Waypoints advance in the per-tick steering, so far-away NPCs that think once a second still walk paths smoothly.
- An NPC that hasn't moved for 2 s drops its path and decides again.
- No grid for the map: NPCs fall back to straight lines.

| Command / ConVar | Meaning |
| --- | --- |
| `ngl_nav_generate` | Build and save the grid for the current map |
| `ngl_nav_info` | Points, spacing, running searches, cached paths |
| `ngl_nav_draw [radius]` | Draw the grid around you for 15 s (listen server with `developer 1`) |
| `ngl_nav_reload` | Reload the saved grid |
| `ngl_nav_spacing` (96) | Grid spacing for generation. Smaller = more precise, more points |
| `ngl_nav_max_nodes` (150000) | Generation stops at this many points |
| `ngl_nav_budget` (2) | ms per tick for path-finding |
| `ngl_nav_max_expand` (30000) | A search gives up after this many points |

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
