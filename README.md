# NGL Base

An NPC base for Garry's Mod built for large battles (100+ NPCs) with minimal server CPU load, in singleplayer and multiplayer, across gamemodes.

## Roadmap

1. **Benchmark harness and entity choice** (this step). A tool that spawns N NPCs and measures server CPU per tick, used to compare an engine NextBot with a lightweight custom entity. Every later step is measured with it.
2. **NPC base core.** One central scheduler with a CPU budget per tick, distance-based update rates (LOD), a spatial grid for perception, and an authoring API (states, relationships, damage, weapons).
3. **Custom navigation.** Our own lightweight nav graph generated per map (no navmesh, no AI nodes), path-finding spread over several ticks, and shared paths / flow fields for groups.
4. **Battle test.** Two teams of 100+ soldiers on several maps, singleplayer and dedicated server, tuned against the target.

**Target:** 100 NPCs fighting with minimal server CPU load. Step 1 gives us the baseline numbers to turn this into a hard ms-per-tick figure.

## Installing

Copy (or clone) this folder into `garrysmod/addons/ngl-base`, then restart the map.

## Running the benchmark

Commands need superadmin (the host in singleplayer) or the server console. Look at an open flat area first, since NPCs spawn where you aim. `gm_flatgrass` or `gm_construct` work well.

| Command | What it does |
| --- | --- |
| `ngl_bench <class> <count>` | One run, e.g. `ngl_bench ngl_bench_light 100` |
| `ngl_bench_compare [count]` | Light entity vs NextBot vs `npc_combine_s` at the same count (default 100) |
| `ngl_bench_sweep <class> <c1,c2,...>` | Several counts in a row, e.g. `ngl_bench_sweep ngl_bench_light 25,50,100,200` |
| `ngl_bench_stop` | Abort and remove everything |
| `ngl_bench_clear` | Remove benchmark NPCs |

Each run samples the empty server, spawns the NPCs in two facing teams, waits for warmup, then samples while they chase, strafe and shoot. The report shows:

- **Server frame, empty / loaded**: the engine's own server frame time (`engine.ServerFrameTime`), which includes engine AI, physics, networking and Lua.
- **Added by NPCs**: loaded minus empty, per tick and per NPC, and the share of the tick budget used.
- **Bench AI Lua only**: time spent in our own Lua for the two test entities.
- **Late ticks**: ticks that arrived more than 1.5x the tick interval late.

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

For dependable numbers, run on a **dedicated server**: on a listen or singleplayer server the client's rendering shares the process and adds noise.

## Results

| Date | Map | Server | Class | Count | Added ms/tick | us/NPC | Late ticks |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |
