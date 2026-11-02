-- =========================================================================
-- REBUILT (16.9). Goes to:  lua/weapons/gmod_tool/stools/acf_fusion_tool.lua
--
-- THE FUSION ENGINE TOOL (based on the generator tool). ONE SLIDER: the rated power in hp (FusionHPMin 250 .. FusionHPMax 6500, the hp of a generator hub that would make the same energy). The mass, the model
-- scale, the spin-up time and the PPC numbers follow the slider on straight lines (FUSION ENGINES in the config).
--   Left-click        spawn a fusion engine with the slider's rating, or change the fusion engine you are aiming at to it
--   Right-click       LINK (from the link kit, lua/autorun/acf_lazers_linkkit.lua). Click the fusion engine first (it turns green), then the capacitor to link it to.
--   Shift + right-click   add one more thing to the selection, or take a selected thing off it. Then a plain right-click links ALL selected things to the one you aim at.
--   Reload            UNLINK. With things selected, aim at the one to unlink them from. With nothing selected, it breaks every link of the thing you aim at.
--   Right-click on nothing, or putting the tool away, clears the selection.
-- A fresh engine is NOT parented and will not run: parent it to its vehicle (the GMod parent tool) first. The tool says so after every spawn.
-- If the server does not know the fusion engine (its folder is not on the SERVER, or its init.lua stopped before it registered), a left click says which of the two it is, instead of ACF's one-line error.
-- The readout in the menu and on the toolgun's own screen comes from ACFLazers.GetFusionReadout in the config, so the tool cannot disagree with the engine.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Fusion Engine Spawner"

-- Same shared table the entities use. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_fusion_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.LinkKit, "[acf_fusion_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")
assert(ACFLazers.GetFusionReadout and ACFLazers.ClampFusionHP and ACFLazers.FusionNumber, "[acf_fusion_tool] lua/autorun/acf_lazers_config.lua is older than this file (it has no 16.9 fusion helpers). Copy the config of the same batch (16.9).")

TOOL.ClientConVar["hp"] = ACFLazers.FusionNumber("FusionHPDefault")

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the little help lines at the bottom-left of the screen.
ACFLazers.LinkKit.Install(TOOL, "acf_fusion_tool", "Spawn a fusion engine of the picked size, or change the one you are aiming at")

if CLIENT then
    language.Add("tool.acf_fusion_tool.name", "ACF Fusion Engine Tool")
    language.Add("tool.acf_fusion_tool.desc", "Spawns fusion engines (they make energy for the capacitors they are linked to) and links fusion engines, capacitors, generators and lazers together.")

    -- Fonts for the readouts. [KNOW] surface.CreateFont(name, table) is client-only; a font family the computer does not have falls back to a default one.
    surface.CreateFont("ACFLazersFusBig",   { font = "Arial", size = 42, weight = 900 })
    surface.CreateFont("ACFLazersFusMid",   { font = "Arial", size = 20, weight = 700 })
    surface.CreateFont("ACFLazersFusSmall", { font = "Arial", size = 15, weight = 600 })

    local ColBack  = Color(24, 26, 31)
    local ColAmber = Color(255, 190, 40)
    local ColWhite = Color(232, 232, 232)
    local ColGrey  = Color(150, 156, 168)
    local ColHurt  = Color(235, 120, 95)

    -- 1234567.8 -> "1,234,568"
    local function Commas(n)
        local digits = string.format("%d", math.floor((tonumber(n) or 0) + 0.5))
        local sign   = ""

        if digits:sub(1, 1) == "-" then sign = "-"; digits = digits:sub(2) end

        digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()

        if digits:sub(1, 1) == "," then digits = digits:sub(2) end

        return sign .. digits
    end

    -- seconds -> "99.4 s" / "11 min 36 s" / "2.3 h"
    local function Duration(seconds)
        if seconds < 100 then return string.format("%.1f s", seconds) end
        if seconds < 3600 then return string.format("%d min %d s", math.floor(seconds / 60), math.floor(seconds % 60)) end

        return string.format("%.1f h", seconds / 3600)
    end

    -- The rated power on the slider (the slider's default when the variable is missing, held inside the range).
    local function PickedHP()
        local convar = GetConVar("acf_fusion_tool_hp")

        return ACFLazers.ClampFusionHP(convar and convar:GetFloat() or ACFLazers.FusionNumber("FusionHPDefault"))
    end

    -- Only works the numbers out again when the slider moved (the screen is drawn every frame).
    local cachedHP, cachedShow

    local function Readout()
        local hp = PickedHP()

        if cachedHP ~= hp then
            cachedHP   = hp
            cachedShow = ACFLazers.GetFusionReadout(hp)
        end

        return cachedShow
    end

    -- A big number with its unit after it, centred on cx. Returns the height used.
    local function BigNumber(value, unit, cx, y, color)
        local text = Commas(value)

        surface.SetFont("ACFLazersFusBig")
        local tw, th = surface.GetTextSize(text)

        surface.SetFont("ACFLazersFusMid")
        local uw, uh = surface.GetTextSize(unit)

        local gap = 6
        local x   = cx - (tw + gap + uw) / 2

        draw.SimpleText(text, "ACFLazersFusBig", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(unit, "ACFLazersFusMid", x + tw + gap, y + th - uh - 3, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        return th
    end

    -- Draws the readout block (used by the menu panel and by the toolgun screen). `show` is ACFLazers.GetFusionReadout's table. Returns the y under the last line.
    local function DrawReadout(show, w, top, heading)
        local cx = w / 2
        local _, lh = draw.SimpleText(heading, "ACFLazersFusSmall", cx, top, ColGrey, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        local y = top + lh + 2

        y = y + BigNumber(show.rate, "kJ/s", cx, y, ColAmber) + 2

        local function Line(text, color)
            local _, h = draw.SimpleText(text, "ACFLazersFusSmall", cx, y, color or ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

            y = y + h + 1
        end

        Line(string.format("%d hp x %g kJ per hp", show.hp, show.kjPerHP))
        Line(string.format("%s kg, model scale %.2f", Commas(show.mass), show.scale))
        Line(string.format("0 to 100%% in %.1f s", show.spinUp))
        Line(string.format("holds %s kJ (%.1f kg of HE)", Commas(show.chargeMax), show.blastKg), ColHurt)
        Line(string.format("PPC hit: -%.0f%% (50 mm) to -%.0f%% (300 mm)", show.ppcCutSmall * 100, show.ppcCutBig * 100), ColHurt)
        Line(string.format("%g unit cap full in %s", show.capSize, Duration(show.fillSeconds)))

        return y
    end

    -- The toolgun's own screen. [KNOW] TOOL:DrawToolScreen(width, height) is called every frame on the client while this tool is held; the screen is a square (256 x 256).
    function TOOL:DrawToolScreen(w, h)
        local show = Readout()

        surface.SetDrawColor(ColBack)
        surface.DrawRect(0, 0, w, h)

        draw.SimpleText("FUSION ENGINE", "ACFLazersFusMid", w / 2, 10, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        DrawReadout(show, w, 44, string.format("%d hp rating makes", show.hp))
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Fusion Engine Configuration", Description = "Tune settings before spawning." })

        -- The rated power is also the size: the mass, the model scale, the spin-up time and the PPC numbers follow it on straight lines (FUSION ENGINES in the config).
        panel:NumSlider("Rated power (hp)", "acf_fusion_tool_hp", ACFLazers.FusionNumber("FusionHPMin"), ACFLazers.FusionNumber("FusionHPMax"), 0)

        -- The big readout. [KNOW] DForm:AddItem(panel) puts a panel on its own full-width row; a DPanel with its own Paint draws whatever we tell it to.
        local box = vgui.Create("DPanel")

        box:SetTall(176)

        function box:Paint(w, h)
            draw.RoundedBox(8, 0, 0, w, h, ColBack)
            DrawReadout(Readout(), w, 6, "ENERGY MADE PER SECOND AT 100% OPERATING")
        end

        panel:AddItem(box)

        local info = panel:Help("")

        local function Refresh()
            local show = Readout()

            if IsValid(info) then
                info:SetText(string.format("A %d hp fusion engine: model scale %.2f, mass %s kg. Switched on (the Active wire input), its operating percent climbs from 0 to 100%% in %.1f seconds, "
                    .. "never higher than its efficiency (full health and low heat = 100%%; it explodes at %g F). It makes %s kJ/s at 100%%, and a quarter of what it puts into the capacitors "
                    .. "is heat in itself. A PPC going off within %g units cuts its operating percent (%.0f%% for a 50 mm shot, %.0f%% for a 300 mm one) and it waits %g to %.1f seconds before climbing back. "
                    .. "Its charge (up to %s kJ) is the size of the explosion if it blows up, and drains away slowly when it is switched off. The reference capacitor holds %s kJ.",
                    show.hp, show.scale, Commas(show.mass), show.spinUp, show.criticalF, Commas(show.rate), ACFLazers.FusionNumber("FusionPPCRange"),
                    show.ppcCutSmall * 100, show.ppcCutBig * 100, show.recoveryMin, show.recoveryMax, Commas(show.chargeMax), Commas(show.capacity)))
            end
        end

        cvars.AddChangeCallback("acf_fusion_tool_hp", Refresh, "acf_fusion_tool_refresh")
        Refresh()

        panel:Help("Link the fusion engine to a capacitor with the right-click (the engine first, then the capacitor), and the capacitor to a lazer. The engine only runs while it is PARENTED to something: "
            .. "parent it to its vehicle with the parent tool. The Active wire input (1 = on) switches it on; nothing wired counts as on. Wire outputs: Operating, Efficiency, Charge, ChargePct, HeatPct, Energy, Parented and more.")
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

-- [CHANGED 1] (16.9) Does ACF know the class? nil when it does; otherwise WHY NOT, in words (ACF itself only says "acf_fusion is not a registered ACF entity class."). Two causes are told apart:
-- the server has the entity (scripted_ents knows it) but its init.lua never got to the registration, or the server has no such entity at all (the folder is not there, or was not loaded).
local function WhyNotRegistered(Entities)
    if not (Entities.Get and not Entities.Get("acf_fusion")) then return nil end

    if scripted_ents and scripted_ents.GetStored and scripted_ents.GetStored("acf_fusion") then
        return "The server has the acf_fusion entity folder, but its init.lua never registered it with ACF. Look in the SERVER console for lines starting with [acf_fusion]: an error there says why. "
            .. "(If there is no '[acf_fusion] init.lua version' line at all, the server did not run the file: restart it after copying.)"
    end

    return "The server has no acf_fusion entity at all: lua/entities/acf_fusion/ (init.lua, shared.lua and cl_init.lua) is not on the SERVER, or the server was not restarted after you copied it."
end

-- ===================== left click: spawn / update =====================

function TOOL:LeftClick(trace)
    if trace.HitSky then return false end
    if CLIENT then return true end

    local ply      = self:GetOwner()
    local Entities = ACF.Classes.Entities

    -- The entity clamps this again server-side (VerifyData in the fusion engine's init.lua), so a stale ConVar is safe.
    local Data = {
        RatedHP = ply:GetInfoNum("acf_fusion_tool_hp", ACFLazers.FusionNumber("FusionHPDefault")),
    }

    -- Tell the player when the server will squeeze the rating into the allowed range.
    local low, high = ACFLazers.FusionNumber("FusionHPMin"), ACFLazers.FusionNumber("FusionHPMax")

    if Data.RatedHP < low or Data.RatedHP > high then
        Say(ply, "Info", string.format("Rating limited to %d hp (the allowed range is %d to %d hp).", ACFLazers.ClampFusionHP(Data.RatedHP), low, high))
    end

    -- Aiming at one of our fusion engines: update it to the slider's rating instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_fusion" then
        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that fusion engine.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in the fusion engine's init.lua

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn standing on the surface we aimed at, with its front (+X) turned toward the player. [GUESS] that the model's up is +Z. Vector:AngleEx(up) makes an angle whose forward
    -- is that vector and whose up is the surface normal.
    local toPlayer = ply:GetPos() - trace.HitPos

    toPlayer = toPlayer - trace.HitNormal * toPlayer:Dot(trace.HitNormal) -- along the surface only

    local angles

    if toPlayer:LengthSqr() > 1 then
        angles = toPlayer:GetNormalized():AngleEx(trace.HitNormal)
    else
        angles = trace.HitNormal:Angle() -- standing right on top of the spot: the wiremod way (the surface normal's angle, pitched 90 degrees)
        angles.pitch = angles.pitch + 90
    end

    -- Is the class there at all? If not, say exactly which part is missing (above).
    local why = WhyNotRegistered(Entities)

    if why then
        Say(ply, "Error", "Couldn't create the fusion engine: " .. why)

        return false
    end

    local ok, result = Entities.Spawn("acf_fusion", ply, trace.HitPos, angles, Data) -- calls MakeACFFusion in the fusion engine's init.lua

    if not ok then
        Say(ply, "Error", "Couldn't create the fusion engine: " .. tostring(result))

        return false
    end

    -- Put its bottom on the surface (OBBMins().z is the distance from the middle down to the bottom of the model)
    result:SetPos(trace.HitPos - trace.HitNormal * result:OBBMins().z)

    -- Freeze it like ACF's tool does (the scalable base already freezes when it scales; this just makes it explicit)
    local phys = result:GetPhysicsObject()

    if IsValid(phys) then
        phys:EnableMotion(false)
    end

    Say(ply, "Info", "Fusion engine spawned. It will not run until it is PARENTED to something (use the parent tool). Wire its Active input to switch it on (nothing wired counts as on).")

    return true
end
