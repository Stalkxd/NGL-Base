-- HolyLib edition: optional fast paths when the server runs HolyLib.
--
-- HolyLib (github.com/RaphaelIT7/gmod-holylib) is a binary module a server
-- owner installs into garrysmod/lua/bin. It can't ship on the Workshop, so
-- NGL never needs it: every part below checks that the HolyLib function it
-- uses is there and otherwise leaves NGL exactly as it is without it.
--
-- What NGL uses when it's there:
--   * networking module (Linux srcds): nothing to call. It replaces the
--     engine's CheckTransmit and speeds up packing entities, which is most
--     of what sending hundreds of moving NPCs costs the server. NGL only
--     reports whether it's on (ngl_holylib_status, the benchmark).
--   * pvs module: sv_transmit.lua hides and shows NPCs per player with one
--     pvs.SetPreventTransmitBulk call per player and tick instead of one
--     SetPreventTransmit call per NPC (ngl_holylib_transmit).
--   * gameserver module: the benchmark reports each player's network
--     channel while sampling: rate, update rate, packets sent a second,
--     choked packets, loss and latency (NGL.HL.NetStart/NetSample/NetStop).
--     Plain GMod Lua can't read any of these.
--   * vprof module: ngl_holylib_vprof 1 puts NGL's scheduler, transmit
--     culling, BehaveUpdate and BodyUpdate in their own vprof scopes (budget
--     group "NGL"), so a vprof report shows them next to the engine's own
--     NextBot, animation and networking work.
--
-- ngl_holylib 0 turns every fast path off (the plain Lua paths run, as
-- without HolyLib), for A/B benchmarks with ngl_bench_limit.

local HL = NGL.HL or {}
NGL.HL = HL

local cvOn = CreateConVar("ngl_holylib", "1", FCVAR_ARCHIVE,
	"HolyLib edition: 1 = use HolyLib's fast paths when the server has HolyLib installed (bulk transmit, network stats in the benchmark). 0 = plain Lua paths, as without HolyLib (for A/B benchmarks).", 0, 1)
local cvTransmit = CreateConVar("ngl_holylib_transmit", "1", FCVAR_ARCHIVE,
	"HolyLib: hide and show NPCs per player with one pvs.SetPreventTransmitBulk call per player and tick instead of one call per NPC (needs HolyLib's pvs module).", 0, 1)
local cvVprof = CreateConVar("ngl_holylib_vprof", "0", 0,
	"HolyLib: 1 = NGL's scheduler, transmit culling, BehaveUpdate and BodyUpdate get their own vprof scopes (budget group NGL), to read next to the engine's work in a vprof report. Costs a little; leave off outside profiling.", 0, 1)

local function moduleOn(name)
	local cv = GetConVar("holylib_enable_" .. name)
	if cv then return cv:GetBool() end
	return nil -- unknown (older HolyLib): judged by its functions instead
end

-- What this server's HolyLib offers, read again on demand (modules can be
-- switched with holylib_enable_* while running).
function HL.Detect()
	local d = {}
	d.present = _HOLYLIB == true or HolyLib ~= nil or pvs ~= nil or gameserver ~= nil
	d.version = _HOLYLIB_VERSION
	d.branch = _HOLYLIB_BRANCH
	d.pvsBulk = pvs ~= nil and pvs.SetPreventTransmitBulk ~= nil and moduleOn("pvs") ~= false
	d.gameserver = gameserver ~= nil and gameserver.GetClient ~= nil and moduleOn("gameserver") ~= false
	d.vprof = vprof ~= nil and vprof.EnterScope ~= nil and vprof.ExitScope ~= nil and moduleOn("vprof") ~= false
	local netOn = moduleOn("networking")
	if netOn == nil then netOn = GetConVar("holylib_networking_fasttransmit") ~= nil end
	d.networking = netOn
	local ft = GetConVar("holylib_networking_fasttransmit")
	d.fasttransmit = netOn and ft ~= nil and ft:GetBool() or false
	local fp = GetConVar("holylib_networking_fastpath")
	d.fastpath = netOn and fp ~= nil and fp:GetBool() or false
	d.luajit = moduleOn("luajit") == true
	HL.Info = d
	return d
end

function HL.On() return cvOn:GetBool() and HL.Info ~= nil and HL.Info.present end

-- sv_transmit.lua asks this once per tick.
function HL.BulkTransmit()
	return cvOn:GetBool() and cvTransmit:GetBool() and HL.Info ~= nil and HL.Info.pvsBulk
end

----------------------------------------------------------------------------
-- Network stats per player (benchmark). Sampled every tick while the
-- benchmark samples; a few players, so it's cheap.

local FLOW_OUT = 0
local FLOW_IN = 1

local function clientOf(ply)
	local ok, cl = pcall(gameserver.GetClient, ply:EntIndex() - 1)
	if ok and cl and cl.IsValid and cl:IsValid() then return cl end
end

local function call(cl, name, ...)
	local f = cl[name]
	if not f then return nil end
	local ok, v = pcall(f, cl, ...)
	if ok then return v end
end

local sampleRun -- the running sample, or nil

function HL.NetStart()
	sampleRun = nil
	if not (cvOn:GetBool() and HL.Info and HL.Info.gameserver) then return end
	sampleRun = { t = SysTime(), per = {} }
	for _, ply in ipairs(player.GetHumans()) do
		local cl = clientOf(ply)
		if cl then
			sampleRun.per[ply] = {
				name = ply:Nick(),
				cl = cl,
				seq0 = call(cl, "GetOutSequenceNr") or 0,
				chokedLast = call(cl, "GetChokedPackets") or 0,
				choked = 0,
				ticksChoking = 0,
				ticks = 0,
				loss = 0, lossN = 0,
				lat = 0, latN = 0,
			}
		end
	end
end

function HL.NetSample()
	if not sampleRun then return end
	for ply, s in pairs(sampleRun.per) do
		local cl = s.cl
		if IsValid(ply) and cl:IsValid() then
			s.ticks = s.ticks + 1
			-- The engine counts packets it held back for the rate since its
			-- last send and resets the count when it sends one.
			local c = call(cl, "GetChokedPackets") or 0
			if c > 0 then s.ticksChoking = s.ticksChoking + 1 end
			if c > s.chokedLast then s.choked = s.choked + (c - s.chokedLast) end
			s.chokedLast = c
			if s.ticks % 10 == 0 then
				local l = call(cl, "GetAvgLoss", FLOW_IN)
				if l then s.loss, s.lossN = s.loss + l, s.lossN + 1 end
				local lt = call(cl, "GetAvgLatency", FLOW_OUT)
				if lt then s.lat, s.latN = s.lat + lt, s.latN + 1 end
			end
		end
	end
end

-- One entry per player, for the benchmark's JSON; nil when there's no data.
function HL.NetStop()
	if not sampleRun then return nil end
	local dt = math.max(0.001, SysTime() - sampleRun.t)
	local out = {}
	for ply, s in pairs(sampleRun.per) do
		local cl = s.cl
		if cl:IsValid() and s.ticks > 0 then
			local sent = math.max(0, (call(cl, "GetOutSequenceNr") or s.seq0) - s.seq0)
			out[#out + 1] = {
				player = s.name,
				rate = call(cl, "GetRate"),
				update_rate = call(cl, "GetUpdateRate"),
				packets_per_s = sent / dt,
				choked_per_s = s.choked / dt,
				choke_pct = (sent + s.choked) > 0 and s.choked / (sent + s.choked) * 100 or 0,
				ticks_choking_pct = s.ticksChoking / s.ticks * 100,
				loss_pct = s.lossN > 0 and s.loss / s.lossN * 100 or nil,
				latency_ms = s.latN > 0 and s.lat / s.latN * 1000 or nil,
			}
		end
	end
	sampleRun = nil
	return #out > 0 and out or nil
end

----------------------------------------------------------------------------
-- vprof scopes. Functions are wrapped while ngl_holylib_vprof is 1 and put
-- back when it's 0. A wrapped function that errors still leaves its scope.

local wrapped = {} -- { tbl, key, original }

local function wrap(tbl, key, name)
	local f = tbl and tbl[key]
	if type(f) ~= "function" then return end
	local enter, exit = vprof.EnterScope, vprof.ExitScope
	wrapped[#wrapped + 1] = { tbl, key, f }
	tbl[key] = function(...)
		enter(name, 0, "NGL")
		local ok, a, b = pcall(f, ...)
		exit()
		if not ok then ErrorNoHaltWithStack(a) return end
		return a, b
	end
end

local function unwrapAll()
	local ticks = hook.GetTable().Tick or {}
	for i = #wrapped, 1, -1 do
		local w = wrapped[i]
		w[1][w[2]] = w[3]
		if w[1] == ticks then hook.Add("Tick", w[2], w[3]) end
		wrapped[i] = nil
	end
end

local function applyVprof()
	unwrapAll()
	if not (cvVprof:GetBool() and cvOn:GetBool()) then return end
	local d = HL.Detect()
	if not d.vprof then
		print("[NGL] ngl_holylib_vprof: HolyLib's vprof module isn't loaded; nothing to do.")
		return
	end
	local ticks = hook.GetTable().Tick or {}
	wrap(ticks, "NGL.Core.Scheduler", "NGL scheduler")
	wrap(ticks, "NGL.NetCull", "NGL transmit culling")
	-- Tick hooks are added again so the hook library calls the wrapped ones
	-- whether or not hook.GetTable() is its own table.
	for _, w in ipairs(wrapped) do
		if w[1] == ticks then hook.Add("Tick", w[2], ticks[w[2]]) end
	end
	-- NPCs get their class's functions when they spawn, so these two only
	-- count NPCs spawned after turning it on.
	local base = scripted_ents.GetStored("ngl_base")
	if base and base.t then
		wrap(base.t, "BehaveUpdate", "NGL BehaveUpdate")
		wrap(base.t, "BodyUpdate", "NGL BodyUpdate")
	end
	print(string.format("[NGL] vprof scopes on (%d functions, budget group NGL; BehaveUpdate and BodyUpdate for NPCs spawned from now). Start vprof, then read its report.", #wrapped))
end

cvars.AddChangeCallback("ngl_holylib_vprof", function() applyVprof() end, "NGL.HL")
cvars.AddChangeCallback("ngl_holylib", function() applyVprof() end, "NGL.HL")

----------------------------------------------------------------------------
-- Status

local function yesno(b) return b and "on" or "off" end

function HL.StatusLines()
	local d = HL.Detect()
	local lines = {}
	if not d.present then
		lines[1] = "[NGL] HolyLib: not installed. NGL runs its plain Lua paths (nothing missing, only the fast paths below)."
		return lines
	end
	lines[#lines + 1] = string.format("[NGL] HolyLib %s%s found, NGL fast paths %s (ngl_holylib)",
		tostring(d.version or "?"), d.branch and (" (" .. tostring(d.branch) .. ")") or "", yesno(cvOn:GetBool()))
	lines[#lines + 1] = string.format("  networking module: %s (fasttransmit %s, fastpath %s)%s", yesno(d.networking), yesno(d.fasttransmit), yesno(d.fastpath),
		d.networking and "" or "  <- Linux srcds only; the biggest server saving for big fights")
	lines[#lines + 1] = string.format("  bulk transmit (pvs): %s", d.pvsBulk and yesno(HL.BulkTransmit()) or "not available")
	lines[#lines + 1] = string.format("  network stats in the benchmark (gameserver): %s", d.gameserver and yesno(cvOn:GetBool()) or "not available")
	lines[#lines + 1] = string.format("  vprof scopes: %s", d.vprof and (yesno(#wrapped > 0) .. " (ngl_holylib_vprof)") or "not available")
	if d.luajit then lines[#lines + 1] = "  HolyLib's LuaJIT is on (experimental; say so in reports)" end
	return lines
end

concommand.Add("ngl_holylib_status", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	for _, l in ipairs(HL.StatusLines()) do
		print(l)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, l) end
	end
end)

HL.Detect()
hook.Add("InitPostEntity", "NGL.HL", function()
	for _, l in ipairs(HL.StatusLines()) do print(l) end
	if cvVprof:GetBool() then applyVprof() end
end)
