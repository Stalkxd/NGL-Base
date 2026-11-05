-- Client half of the NGL benchmark.
--
-- engine.ServerFrameTime() only exists on the client: it is the server frame
-- time the server networks down for net_graph. The server tells us when each
-- phase starts, we sample it every frame, and send the stats back at the end.

local bucket = nil   -- current phase's samples, or nil when idle
local buckets = {}

local function stats(list)
	local n = #list
	if n == 0 then return nil end

	local sorted, sum = {}, 0
	for i = 1, n do
		sorted[i] = list[i]
		sum = sum + list[i]
	end
	table.sort(sorted)

	local function pct(p)
		return sorted[math.max(1, math.min(n, math.ceil(n * p)))]
	end

	return { avg = sum / n, p50 = pct(0.5), p95 = pct(0.95), p99 = pct(0.99), max = sorted[n], n = n }
end

hook.Add("Think", "NGL.Bench.ClientSample", function()
	if not bucket then
		local S = NGL.ClStats
		if S then S.drawn, S.occluded, S.far, S.impostor = 0, 0, 0, 0 end
		return
	end

	if engine.ServerFrameTime then
		local ft = engine.ServerFrameTime()
		if ft then
			-- Value is in seconds (net_graph multiplies it by 1000 for display).
			bucket.sv[#bucket.sv + 1] = ft * 1000
			bucket.raw = bucket.raw or ft
		end
	end

	bucket.fps[#bucket.fps + 1] = FrameTime() * 1000
	bucket.frames = bucket.frames + 1

	-- What NGL NPCs' Draw did last frame (cl_init.lua), and every 15 frames
	-- how many NGL NPCs this client has at all (sent by the server, not
	-- dormant).
	local S = NGL.ClStats
	if S then
		bucket.drawn[#bucket.drawn + 1] = S.drawn
		bucket.occluded[#bucket.occluded + 1] = S.occluded
		bucket.far[#bucket.far + 1] = S.far
		bucket.impostor[#bucket.impostor + 1] = S.impostor or 0
	end
	if bucket.frames % 15 == 1 then
		local n = 0
		for _, e in ipairs(ents.GetAll()) do
			if e.IsNGLNPC and not e:IsDormant() then n = n + 1 end
		end
		bucket.known[#bucket.known + 1] = n
	end
	if not system.HasFocus() then
		-- Unfocused, the engine sleeps (engine_no_focus_sleep), which ruins the numbers.
		bucket.unfocused = bucket.unfocused + 1
	end
	if S then S.drawn, S.occluded, S.far, S.impostor = 0, 0, 0, 0 end
end)

net.Receive("ngl_bench_phase", function()
	local phase = net.ReadString()

	-- "away": the client benchmark's second half, the player turned away
	-- from the fight.
	if phase == "baseline" or phase == "loaded" or phase == "away" then
		bucket = { sv = {}, fps = {}, frames = 0, unfocused = 0, drawn = {}, occluded = {}, far = {}, impostor = {}, known = {} }
		buckets[phase] = bucket
		return
	end

	if phase == "pause" then
		bucket = nil
		return
	end

	if phase == "stop" then
		bucket = nil
		local report = {}
		for name, b in pairs(buckets) do
			report[name] = {
				sv_ms = stats(b.sv),
				client_frame_ms = stats(b.fps),
				raw_first = b.raw,
				unfocused_pct = b.frames > 0 and (b.unfocused / b.frames * 100) or 0,
				npcs_drawn = stats(b.drawn),
				npcs_occluded = stats(b.occluded),
				npcs_too_far = stats(b.far),
				npcs_impostor = stats(b.impostor),
				npcs_on_client = stats(b.known),
			}
		end
		-- This client's drawing settings, so runs can be compared.
		report.settings = {
			occlusion = GetConVar("ngl_cl_occlusion") and GetConVar("ngl_cl_occlusion"):GetInt(),
			impostor = GetConVar("ngl_cl_impostor") and GetConVar("ngl_cl_impostor"):GetInt(),
			impostor_range = GetConVar("ngl_cl_impostor_range") and GetConVar("ngl_cl_impostor_range"):GetFloat(),
			draw_range = GetConVar("ngl_cl_draw_range") and GetConVar("ngl_cl_draw_range"):GetFloat(),
			lod_range = GetConVar("ngl_cl_lod_range") and GetConVar("ngl_cl_lod_range"):GetFloat(),
			weapon_range = GetConVar("ngl_cl_weapon_range") and GetConVar("ngl_cl_weapon_range"):GetFloat(),
			flex_range = GetConVar("ngl_cl_flex_range") and GetConVar("ngl_cl_flex_range"):GetFloat(),
			ragdoll_max = GetConVar("ngl_cl_ragdoll_max") and GetConVar("ngl_cl_ragdoll_max"):GetInt(),
			fps_max = GetConVar("fps_max") and GetConVar("fps_max"):GetFloat(),
			resolution = ScrW() .. "x" .. ScrH(),
		}
		buckets = {}

		net.Start("ngl_bench_report")
		net.WriteTable(report)
		net.SendToServer()
	end
end)
