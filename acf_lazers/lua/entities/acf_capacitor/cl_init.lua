-- =========================================================================
-- NEW FILE (version 8).  Goes to:  lua/entities/acf_capacitor/cl_init.lua   (replaces the empty placeholder that is there now)
-- Copy the whole file. Nothing in it is tagged because every line is new.
-- The capacitor needs nothing special on the client: the scalable base draws the (scaled) model, and the hover text comes from the server
-- (ENT:ACF_UpdateOverlayState in init.lua). Charge glow, sounds and so on can be added here later.
-- =========================================================================

include("shared.lua")
