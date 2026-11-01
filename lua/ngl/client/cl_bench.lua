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
	if not bucket then return end

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
	if not system.HasFocus() then
		-- Unfocused, the engine sleeps (engine_no_focus_sleep), which ruins the numbers.
		bucket.unfocused = bucket.unfocused + 1
	end
end)

net.Receive("ngl_bench_phase", function()
	local phase = net.ReadString()

	if phase == "baseline" or phase == "loaded" then
		bucket = { sv = {}, fps = {}, frames = 0, unfocused = 0 }
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
			}
		end
		buckets = {}

		net.Start("ngl_bench_report")
		net.WriteTable(report)
		net.SendToServer()
	end
end)
