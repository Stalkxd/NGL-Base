-- NGL Base loader.
-- Everything server-side lives under lua/ngl/server, client files under lua/ngl/client.

NGL = NGL or {}
NGL.Version = "0.5.0"

if SERVER then
	AddCSLuaFile()
	AddCSLuaFile("ngl/client/cl_bench.lua")
	AddCSLuaFile("ngl/client/cl_projectile.lua")

	include("ngl/server/sv_core.lua")
	include("ngl/server/sv_projectile.lua")
	include("ngl/server/sv_nav.lua")
	include("ngl/server/sv_bench_ai.lua")
	include("ngl/server/sv_bench.lua")
else
	include("ngl/client/cl_bench.lua")
	include("ngl/client/cl_projectile.lua")
end
