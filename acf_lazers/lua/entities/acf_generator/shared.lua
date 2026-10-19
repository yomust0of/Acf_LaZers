-- =========================================================================
-- NEW (12). Goes to:  lua/entities/acf_generator/shared.lua
--
-- THE ACF GENERATOR HUB, shared part. Same recipe as the lazer's and the capacitor's: ACF's scalable base entity. It needs no NetworkVars of its own: what the
-- client needs (the rated power, the engines it is linked to) travels as NW2 values, which also reach players who join later.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName     = "ACF Generator Hub"
ENT.WireDebugName = "ACF Generator Hub"
ENT.PluralName    = "ACF Generator Hubs"
ENT.Author        = "ACF Team"
ENT.Spawnable     = false -- tool-only: one made from the Q-menu would skip MakeACFGenerator and have no model / physics
ENT.AdminSpawnable = false

cleanup.Register("acf_generators") -- the entry in the cleanup menu, shared so the client knows the name

-- ONE definition of "where the engine's driveshaft plugs in", used by the server (angle checks, rope length) and the client (rope drawing).
-- The point in the config (GenInputPos) is for the model at scale 1; the model is drawn bigger or smaller, so the point moves with the scale. [GUESS] that ACF's scaling
-- scales the picture around the entity's origin (it uses a render matrix), so a point in the entity's local space scales by the same factor.
function ENT:GetInputLocal()
    local pos   = ACFLazers.Config.GenInputPos
    local scale = ACFLazers.GetGenScale(self:GetRatedHP())

    return Vector(pos[1] * scale, pos[2] * scale, pos[3] * scale)
end

-- The rated power. The server keeps it in the plain field RatedHP (the duplicator saves that); the client reads the NW2 copy the server publishes.
function ENT:GetRatedHP()
    if SERVER then return self.RatedHP or ACFLazers.Config.GenHPDefault end

    return self:GetNW2Int("ACFGenHP", ACFLazers.Config.GenHPDefault)
end
