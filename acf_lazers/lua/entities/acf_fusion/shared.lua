-- =========================================================================
-- NEW (16.8). Goes to:  lua/entities/acf_fusion/shared.lua
--
-- THE ACF FUSION ENGINE, shared part. Same recipe as the generator hub's and the radiator's: ACF's scalable base entity. It needs no NetworkVars of its own: what the client needs
-- (which size it is) travels as an NW2 value, which also reaches players who join later.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName     = "ACF Fusion Engine"
ENT.WireDebugName = "ACF Fusion Engine"
ENT.PluralName    = "ACF Fusion Engines"
ENT.Author        = "ACF Team"
ENT.Spawnable     = false -- tool-only: one made from the Q-menu would skip MakeACFFusion and have no model / physics
ENT.AdminSpawnable = false

cleanup.Register("acf_fusions") -- the entry in the cleanup menu, shared so the client knows the name

-- The size ("large" / "small", the ids of FusionTypes in the config). The server keeps it in the plain field FusionType (the duplicator saves that; a dupe with none, or an
-- unknown one, is the default size); the client reads the NW2 copy the server publishes.
function ENT:GetFusionType()
    local id = SERVER and self.FusionType or self:GetNW2String("ACFFusionType", "")

    return ACFLazers.ClampFusionType(id)
end
