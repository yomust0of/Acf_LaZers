-- =========================================================================
-- REBUILT (16.9). Goes to:  lua/entities/acf_fusion/shared.lua
--
-- THE ACF FUSION ENGINE, shared part. Same recipe as the generator hub's and the radiator's: ACF's scalable base entity. It needs no NetworkVars of its own: what the client needs
-- (the rated power, which is also the size) travels as an NW2 value, which also reaches players who join later.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName     = "ACF Fusion Engine"
ENT.WireDebugName = "ACF Fusion Engine"
ENT.PluralName    = "ACF Fusion Engines"
ENT.Author        = "ACF Team"
ENT.Spawnable     = false -- tool-only: one made from the Q-menu would skip MakeACFFusion and have no model / physics
ENT.AdminSpawnable = false

cleanup.Register("acf_fusions") -- the entry in the cleanup menu, shared so the client knows the name

-- The rated power in hp (the tool's slider value). The server keeps it in the plain field RatedHP (the duplicator saves that; a dupe with none, or a silly one, is the slider's default);
-- the client reads the NW2 copy the server publishes.
function ENT:GetRatedHP()
    local hp = SERVER and self.RatedHP or self:GetNW2Float("ACFFusionHP", 0)

    return ACFLazers.ClampFusionHP(hp > 0 and hp or nil)
end
