-- NGL Base loader.
-- Everything server-side lives under lua/ngl/server, client files under lua/ngl/client.

NGL = NGL or {}
NGL.Version = "0.1.0"

if SERVER then
	AddCSLuaFile()

	include("ngl/server/sv_bench_ai.lua")
	include("ngl/server/sv_bench.lua")
end
