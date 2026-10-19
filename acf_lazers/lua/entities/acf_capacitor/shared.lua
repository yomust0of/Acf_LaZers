-- =========================================================================
-- NEW FILE (version 8).  Goes to:  lua/entities/acf_capacitor/shared.lua   (replaces the empty placeholder that is there now)
-- Copy the whole file. Nothing in it is tagged because every line is new.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (same first line as acf_lazer/shared.lua and acf_gun/shared.lua)

ENT.PrintName      = "ACF Capacitor"
ENT.WireDebugName  = "ACF Capacitor"
ENT.PluralName     = "ACF Capacitors"
ENT.Author         = "ACF Team"
ENT.Spawnable      = false -- tool-only: one made from the Q-menu would skip MakeACFCapacitor and have no model / physics / size
ENT.AdminSpawnable = false

-- Lets the undo / cleanup lists know about the limit name the capacitor tool uses (ply:AddCleanup("acf_capacitors", ent) in init.lua).
cleanup.Register("acf_capacitors")
