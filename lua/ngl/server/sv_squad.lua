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
		max = maxSize or 10,
	}, Squad)
	if IsValid(leader) then
		s:Add(leader)
		s.leader = leader
	end
	return s
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
	local n = 0
	for _, npc in ipairs(list) do
		local copy = {}
		for k, v in pairs(order) do copy[k] = v end
		if npc:GiveOrder(copy) then n = n + 1 end
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
