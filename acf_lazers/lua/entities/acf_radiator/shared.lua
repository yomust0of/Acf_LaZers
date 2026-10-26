-- =========================================================================
-- NEW (15.2). Goes to:  lua/entities/acf_radiator/shared.lua
--
-- THE ACF RADIATOR, shared part. Same recipe as the generator hub's: ACF's scalable base entity. It needs no NetworkVars of its own: what the client needs (the width, so it can
-- draw the radius) travels as an NW2 value, which also reaches players who join later.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName     = "ACF Radiator"
ENT.WireDebugName = "ACF Radiator"
ENT.PluralName    = "ACF Radiators"
ENT.Author        = "ACF Team"
ENT.Spawnable     = false -- tool-only: one made from the Q-menu would skip MakeACFRadiator and have no model / physics
ENT.AdminSpawnable = false

cleanup.Register("acf_radiators") -- the entry in the cleanup menu, shared so the client knows the name

-- The width in units. The server keeps it in the plain field Width (the duplicator saves that); the client reads the NW2 copy the server publishes.
function ENT:GetWidth()
    if SERVER then return self.Width or ACFLazers.Config.RadWidthDefault end

    return self:GetNW2Int("ACFRadWidth", ACFLazers.Config.RadWidthDefault)
end
