-- =========================================================================
-- CHANGES vs the acf_capacitor_tool.lua you have now (version 9.7). Search this file for [CHANGED n].
--   [CHANGED 1] The linking part (select, Shift multi-select, link, unlink, green paint, holster, disconnect) moved out into the shared link kit, lua/autorun/acf_lazers_linkkit.lua,
--               so the lazer tool and the generator tool link exactly the same way. This file now only installs it (one line near the top). What you can select grew: engines and
--               generator hubs too (config LinkClasses). Nothing else about the tool changed: same sliders, same left click
--   (The 9.x numbering of earlier handoffs is gone: [CHANGED n] marks restart at 1 with every whole-number handoff.)
--   Goes to:  lua/weapons/gmod_tool/stools/acf_capacitor_tool.lua
--
-- THE CAPACITOR TOOL (based on the lazer tool).
--   Left-click        spawn a capacitor with the sliders' settings, or update the capacitor you are aiming at
--   Right-click       LINK (from the link kit). Click the first thing (engine, generator, capacitor or lazer): it turns green. Then click what to link it to.
--                     engine > generator > capacitor > lazer.   capacitor <-> capacitor = one group that shares the load.
--   Shift + right-click   add one more thing to the selection (every selected thing is green), or take a selected thing off it. Then a plain right-click on
--                     another thing links ALL of them to it at once.
--   Reload            UNLINK. With things selected, aim at the one to unlink them from. With nothing selected, it breaks every link of the thing you aim at.
--   Right-click on nothing, or putting the tool away, clears the selection.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Capacitor Spawner"

-- Same shared table the entities use. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_capacitor_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.LinkKit, "[acf_capacitor_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")

TOOL.ClientConVar["diameter"]   = Config.CapDiameterDefault
TOOL.ClientConVar["chargerate"] = Config.CapChargeRateDefault

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the little help lines at the bottom-left of the screen. [CHANGED 1]
ACFLazers.LinkKit.Install(TOOL, "acf_capacitor_tool", "Spawn a capacitor with these settings, or update the one you are aiming at") -- [CHANGED 1]

if CLIENT then
    language.Add("tool.acf_capacitor_tool.name", "ACF Capacitor Tool")
    language.Add("tool.acf_capacitor_tool.desc", "Spawns capacitors and links engines, generators, capacitors and lazers together.")

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Capacitor Configuration", Description = "Tune settings before spawning." })

        panel:AddControl("Slider", {
            Label = "Size: diameter (units)",
            Command = "acf_capacitor_tool_diameter",
            Min = Config.CapDiameterMin,
            Max = Config.CapDiameterMax,
            Value = Config.CapDiameterDefault
        })

        -- The charge rate slider ends at a third of the capacitor's capacity per second (config CapChargeRateMaxFraction), and a capacitor's capacity depends on its diameter,
        -- so this slider's top end follows the diameter slider (see Refresh below). You can also click the number and type a value.
        local rateSlider = panel:NumSlider("Charge rate (kJ per second)", "acf_capacitor_tool_chargerate", 0, ACFLazers.GetCapMaxChargeRate(Config.CapDiameterDefault), 1)
        local info       = panel:Help("")

        local function Refresh()
            local convar = GetConVar("acf_capacitor_tool_diameter")

            if not convar then return end

            local diameter = math.Clamp(convar:GetFloat(), Config.CapDiameterMin, Config.CapDiameterMax)
            local capacity = ACFLazers.GetCapCapacity(diameter)
            local maxRate  = ACFLazers.GetCapMaxChargeRate(diameter)
            local heKg     = capacity / ((ACF and ACF.HEPower) or 8000) * Config.CapExplosionMult

            if IsValid(rateSlider) then rateSlider:SetMax(maxRate) end

            -- A saved rate above the new top is pulled down (the saved number AND the slider), so the chat does not have to tell you it was limited.
            -- A little slack: a saved number comes back from the game as a float and may differ from what was written in its last digits.
            local rateConVar = GetConVar("acf_capacitor_tool_chargerate")

            if rateConVar and rateConVar:GetFloat() > maxRate + 0.01 then
                RunConsoleCommand("acf_capacitor_tool_chargerate", tostring(maxRate))
                if IsValid(rateSlider) then rateSlider:SetValue(maxRate) end
            end

            if IsValid(info) then
                info:SetText(string.format("A capacitor %g units across holds %.0f kJ when full (that blows like %.2f kg of ACF HE). The charge rate can go up to %.0f kJ per second (a third of that).", diameter, capacity, heKg, maxRate))
            end
        end

        cvars.AddChangeCallback("acf_capacitor_tool_diameter", Refresh, "acf_capacitor_tool_refresh")
        Refresh()
    end
end

-- ===================== helpers (server) =====================

-- Prop protection: if a prop-protection addon (CPPI) is installed, respect it.
local function MayTouch(tool, ply, ent)
    if ent.CPPICanTool and not ent:CPPICanTool(ply, tool.Mode) then return false end

    return true
end

local function Say(ply, kind, text)
    ACF.Utilities.Messages.SendChat(ply, kind, text)
end

-- ===================== left click: spawn / update =====================

function TOOL:LeftClick(trace)
    if trace.HitSky then return false end
    if CLIENT then return true end

    local ply      = self:GetOwner()
    local Entities = ACF.Classes.Entities

    -- The entity clamps these again server-side (VerifyData in the capacitor's init.lua), so a stale ConVar is safe.
    local Data = {
        Diameter   = ply:GetInfoNum("acf_capacitor_tool_diameter", Config.CapDiameterDefault),
        ChargeRate = ply:GetInfoNum("acf_capacitor_tool_chargerate", Config.CapChargeRateDefault),
    }

    -- Tell the player when the server will squeeze the charge rate to fit the capacitor's size.
    local diameter = math.Clamp(Data.Diameter, Config.CapDiameterMin, Config.CapDiameterMax)
    local capacity = ACFLazers.GetCapCapacity(diameter)
    local maxRate  = ACFLazers.GetCapMaxChargeRate(diameter)

    if Data.ChargeRate > maxRate then
        Say(ply, "Info", string.format("Charge rate limited to %.0f kJ/s (the fastest a capacitor this size can charge; it holds %.0f kJ).", maxRate, capacity))
    end

    -- Aiming at one of our capacitors: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_capacitor" then
        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that capacitor.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in the capacitor's init.lua

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn standing upright on the surface we aimed at (the usual Wiremod trick: the surface normal's angle, pitched 90 degrees)
    local angles = trace.HitNormal:Angle()
    angles.pitch = angles.pitch + 90

    local ok, result = Entities.Spawn("acf_capacitor", ply, trace.HitPos, angles, Data) -- calls MakeACFCapacitor in the capacitor's init.lua

    if not ok then
        Say(ply, "Error", "Couldn't create the capacitor: " .. tostring(result))

        return false
    end

    -- Put its bottom on the surface (OBBMins().z is the distance from the middle down to the bottom of the model)
    result:SetPos(trace.HitPos - trace.HitNormal * result:OBBMins().z)

    -- Freeze it like ACF's tool does (the scalable base already freezes when it scales; this just makes it explicit)
    local phys = result:GetPhysicsObject()

    if IsValid(phys) then
        phys:EnableMotion(false)
    end

    return true
end
