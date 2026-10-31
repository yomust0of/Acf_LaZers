-- =========================================================================
-- ACF PPC: CLIENT FILE  (16)
-- Goes to:  lua/entities/acf_ppc/cl_init.lua    (replaces the empty placeholder that is there now)
-- The PPC needs nothing special on the client: the scalable base draws the (scaled) model, the hover text comes from the server (ENT:ACF_UpdateOverlayState in init.lua), and the flying
-- projectile is drawn by ACF's own bullet effect from the values the server puts on the PPC (ENT:NetworkBolt). The muzzle sparks, the energy round the projectile and the sounds will go here later.
-- =========================================================================

include("shared.lua")
