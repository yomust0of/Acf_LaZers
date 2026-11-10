-- =========================================================================
-- ACF GAUSS RIFLE: CLIENT FILE  (23)
-- Goes to:  lua/entities/acf_gauss/cl_init.lua
-- The rifle needs nothing special on the client: the scalable base draws the (scaled) model, the hover text comes from the server (ENT:ACF_UpdateOverlayState in init.lua), and the flying DART is
-- drawn by ACF's own bullet effect from the values the server puts on the rifle (lua/acf/entities/ammo_types/lazers_dart.lua, Ammo:Network). The muzzle effects and the gauss look of the DART go here
-- later.
-- =========================================================================

include("shared.lua")
