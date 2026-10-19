-- =========================================================================
-- NEW (12). Goes to:  lua/entities/acf_generator/cl_init.lua
--
-- THE ACF GENERATOR HUB, client part. It only draws the ROPES from the linked engines' driveshafts to the generator's input point, and ONLY while the same console
-- variable that switches ACF's own mobility ropes on is on: acf_mobilityropelinks [SEEN acf/core/globals.lua:442; acf_engine/cl_init.lua:161 and acf_gearbox/cl_init.lua:261
-- read it the same way]. Switch it on with  acf_mobilityropelinks 1  or the checkbox in ACF's settings menu [SEEN acf/menu/items_cl/settings.lua:67].
-- The server publishes the linked engines as NW2 entity values  ACFGenEngine1 .. ACFGenEngineN  (N = GenMaxEngines).
-- =========================================================================

include("shared.lua")

assert(ACFLazers and ACFLazers.Config, "[acf_generator] lua/autorun/acf_lazers_config.lua is missing or did not load")

local Config = ACFLazers.Config

local RopeMat   = Material("cable/cable2")  -- the same cable material ACF's ropes use [SEEN acf_engine/cl_init.lua:162]
local RopeColor = Color(127, 127, 127)      -- [SEEN acf_engine/cl_init.lua:163]
local RopesCvar                             -- found on first use: ACF creates it when it loads, and we must not depend on who loads first

local function RopesOn()
    if not RopesCvar then RopesCvar = GetConVar("acf_mobilityropelinks") end

    return RopesCvar ~= nil and RopesCvar:GetBool()
end

-- Where an engine's driveshaft ends, in the world. The server uses the "driveshaft" attachment of the engine model for this (acf_engine/init.lua:337); a model without one
-- (the server then uses the engine's own origin for transverse engines) falls back to the origin here as well.
local function DriveshaftPos(engine)
    local index = engine:LookupAttachment("driveshaft")

    if index and index > 0 then
        local attachment = engine:GetAttachment(index)

        if attachment then return attachment.Pos end
    end

    return engine:GetPos()
end

function ENT:DrawRopes()
    local inPos = self:LocalToWorld(self:GetInputLocal())

    render.SetMaterial(RopeMat)

    for i = 1, Config.GenMaxEngines do
        local engine = self:GetNW2Entity("ACFGenEngine" .. i)

        if IsValid(engine) then
            render.DrawBeam(DriveshaftPos(engine), inPos, 1.5, 0, 0, RopeColor)
        end
    end
end

function ENT:Draw()
    self.BaseClass.Draw(self) -- [SEEN acf_engine/cl_init.lua:166]

    if RopesOn() then
        self:DrawRopes()
    end
end
