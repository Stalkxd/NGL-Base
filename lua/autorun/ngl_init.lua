-- NGL Base loader.
-- Everything server-side lives under lua/ngl/server, client files under lua/ngl/client.

NGL = NGL or {}
NGL.Version = "0.15.1"

if SERVER then
	AddCSLuaFile()
	AddCSLuaFile("ngl/client/cl_bench.lua")
	AddCSLuaFile("ngl/client/cl_projectile.lua")
	AddCSLuaFile("ngl/client/cl_nav_edit.lua")
	-- The Combine rope animations (clients without the addon's files download them).
	resource.AddSingleFile("models/ngl/combine_rappel.mdl")
	resource.AddSingleFile("models/ngl/combine_rappel.ani")

	include("ngl/server/sv_core.lua")
	include("ngl/server/sv_aimodes.lua")
	include("ngl/server/sv_squad.lua")
	include("ngl/server/sv_air.lua")
	include("ngl/server/sv_reinforce.lua")
	include("ngl/server/sv_projectile.lua")
	include("ngl/server/sv_nav.lua")
	include("ngl/server/sv_nav_edit.lua")
	include("ngl/server/sv_doors.lua")
	include("ngl/server/sv_bench_ai.lua")
	include("ngl/server/sv_bench.lua")
else
	include("ngl/client/cl_bench.lua")
	include("ngl/client/cl_projectile.lua")
	include("ngl/client/cl_nav_edit.lua")

	-- Names in the kill feed and other HUD text ("Combine Soldier (NGL)"
	-- instead of "#ngl_combine_soldier").
	local function addNames()
		for class, info in pairs(scripted_ents.GetList()) do
			local t = info.t
			if t and t.PrintName and string.sub(class, 1, 4) == "ngl_" then
				language.Add(class, t.PrintName)
			end
		end
	end
	hook.Add("InitPostEntity", "NGL.Names", addNames)
	addNames()
end
