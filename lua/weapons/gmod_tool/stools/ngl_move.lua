-- NGL NPC Mover: send NGL NPCs somewhere.
--   Left click:  pick the NPC you aim at (again to drop it); aiming at the
--                ground, sends the picked NPCs there.
--   Right click: send the picked NPCs where you aim. They spread out round
--                the spot, find their way along the nav grid, and shoot at
--                enemies on the way.
--   Reload:      drop them all.
-- It's a move order, the same as squad leaders give, but their squad
-- leader can't call them off it until they get there. Superadmins only.
TOOL.Category = "NGL Base"
TOOL.Name = "#tool.ngl_move.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar["run"] = "1"
TOOL.ClientConVar["hold"] = "1"

TOOL.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" },
}

if CLIENT then
	language.Add("tool.ngl_move.name", "NGL NPC Mover")
	language.Add("tool.ngl_move.desc", "Pick NGL NPCs and send them somewhere")
	language.Add("tool.ngl_move.left", "Pick the NPC you aim at (again to drop it)")
	language.Add("tool.ngl_move.right", "Send the picked NPCs here")
	language.Add("tool.ngl_move.reload", "Drop all picked NPCs")
end

local function use(self, trace, button)
	if CLIENT then return true end
	if not (NGL and NGL.Tools) then return false end
	return NGL.Tools.Move(self:GetOwner(), trace, button, {
		run = self:GetClientNumber("run", 1) ~= 0,
		hold = self:GetClientNumber("hold", 1) ~= 0,
	})
end

function TOOL:LeftClick(trace) return use(self, trace, "left") end
function TOOL:RightClick(trace) return use(self, trace, "right") end
function TOOL:Reload(trace) return use(self, trace, "reload") end

if CLIENT then
	function TOOL.BuildCPanel(panel)
		panel:Help("Left click NGL NPCs to pick them (green rings), then right click where they should go.")
		panel:CheckBox("Run there", "ngl_move_run")
		panel:CheckBox("Stay there a minute (otherwise they carry on as before)", "ngl_move_hold")
		panel:Help("Track them with the NGL NPC Tracker to watch the way they take.")
	end
end
