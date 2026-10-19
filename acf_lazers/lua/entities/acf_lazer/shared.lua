-- CHANGES vs the shared.lua you have now (version 6.1). Search this file for [CHANGED n].
--   [CHANGED 1] NEW custom beam colour: two NetworkVars UseCustomColor (Bool) and CustomColorRGB (Vector, 0-255). (9.7: the third one, CustomAlpha, the opacity, is gone.) Everything else is unchanged.

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName = "ACF Lazer"
ENT.WireDebugName = "ACF Lazer"
ENT.PluralName = "ACF Lazers"
ENT.Author = "ACF Team"
ENT.Spawnable = false      -- tool-only: a lazer made from the Q-menu would skip MakeACFLazer and have no model/physics
ENT.AdminSpawnable = false

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "CaliberSize")
    self:NetworkVar("Float", 1, "FocalLength")
    self:NetworkVar("Float", 2, "BeamLength")  -- units from the muzzle to where the beam ended (server-measured)
    self:NetworkVar("Float", 3, "BeamYaw")     -- aim error, degrees, to the left / right of the lazer's forward (server-chosen, see ENT:UpdateWobble)
    self:NetworkVar("Float", 4, "BeamPitch")   -- aim error, degrees, up / down
    self:NetworkVar("Bool", 0, "IsFiring")
    self:NetworkVar("Bool", 1, "BeamHit")      -- did the beam end on a surface (server-measured)
    self:NetworkVar("Bool", 2, "ColorSet")     -- 0 = red/green/cyan/purple set, 1 = orange/yellow/blue/purple set
    self:NetworkVar("Bool", 3, "UseCustomColor")   -- [CHANGED 1] 1 = draw the beam in this lazer's own colour (below) instead of the colour set
    self:NetworkVar("Vector", 0, "CustomColorRGB") -- [CHANGED 1] that colour: x = red, y = green, z = blue, each 0-255
    self:NetworkVar("String", 0, "LaserSoundPath") -- Crucial for SetLaserSoundPath / GetLaserSoundPath
end

-- Shared. Falls back to CaliberBase while the NetworkVar is still 0 (right after Spawn, before ApplyCaliber).
function ENT:GetCaliber()
    local caliber = self:GetCaliberSize()

    if caliber > 0 then return caliber end

    return ACFLazers.Config.CaliberBase
end

-- ONE definition of "where the beam starts", used by server damage AND client drawing.
-- OBBMaxs().x is the front of the model (laser.mdl hull is about 40.28 at scale 1), so it grows with the scale.
function ENT:GetMuzzlePos()
    return self:LocalToWorld(Vector(self:OBBMaxs().x, 0, 0))
end

-- ONE definition of "which way the beam points": the lazer's forward, turned by the wobble the server last published.
-- Healthy lazer: both numbers are 0, so this is exactly GetForward(). The server uses it for the trace, the client for drawing, so they can never disagree.
-- Angle(pitch, yaw, 0) is a rotation in the LAZER's own frame; LocalToWorldAngles turns it into a world angle [KNOW]; :Forward() is the direction that angle faces.
function ENT:GetBeamDirection()
    local yaw   = self:GetBeamYaw()
    local pitch = self:GetBeamPitch()

    if yaw == 0 and pitch == 0 then
        return self:GetForward()
    end

    return self:LocalToWorldAngles(Angle(pitch, yaw, 0)):Forward()
end

if CLIENT then
    killicon.AddAlias("acf_lazer", "weapon_crossbow")
end
