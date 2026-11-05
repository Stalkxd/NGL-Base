-- The "NGL Base" tab in the spawn menu (Q menu), like VJ Base's: NGL NPCs
-- grouped by side (Combine, Resistance, Zombies, Headcrabs...) in a tree on
-- the left, their icons on the right. Click an icon to spawn, as in the NPCs
-- tab, where they stay listed too.
--
-- Any NPC in the "NPC" list with an NGLGroup shows up here, so an addon built
-- on NGL Base puts its NPCs in a group of its own (or one of ours):
--   list.Set("NPC", "my_npc", { Name = "Mutant", Class = "my_npc",
--   	Category = "My Addon", NGLGroup = "Mutants" })
--   NGL.SpawnGroups.Mutants = { Icon = "icon16/bug.png", Order = 50 }
-- Entries in the "NGL Base" category without an NGLGroup go under "Other".

NGL.SpawnGroups = NGL.SpawnGroups or {}
local Groups = NGL.SpawnGroups

local function group(name, icon, order)
	Groups[name] = Groups[name] or {}
	local g = Groups[name]
	g.Icon = g.Icon or icon
	g.Order = g.Order or order
end
group("Combine", "icon16/shield.png", 10)
group("Resistance", "icon16/flag_orange.png", 20)
group("Zombies", "icon16/bug.png", 30)
group("Headcrabs", "icon16/bug_error.png", 40)
group("Other", "icon16/monkey.png", 1000)

-- { [group] = { [class] = entry } } of every NGL NPC in the list.
local function collect()
	local out = {}
	for class, e in pairs(list.Get("NPC")) do
		local g = e.NGLGroup
		if g == nil and e.Category == "NGL Base" then g = "Other" end
		if g ~= nil then
			g = tostring(g)
			out[g] = out[g] or {}
			out[g][class] = e
		end
	end
	return out
end

local function sortedGroups(found)
	local names = {}
	for name in pairs(found) do names[#names + 1] = name end
	table.sort(names, function(a, b)
		local oa = Groups[a] and Groups[a].Order or 500
		local ob = Groups[b] and Groups[b].Order or 500
		if oa ~= ob then return oa < ob end
		return a < b
	end)
	return names
end

local function addIcon(container, class, e)
	spawnmenu.CreateContentIcon(e.ScriptedEntityType or "npc", container, {
		nicename = e.Name or class,
		spawnname = class,
		material = e.IconOverride or ("entities/" .. class .. ".png"),
		weapon = e.Weapons,
		admin = e.AdminOnly,
	})
end

hook.Add("NGLPopulateSpawnMenu", "NGL.SpawnMenu", function(pnlContent, tree)
	local found = collect()
	for _, name in ipairs(sortedGroups(found)) do
		local entries = found[name]
		local g = Groups[name]
		local node = tree:AddNode(name, g and g.Icon or "icon16/monkey.png")
		node.DoPopulate = function(self)
			if self.PropPanel then return end
			self.PropPanel = vgui.Create("ContentContainer", pnlContent)
			self.PropPanel:SetVisible(false)
			self.PropPanel:SetTriggerSpawnlistChange(false)
			for class, e in SortedPairsByMemberValue(entries, "Name") do
				addIcon(self.PropPanel, class, e)
			end
		end
		node.DoClick = function(self)
			self:DoPopulate()
			pnlContent:SwitchPanel(self.PropPanel)
		end
	end
	local first = tree:Root():GetChildNode(0)
	if IsValid(first) then first:InternalDoClick() end
end)

-- Only where there is a spawn menu (Sandbox and gamemodes built on it): the
-- tab is built when the spawn menu is, so it has to be added now, before
-- the gamemode makes the menu.
if spawnmenu and spawnmenu.AddCreationTab then
	spawnmenu.AddCreationTab("NGL Base", function()
		local ctrl = vgui.Create("SpawnmenuContentPanel")
		if spawnmenu.CreateContentIcon then ctrl:CallPopulateHook("NGLPopulateSpawnMenu") end
		return ctrl
	end, "icon16/group.png", 25, "NGL Base NPCs, grouped by side")
end
