-- =========================================================================
-- NEW FILE (16).  Goes to:  lua/weapons/gmod_tool/stools/acf_ppc_tool.lua
-- The PPC spawner: one slider (the muzzle diameter) and a readout of what that size gives. Left-click spawns a PPC, or updates the one you are aiming at. Right-click, Shift + right-click and
-- Reload (link / unlink) come from the shared link kit, like every tool of this addon: link engine > generator > capacitor > PPC.
-- Needs the 16 config (lua/autorun/acf_lazers_config.lua: the PPC knobs and helpers) and the 16 link kit (lua/autorun/acf_lazers_linkkit.lua).
-- 16.2: the info line under the slider also says what a shot does to the PPC's own heat (kJ and percent of its limit). Nothing else changed.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "PPC Spawner"

local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_ppc_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.PPCNumber and ACFLazers.GetPPCReadout, "[acf_ppc_tool] lua/autorun/acf_lazers_config.lua is older than this tool (the PPC helpers are missing): copy the new config too")
assert(ACFLazers.LinkKit, "[acf_ppc_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")

TOOL.ClientConVar["caliber"] = ACFLazers.PPCNumber("PPCCaliberBase")

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the help lines at the bottom-left of the screen: the shared link kit.
ACFLazers.LinkKit.Install(TOOL, "acf_ppc_tool", "Spawn a PPC with this size, or update the one you are aiming at")

if CLIENT then
    language.Add("tool.acf_ppc_tool", "ACF PPC Spawner Tool")
    language.Add("tool.acf_ppc_tool.name", "ACF PPC Spawner Tool")
    language.Add("tool.acf_ppc_tool.desc", "Spawns an ACF PPC (a capacitor-fed gun that fires one energy projectile per shot), or updates the one you are aiming at. Also links engines, generators, capacitors, lazers, PPCs and radiators together.")

    -- The one line under the slider: what a PPC of this size is. All the numbers come from the config's helpers, the same ones the server uses.
    local function ReadoutText(caliber)
        local info = ACFLazers.GetPPCReadout(caliber)

        local text = string.format("A %g mm PPC: %.0f kJ per shot, muzzle velocity %.0f m/s, %.2f kg of HE (blast radius %.1f m), mass %d kg. The projectile is deleted after %g s and does %d%% of its damage by then.",
            caliber, info.energy, info.speed, info.filler, info.radiusM, info.mass, info.lifetime, math.floor(info.damageEnd * 100 + 0.5))

        -- (16.2) what a shot does to the PPC itself (an older config has no heat numbers: no sentence)
        if info.heat and info.heatPct then
            text = text .. string.format(" Each shot heats the PPC by %.0f kJ (%.0f%% of its limit, before cooling); over 100%% it damages itself.", info.heat, info.heatPct)
        end

        return text
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF PPC Configuration", Description = "Pick the muzzle diameter before spawning." })

        panel:AddControl("Slider", {
            Label = "Muzzle diameter (mm)",
            Command = "acf_ppc_tool_caliber",
            Min = ACFLazers.PPCNumber("PPCCaliberMin"),
            Max = ACFLazers.PPCNumber("PPCCaliberMax"),
            Value = ACFLazers.PPCNumber("PPCCaliberBase")
        })

        local info = panel:Help("")

        local function Refresh(caliber)
            if not IsValid(info) then return end -- the panel was closed or rebuilt

            local convar = GetConVar("acf_ppc_tool_caliber")

            caliber = tonumber(caliber) or (convar and convar:GetFloat()) or ACFLazers.PPCNumber("PPCCaliberBase")
            caliber = ACFLazers.ClampPPCCaliber(caliber)

            info:SetText(ReadoutText(caliber))
        end

        -- The same name every time the panel is built, so an old panel's callback is replaced instead of piling up.
        cvars.AddChangeCallback("acf_ppc_tool_caliber", function(_, _, new) Refresh(new) end, "acf_ppc_tool_readout")

        Refresh()
        timer.Simple(0, Refresh) -- once more after the slider has read its saved value

        panel:Help("Link the PPC to a capacitor with the right-click link controls of this tool (or any tool of this addon). A shot is released when its Fire wire input goes from 0 to above 0 and the capacitors hold the shot's energy.")
    end
end

function TOOL:LeftClick(trace)
    if trace.HitSky then return false end
    if CLIENT then return true end

    local ply      = self:GetOwner()
    local Entities = ACF.Classes.Entities
    local Messages = ACF.Utilities.Messages

    -- The entity clamps this again server-side (VerifyData in init.lua); the note is only so the player knows.
    local Data = {
        Caliber = ply:GetInfoNum("acf_ppc_tool_caliber", ACFLazers.PPCNumber("PPCCaliberBase")),
    }

    local clamped = ACFLazers.ClampPPCCaliber(Data.Caliber)

    if math.abs(clamped - Data.Caliber) > 0.001 then
        Messages.SendChat(ply, "Info", string.format("Caliber limited to %g mm (a PPC goes from %g to %g mm).", clamped, ACFLazers.PPCNumber("PPCCaliberMin"), ACFLazers.PPCNumber("PPCCaliberMax")))
    end

    -- Aiming at one of our PPCs: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_ppc" then
        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in init.lua

        Messages.SendChat(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn
    local spawnPos = trace.HitPos + (trace.HitNormal * 24)

    local angles = trace.HitNormal:Angle()
    angles:RotateAroundAxis(angles:Right(), -90)

    local ok, result = Entities.Spawn("acf_ppc", ply, spawnPos, angles, Data) -- calls MakeACFPPC in init.lua

    if not ok then
        Messages.SendChat(ply, "Error", "Couldn't create the PPC: " .. tostring(result))

        return false
    end

    -- Freeze it like ACF's tool does (base_scalable already freezes when it scales; this just makes it explicit)
    local phys = result:GetPhysicsObject()

    if IsValid(phys) then
        phys:EnableMotion(false)
    end

    return true
end
