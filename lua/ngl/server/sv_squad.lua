-- NGL squads: a leader and up to Max members (the leader counts) that share
-- what they know and take orders. A squad is a plain Lua table, not an
-- entity, and costs nothing per tick: members follow and obey inside their
-- normal think (sv_core.lua), the squad itself never runs on its own.
--
--   local sq = NGL.NewSquad(leader, 10)
--   sq:Add(npc)                         -- leaves any old squad first
--   sq:Order(sq:Nearest(pos, 3), { kind = "search", pos = pos })
--   sq:Order("all", { kind = "hold", face = pos, time = 5 })
--
-- Order kinds (see Core.RunOrder): hold, move, search, fire_at.

NGL.Squad = NGL.Squad or {}
local Squad = NGL.Squad
Squad.__index = Squad

local IsValid = IsValid

local function alive(npc)
	return IsValid(npc) and not npc.NGLDying and npc:Health() > 0
end

function NGL.NewSquad(leader, maxSize)
	local s = setmetatable({
		leader = nil,
		members = {}, -- array, leader included
		slots = {},   -- [npc] = formation slot (1..), leader has none
		assets = {},  -- [vehicle] = true: Commandable NPCs taking the leader's orders (not members)
		max = maxSize or 10,
		formation = NGL.Squad.RandomFormation(leader),
	}, Squad)
	if IsValid(leader) then
		s:Add(leader)
		s.leader = leader
	end
	return s
end

-- "wedge", "line" or "column" (Core.Formations): one of the leader's
-- ENT.Squad.Formations, or of all three, at random.
function NGL.Squad.RandomFormation(leader)
	local cfg = IsValid(leader) and leader.Squad
	local list = cfg and cfg.Formations or { "wedge", "line", "column" }
	return list[math.random(#list)]
end

function Squad:SetFormation(name)
	if NGL.Core.Formations[name] then self.formation = name end
end

-- Drops dead and removed members. Called by everything that reads the list,
-- so deaths need no bookkeeping elsewhere.
function Squad:Prune()
	local m = self.members
	local j = 0
	for i = 1, #m do
		local npc = m[i]
		if alive(npc) and npc.NGLSquad == self then
			j = j + 1
			m[j] = npc
		else
			self.slots[npc] = nil
			if IsValid(npc) and npc.NGLSquad == self then npc.NGLSquad = nil end
		end
	end
	for i = #m, j + 1, -1 do m[i] = nil end
	if self.leader and not (alive(self.leader) and self.leader.NGLSquad == self) then
		self.leader = nil
	end
	-- A group that formed on its own (Squad.AutoGroup) picks a new leader
	-- when its leader dies or leaves.
	if self.auto and not self.leader and m[1] then self:SetLeader(m[1]) end
	return m
end

function Squad:Members() return self:Prune() end
function Squad:Count() return #self:Prune() end
function Squad:IsFull() return #self:Prune() >= self.max end
function Squad:GetLeader() return self.leader end
function Squad:SlotOf(npc) return self.slots[npc] end

function Squad:Add(npc)
	if not alive(npc) or npc.NGLSquad == self then return npc.NGLSquad == self end
	if self:IsFull() then return false end
	if npc.NGLSquad then npc.NGLSquad:Remove(npc) end
	local m = self.members
	m[#m + 1] = npc
	npc.NGLSquad = self
	if self.leader then
		-- Smallest free formation slot.
		local used = {}
		for _, s in pairs(self.slots) do used[s] = true end
		local slot = 1
		while used[slot] do slot = slot + 1 end
		self.slots[npc] = slot
	end
	return true
end

function Squad:Remove(npc)
	if npc.NGLSquad ~= self then return end
	npc.NGLSquad = nil
	self.slots[npc] = nil
	local m = self.members
	for i = #m, 1, -1 do
		if m[i] == npc then table.remove(m, i) break end
	end
	if npc == self.leader then self.leader = nil end
end

-- Makes `npc` (already a member) the leader; the old leader gets a slot.
function Squad:SetLeader(npc)
	if npc.NGLSquad ~= self then return false end
	local old = self.leader
	self.leader = npc
	local slot = self.slots[npc]
	self.slots[npc] = nil
	if IsValid(old) and old ~= npc and old.NGLSquad == self then self.slots[old] = slot or 1 end
	-- Members added while there was no leader get slots now.
	local used = {}
	for _, s in pairs(self.slots) do used[s] = true end
	local free = 1
	for _, m in ipairs(self.members) do
		if m ~= npc and not self.slots[m] then
			while used[free] do free = free + 1 end
			self.slots[m] = free
			used[free] = true
		end
	end
	return true
end

function Squad:Disband()
	for _, npc in ipairs(self.members) do
		if IsValid(npc) and npc.NGLSquad == self then npc.NGLSquad = nil end
	end
	for v in pairs(self.assets) do
		if IsValid(v) and v.NGLCommander == self.leader then v.NGLCommander = nil end
	end
	self.assets = {}
	self.members, self.slots, self.leader = {}, {}, nil
end

-- Up to `n` living members nearest to `pos`, leader excluded unless
-- withLeader. `filter(npc)` can skip some (busy, already on an order...).
function Squad:Nearest(pos, n, filter, withLeader)
	local list, dist = {}, {}
	for _, npc in ipairs(self:Prune()) do
		if (withLeader or npc ~= self.leader) and (not filter or filter(npc)) then
			list[#list + 1] = npc
			dist[npc] = pos:DistToSqr(npc:GetPos())
		end
	end
	table.sort(list, function(a, b) return dist[a] < dist[b] end)
	for i = #list, n + 1, -1 do list[i] = nil end
	return list
end

-- Gives each NPC its own copy of `order`. `who` = "all" (leader excluded),
-- "everyone" (leader included) or a list of NPCs. Returns how many took it.
function Squad:Order(who, order)
	local list = who
	if who == "all" or who == "everyone" then
		list = {}
		for _, npc in ipairs(self:Prune()) do
			if who == "everyone" or npc ~= self.leader then list[#list + 1] = npc end
		end
	end
	local n, first = 0, nil
	for _, npc in ipairs(list) do
		local copy = {}
		for k, v in pairs(order) do copy[k] = v end
		if npc:GiveOrder(copy) then
			n = n + 1
			if npc ~= self.leader and not first then first = npc end
		end
	end
	-- One of them answers over the radio, a moment after the order.
	if first and first.NGLSounds and first.NGLSounds.Ack then
		timer.Simple(0.8, function()
			if IsValid(first) and not first.NGLDying then first:NGLSound("Ack") end
		end)
	end
	return n
end

-- A member found an enemy: everyone else in the squad who isn't busy with
-- one goes to look (like ally alerts, but at any distance).
function Squad:Contact(from, pos, now)
	for _, npc in ipairs(self:Prune()) do
		if npc ~= from and npc.NGLEnemy == nil and not npc.NGLInvestigate
			and npc:OnAlerted(from, pos) ~= true then
			npc.NGLInvestigate = pos
			npc.NGLInvestigateUntil = now + 20
		end
	end
end

----------------------------------------------------------------------------
-- Leaders: any NGL NPC with ENT.Squad set leads a squad on its own.
--
--   ENT.Squad = {
--   	Max = 10,                 -- squad size, leader included
--   	Recruit = { "ngl_combine_soldier" }, -- classes it takes (nil = any ally)
--   	RecruitRadius = 1500,
--   	Scouts = 3,               -- sent to search when the target is lost
--   	ScoutRadius = 400, ScoutTime = 20,
--   	LostDelay = 2,            -- s out of sight before the squad halts
--   }
--
-- Runs inside the leader's think at most twice a second: recruiting, and the
-- lost-target drill (halt, then send scouts, then engage or stand down).
-- Hand signals (ENT:NGLSignal) and voice lines (Sounds.Halt, .Search,
-- .Engage, .StandDown) go with each step; members act half a second after
-- the signal so players see it first.
----------------------------------------------------------------------------

local LEAD_RATE = 0.5
local SIGNAL_DELAY = 0.5
local recruitSets = setmetatable({}, { __mode = "k" })

local function recruitable(leader, cfg)
	local set = cfg.Recruit and recruitSets[cfg]
	if cfg.Recruit and not set then
		set = {}
		for _, c in ipairs(cfg.Recruit) do set[c] = true end
		recruitSets[cfg] = set
	end
	return function(e)
		local esq = e.NGLSquad
		return e ~= leader and e.IsNGLNPC and not e.Squad and alive(e)
			and (esq == nil or esq.leader == nil or esq.auto) -- a real leader takes over loose groups
			and NGL.GetRelation(e.Faction, leader.Faction) == D_LI
			and (not set or set[e:GetClass()])
	end
end

local function signal(npc, kind)
	if npc.NGLSignal then npc:NGLSignal(kind) end
	npc:NGLSound(kind, true)
end

-- Something to do SIGNAL_DELAY after a hand signal (one at a time).
local function later(npc, now, fn)
	npc.NGLLeadAction = { at = now + SIGNAL_DELAY, fn = fn }
end

-- Everyone (leader too) drops their orders and fights `enemy`.
local function engage(npc, sq, enemy, now)
	npc.NGLLost = nil
	npc.NGLLeadAction = nil
	signal(npc, "Engage")
	local Core = NGL.Core
	local ePos = IsValid(enemy) and enemy:GetPos()
	for _, m in ipairs(sq:Prune()) do
		if m.NGLOrder then Core.EndOrder(m, "cleared") end
		if ePos and Core.IsHostile(m, enemy) then
			Core.SetEnemy(m, enemy)
			m.NGLLastSeenPos, m.NGLLastSeenT = ePos, now
		end
	end
end

-- Nothing found: orders off, forget the target, back into formation.
local function standDown(npc, sq, lost)
	npc.NGLLost = nil
	npc.NGLLeadAction = nil
	signal(npc, "StandDown")
	local Core = NGL.Core
	for _, m in ipairs(sq:Prune()) do
		if m.NGLOrder then Core.EndOrder(m, "cleared") end
		if m.NGLEnemy == lost and not m.NGLEnemyVisible then Core.SetEnemy(m, nil) end
	end
end

-- Any member looking at a hostile right now?
local function anyoneSees(sq)
	for _, m in ipairs(sq.members) do
		local e = m.NGLEnemy
		if e and m.NGLEnemyVisible and IsValid(e) and not e.NGLDying and e:Health() > 0 then return e end
	end
end

-- Fire support: the nearest free vehicle (ENT.Commandable) pounds `pos`.
local function callFire(npc, sq, pos, now, cfg)
	if now < (npc.NGLNextFireCall or 0) then return false end
	local best, bestD
	local myPos = npc:GetPos()
	for v in pairs(sq.assets) do
		if alive(v) and not v.NGLOrder and not v:IsBusy() then
			local d = myPos:DistToSqr(v:GetPos())
			if not bestD or d < bestD then best, bestD = v, d end
		end
	end
	if not best then return false end
	npc.NGLNextFireCall = now + (cfg.FireSupportDelay or 12)
	signal(npc, "CallFire")
	later(npc, now, function()
		if alive(best) then best:GiveOrder({ kind = "fire_at", pos = pos, time = 8 }) end
	end)
	return true
end
Squad.CallFire = callFire

-- Vehicles of our faction nearby report to us; ones that drove off or lost
-- their commander are let go.
local function scanAssets(npc, now, pos, sq, cfg)
	if now < (npc.NGLNextAssetScan or 0) then return end
	npc.NGLNextAssetScan = now + 2
	local r = cfg.CommandRadius or 3000
	for v in pairs(sq.assets) do
		if not alive(v) or v.NGLCommander ~= npc or v:GetPos():DistToSqr(pos) > (r * 1.2) ^ 2 then
			sq.assets[v] = nil
			if IsValid(v) and v.NGLCommander == npc then v.NGLCommander = nil end
		end
	end
	local found = NGL.FindInRadius(pos, r, function(e)
		if not e.Commandable or not alive(e) or NGL.GetRelation(e.Faction, npc.Faction) ~= D_LI then return false end
		local c = e.NGLCommander
		return c == nil or c == npc or not alive(c)
	end)
	for _, v in ipairs(found) do
		v.NGLCommander = npc
		sq.assets[v] = true
	end
end

-- The enemy has friends packed around it: worth a rocket barrage.
local function crowded(npc, enemy)
	local n = 0
	for _, e in ipairs(NGL.FindInRadius(enemy:GetPos(), 300, function(e) return NGL.Core.IsHostile(npc, e) end)) do
		n = n + 1
		if n >= 3 then return true end
	end
	return false
end

local function lostTarget(npc, now, sq, cfg)
	local L = npc.NGLLost
	if not L then
		local e = npc.NGLEnemy
		if not IsValid(e) then return end
		if npc.NGLEnemyVisible then
			npc.NGLLostFor = nil -- seen again: the drill may run again later
			return
		end
		if npc.NGLLostFor == e or now - (npc.NGLLastSeenT or now) < (cfg.LostDelay or 2) then return end
		if #sq:Prune() < 2 then return end
		if anyoneSees(sq) then return end -- someone still has eyes on it
		npc.NGLLostFor = e
		local last = npc.NGLLastSeenPos or e:GetPos()
		L = { enemy = e, last = last, stage = "halt", at = now + 1.5 }
		npc.NGLLost = L
		signal(npc, "Halt")
		local hold = (cfg.ScoutTime or 20) + 6
		later(npc, now, function()
			if npc.NGLLost ~= L then return end
			sq:Order("everyone", { kind = "hold", face = last, time = hold })
		end)
		return
	end

	-- Contact while halted or searching: everyone fights.
	local seen = anyoneSees(sq)
	if seen then return engage(npc, sq, seen, now) end

	if L.stage == "halt" then
		if now < L.at then return end
		L.stage = "search"
		L.giveUp = now + (cfg.ScoutTime or 20) + 5
		-- The target is hiding: a vehicle shells the spot while scouts go in.
		if not L.called and callFire(npc, sq, L.last, now, cfg) then
			L.at = now + 1 -- scouts right after the call
			L.stage = "halt"
			L.called = true
			return
		end
		signal(npc, "Search")
		later(npc, now, function()
			if npc.NGLLost ~= L then return end
			local scouts = sq:Nearest(L.last, cfg.Scouts or 3)
			L.left = #scouts
			for _, sc in ipairs(scouts) do
				sc:GiveOrder({
					kind = "search", pos = L.last, radius = cfg.ScoutRadius or 400, time = cfg.ScoutTime or 20,
					onDone = function(s, _, reason)
						if npc.NGLLost ~= L or not IsValid(npc) then return end
						if reason == "contact" then
							engage(npc, sq, s.NGLEnemy, CurTime())
						elseif reason ~= "replaced" then
							L.left = L.left - 1
							if L.left <= 0 then standDown(npc, sq, L.enemy) end
						end
					end,
				})
			end
			if L.left == 0 then standDown(npc, sq, L.enemy) end
		end)
	elseif L.stage == "search" and now > L.giveUp then
		standDown(npc, sq, L.enemy)
	end
end

function Squad.LeaderThink(npc, now, pos)
	if now < (npc.NGLNextLead or 0) then return end
	npc.NGLNextLead = now + LEAD_RATE
	local cfg = npc.Squad

	local act = npc.NGLLeadAction
	if act and now >= act.at then
		npc.NGLLeadAction = nil
		act.fn()
	end

	local sq = npc.NGLSquad
	if sq and sq.leader ~= npc then return end -- someone else leads us

	-- A leader always has a squad, even alone (it may call reinforcements).
	sq = sq or NGL.NewSquad(npc, cfg.Max or 10)

	if now >= (npc.NGLNextRecruit or 0) then
		npc.NGLNextRecruit = now + 2
		if not sq or not sq:IsFull() then
			local found = NGL.FindInRadius(pos, cfg.RecruitRadius or 1500, recruitable(npc, cfg))
			if #found > 0 then
				table.sort(found, function(a, b) return pos:DistToSqr(a:GetPos()) < pos:DistToSqr(b:GetPos()) end)
				for _, e in ipairs(found) do
					if sq:IsFull() then break end
					sq:Add(e)
				end
			end
		end
	end

	if sq then
		scanAssets(npc, now, pos, sq, cfg)
		if cfg.Reinforce and NGL.Reinforce then NGL.Reinforce.Think(npc, now, sq, cfg) end
		lostTarget(npc, now, sq, cfg)
		-- A packed group around our target: call in the vehicles.
		local e = npc.NGLEnemy
		if next(sq.assets) and not npc.NGLLost and IsValid(e) and npc.NGLEnemyVisible
			and now >= (npc.NGLNextFireCall or 0) and crowded(npc, e) then
			callFire(npc, sq, e:GetPos(), now, cfg)
		end
		if npc.OnLeaderThink then npc:OnLeaderThink(sq, now) end
	end
end

----------------------------------------------------------------------------
-- Groups: NPCs without ENT.Squad team up on their own with allies of the
-- same faction nearby (ENT.Group, default { Max = 6, Radius = 800 }; false
-- = always alone, e.g. zombies). The nearest ally becomes the leader; the
-- group walks in formation behind it, shares contacts, and picks a new
-- leader when it dies. A squad leader (ENT.Squad) nearby takes them over.
-- Runs from the idle think, every 3 to 5 seconds per NPC: one grid lookup.
----------------------------------------------------------------------------

local GROUP_DEFAULT = { Max = 6, Radius = 800 }

function Squad.AutoGroup(npc, now, pos)
	if now < (npc.NGLNextGroup or 0) then return end
	npc.NGLNextGroup = now + math.Rand(3, 5)
	local cfg = npc.Group
	if cfg == false or npc.Squad or npc.IsVehicleNPC then return end
	local sq = npc.NGLSquad
	if sq then
		if not (sq.auto and sq:Count() <= 1) then return end
		sq:Disband() -- everyone else is gone: look for a new group
	end
	if type(cfg) ~= "table" then cfg = GROUP_DEFAULT end
	local faction = npc.Faction
	local best, bestD
	local found = NGL.FindInRadius(pos, cfg.Radius or 800, function(e)
		return e ~= npc and e.Faction == faction and e.Group ~= false and not e.IsVehicleNPC and alive(e)
	end)
	for _, e in ipairs(found) do
		local esq = e.NGLSquad
		local ok
		if esq then
			ok = esq.auto and esq.leader ~= nil and not esq:IsFull()
		else
			ok = not e.Squad
		end
		if ok then
			local d = pos:DistToSqr(e:GetPos())
			if not bestD or d < bestD then best, bestD = e, d end
		end
	end
	if not best then return end
	if best.NGLSquad then
		best.NGLSquad:Add(npc)
	else
		local bcfg = type(best.Group) == "table" and best.Group or cfg
		local s = NGL.NewSquad(best, bcfg.Max or 6)
		s.auto = true
		s:Add(npc)
	end
end

----------------------------------------------------------------------------
-- Test commands (superadmin): group, order and inspect squads in game.
----------------------------------------------------------------------------

local function admin(ply)
	return not IsValid(ply) or ply:IsSuperAdmin()
end

local function aimed(ply)
	if not IsValid(ply) then return end
	local tr = ply:GetEyeTrace()
	return tr.Entity, tr.HitPos
end

local function say(ply, msg)
	print(msg)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
end

-- ngl_squad_make [size]: the NGL NPC you look at leads the nearest allies of
-- its faction (default 10 including the leader).
concommand.Add("ngl_squad_make", function(ply, _, args)
	if not admin(ply) then return end
	local leader = aimed(ply)
	if not (IsValid(leader) and leader.IsNGLNPC) then return say(ply, "[NGL] Look at an NGL NPC.") end
	local size = math.Clamp(tonumber(args[1]) or 10, 2, 64)
	local sq = NGL.NewSquad(leader, size)
	local pos = leader:GetPos()
	local near = NGL.FindInRadius(pos, 2000, function(e)
		return e ~= leader and e.IsNGLNPC and NGL.GetRelation(e.Faction, leader.Faction) == D_LI
	end)
	table.sort(near, function(a, b) return a:GetPos():DistToSqr(pos) < b:GetPos():DistToSqr(pos) end)
	for _, npc in ipairs(near) do
		if sq:IsFull() then break end
		sq:Add(npc)
	end
	say(ply, string.format("[NGL] Squad of %d led by %s.", sq:Count(), tostring(leader)))
end)

-- ngl_squad_order <hold|move|search|fire_at> [n]: order the squad of the NPC
-- you last made a squad with (or look at) to act on the spot you look at.
concommand.Add("ngl_squad_order", function(ply, _, args)
	if not admin(ply) then return end
	local ent, hit = aimed(ply)
	local kind = args[1] or "hold"
	local sq = IsValid(ent) and ent.NGLSquad or ply.NGLLastSquad
	if not sq then
		-- Nearest squad to where we look.
		local best, bestD
		for _, npc in ipairs(NGL.FindInRadius(hit, 3000, function(e) return e.NGLSquad ~= nil end)) do
			local d = npc:GetPos():DistToSqr(hit)
			if not bestD or d < bestD then best, bestD = npc.NGLSquad, d end
		end
		sq = best
	end
	if not sq then return say(ply, "[NGL] No squad nearby. Use ngl_squad_make first.") end
	ply.NGLLastSquad = sq
	local who = "all"
	local n = tonumber(args[2])
	if n then who = sq:Nearest(hit, n) end
	local order = { kind = kind, pos = hit, face = hit, run = true }
	if kind == "move" then order.hold = true end
	local took = sq:Order(who, order)
	say(ply, string.format("[NGL] %d members took the %s order.", took, kind))
end)

concommand.Add("ngl_squad_info", function(ply)
	if not admin(ply) then return end
	local seen, n = {}, 0
	for _, npc in ipairs(NGL.Core.List) do
		local sq = IsValid(npc) and npc.NGLSquad
		if sq and not seen[sq] then
			seen[sq] = true
			n = n + 1
			local orders = 0
			for _, m in ipairs(sq:Members()) do if m.NGLOrder then orders = orders + 1 end end
			say(ply, string.format("[NGL] Squad %d: %d/%d members, leader %s, %d on orders",
				n, sq:Count(), sq.max, tostring(sq.leader), orders))
		end
	end
	if n == 0 then say(ply, "[NGL] No squads.") end
end)
