-- =========================================================================
-- CHANGES vs the acf_lazer_tool.lua you have now (version 9.7). Search this file for [CHANGED n].
--   [CHANGED 1] The lazer tool can LINK now, like the capacitor tool: right-click, Shift + right-click and Reload come from the shared link kit (lua/autorun/acf_lazers_linkkit.lua), installed
--               with one line near the top. So you can link engine > generator > capacitor > lazer with any of the tools. The help lines at the bottom-left of the screen are the kit's.
--               Nothing else changed: same sliders, same left click
--   [CHANGED 2] (16.1) AUTO-FOCUS: lazers now move their own focal length while they fire (config LazerAutoFocus / LazerFocusSpeed), so the Focal Length slider says it is where the lazer STARTS and the
--               text under the sliders says what the lazer does with it. Nothing else changed.
--   (The 9.x numbering of earlier handoffs is gone: [CHANGED n] marks restart at 1 with every whole-number handoff.)
--   Goes to:  lua/weapons/gmod_tool/stools/acf_lazer_tool.lua
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Lazer Spawner"

-- Same shared table the entity uses. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_lazer_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.LinkKit, "[acf_lazer_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load") -- [CHANGED 1]

-- Define default ClientConVars tied to this tool
TOOL.ClientConVar["caliber"] = Config.CaliberBase
TOOL.ClientConVar["focal"] = Config.FocalDefault
TOOL.ClientConVar["colorset"] = "0"
TOOL.ClientConVar["safezone"] = "1" -- 1 = checked by default (this is the person's own protection setting, see the checkbox below)
TOOL.ClientConVar["focusamount"] = Config.FocusAmountDefault -- replaces "focalrange"
TOOL.ClientConVar["usecustomcolor"] = "0"
TOOL.ClientConVar["customr"] = Config.CustomColorDefault[1]
TOOL.ClientConVar["customg"] = Config.CustomColorDefault[2]
TOOL.ClientConVar["customb"] = Config.CustomColorDefault[3]
-- the bursttime / rechargetime ConVars were here

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the help lines at the bottom-left of the screen: the shared link kit (lua/autorun/acf_lazers_linkkit.lua). [CHANGED 1]
ACFLazers.LinkKit.Install(TOOL, "acf_lazer_tool", "Spawn a lazer with these settings, or update the one you are aiming at") -- [CHANGED 1]

if CLIENT then
    language.Add("tool.acf_lazer_tool", "ACF Laser Spawner Tool")
    language.Add("tool.acf_lazer_tool.name", "ACF Laser Spawner Tool") -- [CHANGED 1]
    language.Add("tool.acf_lazer_tool.desc", "Spawns a custom ACF laser, or updates the one you are aiming at. Also links engines, generators, capacitors and lazers together.") -- [CHANGED 1]

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Laser Configuration", Description = "Tune settings before spawning." })

        panel:AddControl("Slider", {
            Label = Config.SizeLabel .. " (mm)", -- was "Laser Size (Caliber mm)"
            Command = "acf_lazer_tool_caliber",
            Min = Config.CaliberMin,   -- was 20
            Max = Config.CaliberMax,   -- was 2000
            Value = Config.CaliberBase -- was 100
        })

        -- kept in a variable: the code below moves its ends when the size slider moves
        local focalSlider = panel:AddControl("Slider", {
            Label = (ACFLazers.AutoFocusOn and ACFLazers.AutoFocusOn()) and "Focal Length (start: the lazer focuses itself)" or "Focal Length", -- [CHANGED 2]
            Command = "acf_lazer_tool_focal",
            Min = Config.FocalMin,     -- was 200
            Max = ACFLazers.GetFocalMax(Config.CaliberMax), -- the widest possible to start with; ApplyFocalLimits below narrows it to the lazer size
            Value = Config.FocalDefault -- was 300
        })

        -- FOCUS AMOUNT (replaces "Range from intended focal"). Where the damage is at its max is the focal length above. This slider is how tightly the damage is gathered round that spot
        -- (along the beam): 0 = spread over the widest zone the lazer allows, 100 = the tightest, with a stronger peak. The zone's size comes from the lazer's size.
        panel:AddControl("Slider", {
            Label = "Focus amount",
            Command = "acf_lazer_tool_focusamount",
            Min = Config.FocusAmountMin,
            Max = Config.FocusAmountMax,
            Value = Config.FocusAmountDefault
        })

        local focusInfo = panel:Help("") -- filled in by ApplyFocalLimits: what the two sliders come to for the size you picked

        -- [CHANGED 2] what the automatic focus does, when it is on (an older config without the helpers: no note)
        local autoNote = ""

        if ACFLazers.AutoFocusOn and ACFLazers.GetFocusSpeed and ACFLazers.AutoFocusOn() then
            autoNote = string.format(" AUTO-FOCUS: while it fires, the lazer moves its own focal length toward the first thing its beam hits, at most %d units per second. The slider is where it starts.", math.floor(ACFLazers.GetFocusSpeed()))
        end

        -- Keep the Focal Length slider inside what the chosen lazer size allows: the same limit the server uses (ACFLazers.GetFocalLimits in the config).
        -- Its top end moves when the size slider moves, and a saved value that no longer fits is pulled inside (the saved number AND the slider).
        -- [GUESS] AddControl hands back the slider panel (I believe GMod's control panel code returns it) and the panel has SetMinMax / SetValue (DNumSlider does).
        -- If AddControl returned nothing, the IsValid check below makes all of this a harmless no-op and the server limit (and the chat note) still work.
        local function PullInside(slider, command, low, high)
            local convar = GetConVar(command)

            if not convar then return end

            local value = convar:GetFloat()

            -- a little slack: a saved number comes back from the game as a float and may differ from what was written in its last digits
            if value < low - 0.01 or value > high + 0.01 then
                local clamped = math.Clamp(value, low, high)

                RunConsoleCommand(command, tostring(clamped))
                slider:SetValue(clamped)
            end
        end

        local function ApplyFocalLimits(caliber)
            if not IsValid(focalSlider) then return end -- the panel was closed or rebuilt

            local sizeConVar = GetConVar("acf_lazer_tool_caliber")

            caliber = tonumber(caliber) or (sizeConVar and sizeConVar:GetFloat()) or Config.CaliberBase
            caliber = math.Clamp(caliber, Config.CaliberMin, Config.CaliberMax)

            local focalMin, focalMax = ACFLazers.GetFocalLimits(caliber)

            focalSlider:SetMinMax(focalMin, focalMax)
            PullInside(focalSlider, "acf_lazer_tool_focal", focalMin, focalMax)

            if IsValid(focusInfo) then
                focusInfo:SetText(string.format("A %g mm lazer: focal length up to %d units. Focus amount %g makes the focused zone %d units either side of the focal length, %g makes it %d (and above %g the centre also gets a damage bonus).",
                    caliber, math.floor(focalMax), Config.FocusAmountMin, math.floor(ACFLazers.GetFocalRange(caliber, Config.FocusAmountMin)),
                    Config.FocusAmountMax, math.floor(ACFLazers.GetFocalRange(caliber, Config.FocusAmountMax)), Config.FocusBoostStart) .. autoNote)
            end
        end

        -- Runs whenever the size changes. The same name every time the panel is built, so an old panel's callback is replaced instead of piling up.
        cvars.AddChangeCallback("acf_lazer_tool_caliber", function(_, _, new) ApplyFocalLimits(new) end, "acf_lazer_tool_focal_limits")

        ApplyFocalLimits()
        timer.Simple(0, ApplyFocalLimits) -- once more after the slider has read its saved value

        -- the burst length and forced recharge time sliders were here

        -- 0 = red > green > cyan > blue-purple.  1 = orange > yellow > blue > purple (planned for burst lazers).
        panel:AddControl("Checkbox", {
            Label = "Alternate beam colour set (orange / yellow / blue / purple)",
            Command = "acf_lazer_tool_colorset"
        })

        -- Your own colour. While this box is ticked the beam uses the colour below instead of the colour set, at any size.
        panel:AddControl("Checkbox", {
            Label = "Use custom beam colour (instead of the colour set)",
            Command = "acf_lazer_tool_usecustomcolor"
        })

        -- ColorPicker(label, red convar, green convar, blue convar): the same picker GMod's own tools show. The opacity convar is the optional fifth one; leaving it out
        -- leaves out the opacity bar. [GUESS] that GMod's rope tool does it this way (test: the picker shows no opacity bar)
        panel:ColorPicker("Custom beam colour", "acf_lazer_tool_customr", "acf_lazer_tool_customg", "acf_lazer_tool_customb")

        -- This is YOUR setting as a person: while you stand in a safezone, lazers do only a fraction of their damage to you and can't set you on fire
        -- (see SafezoneDamageMult in the config). It does not change how your own lazers work.
        panel:AddControl("Checkbox", {
            Label = "Safezone protection for ME (reduced lazer damage, no fire, while I'm in a safezone)",
            Command = "acf_lazer_tool_safezone"
        })
    end
end

function TOOL:LeftClick(trace)
    if trace.HitSky then return false end
    if CLIENT then return true end

    local ply      = self:GetOwner()
    local Entities = ACF.Classes.Entities
    local Messages = ACF.Utilities.Messages

    -- The entity clamps these again server-side (VerifyData in init.lua), so a stale convar from the old 20-2000 slider is safe.
    local Data = {
        Caliber = ply:GetInfoNum("acf_lazer_tool_caliber", Config.CaliberBase),
        Focal   = ply:GetInfoNum("acf_lazer_tool_focal", Config.FocalDefault),
        FocusAmount = ply:GetInfoNum("acf_lazer_tool_focusamount", Config.FocusAmountDefault),
        ColorSet = ply:GetInfoNum("acf_lazer_tool_colorset", 0),
        UseCustomColor = ply:GetInfoNum("acf_lazer_tool_usecustomcolor", 0),
        CustomR = ply:GetInfoNum("acf_lazer_tool_customr", Config.CustomColorDefault[1]),
        CustomG = ply:GetInfoNum("acf_lazer_tool_customg", Config.CustomColorDefault[2]),
        CustomB = ply:GetInfoNum("acf_lazer_tool_customb", Config.CustomColorDefault[3]),
        -- BurstTime / RechargeTime were here
    }

    -- Tell the player when the server will squeeze their focal length to fit this lazer's size (VerifyData in init.lua does the actual limiting).
    local caliber  = math.Clamp(Data.Caliber, Config.CaliberMin, Config.CaliberMax)
    local _, focalMax = ACFLazers.GetFocalLimits(caliber)

    if Data.Focal > focalMax then
        Messages.SendChat(ply, "Info", string.format("Focal length limited to %d for a lazer this size.", math.floor(focalMax)))
    end

    -- the "burst length limited" chat note was here

    -- Aiming at one of our lazers: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_lazer" then
        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in init.lua

        Messages.SendChat(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn
    local spawnPos = trace.HitPos + (trace.HitNormal * 24)

    local angles = trace.HitNormal:Angle()
    angles:RotateAroundAxis(angles:Right(), -90)

    local ok, result = Entities.Spawn("acf_lazer", ply, spawnPos, angles, Data) -- calls MakeACFLazer in init.lua

    if not ok then
        Messages.SendChat(ply, "Error", "Couldn't create the lazer: " .. tostring(result))

        return false
    end

    -- Freeze it like ACF's tool does (base_scalable already freezes when it scales; this just makes it explicit)
    local phys = result:GetPhysicsObject()

    if IsValid(phys) then
        phys:EnableMotion(false)
    end

    return true
end
