-- NGL Base loader.
-- Everything server-side lives under lua/ngl/server, client files under lua/ngl/client.

NGL = NGL or {}
NGL.Version = "0.1.2"

if SERVER then
	AddCSLuaFile()
	AddCSLuaFile("ngl/client/cl_bench.lua")

	include("ngl/server/sv_bench_ai.lua")
	include("ngl/server/sv_bench.lua")
else
	include("ngl/client/cl_bench.lua")
end
