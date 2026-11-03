-- =========================================================================
-- ACF FLAMETHROWER: CLIENT FILE  (22)
-- Goes to:  lua/entities/acf_flamer/cl_init.lua
-- The flamethrower needs nothing special on the client: the scalable base draws the (scaled) model, the hover text comes from the server (ENT:ACF_UpdateOverlayState in init.lua), and the flying
-- flames (the trail, the sound, the sphere you can switch on with the console command acf_lazers_flame_sphere) are drawn by the client part of lua/acf/entities/ammo_types/lazers_flame.lua.
-- =========================================================================

include("shared.lua")
