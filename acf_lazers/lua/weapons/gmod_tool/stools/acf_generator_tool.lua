-- =========================================================================
-- CHANGED (13). Goes to:  lua/weapons/gmod_tool/stools/acf_generator_tool.lua
--
-- THE GENERATOR TOOL (based on the capacitor tool).
--   Left-click        spawn a generator hub with the slider's rated power, or update the generator you are aiming at (the model grows / shrinks with the rating:
--                     50 hp = 0.5 scale, 350 hp = 1, 3500 hp = 2, see GenScaleKnots in the config)
--   Right-click       LINK (from the link kit, lua/autorun/acf_lazers_linkkit.lua). Click the first thing (engine, generator, capacitor or lazer): it turns green. Then click what to link it to.
--                     engine > generator > capacitor > lazer.
--   Shift + right-click   add one more thing to the selection, or take a selected thing off it. Then a plain right-click links ALL selected things to the one you aim at.
--   Reload            UNLINK. With things selected, aim at the one to unlink them from. With nothing selected, it breaks every link of the thing you aim at.
--   Right-click on nothing, or putting the tool away, clears the selection.
--
-- WHAT CHANGED vs the file you have now (search for [CHANGED n]):
--   1  The tool menu has a big energy readout: "910 kJ/s" in large amber letters for the slider's rating, with the same hub damaged to 0% health and the fill time of a
--      reference capacitor under it. It follows the slider as you drag it.
--   2  The toolgun's own little screen (TOOL:DrawToolScreen) shows the same numbers, so you can see them without opening the menu.
--   3  The sentence about breaking engine links when overloaded is gone (the config knob it read, GenOverloadTolerance, no longer exists): the rating is a limit now, the hub just
--      takes at most that many hp.
--   All the numbers come from ACFLazers.GetGenReadout in the config file, so the tool cannot disagree with the hub.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Generator Spawner"

-- Same shared table the entities use. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_generator_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.LinkKit, "[acf_generator_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")

TOOL.ClientConVar["hp"] = Config.GenHPDefault

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the little help lines at the bottom-left of the screen.
ACFLazers.LinkKit.Install(TOOL, "acf_generator_tool", "Spawn a generator hub with this rating, or update the one you are aiming at")

if CLIENT then
    language.Add("tool.acf_generator_tool.name", "ACF Generator Tool")
    language.Add("tool.acf_generator_tool.desc", "Spawns generator hubs (engines turn them into capacitor energy) and links engines, generators, capacitors and lazers together.")

    -- [CHANGED 1] Fonts for the readouts. [KNOW] surface.CreateFont(name, table) is client-only; a font family the computer does not have falls back to a default one.
    surface.CreateFont("ACFLazersGenBig",   { font = "Arial", size = 42, weight = 900 })
    surface.CreateFont("ACFLazersGenMid",   { font = "Arial", size = 20, weight = 700 })
    surface.CreateFont("ACFLazersGenSmall", { font = "Arial", size = 15, weight = 600 })

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

    -- Only works the numbers out again when the slider moved (the screen is drawn every frame).
    local cachedHP, cachedShow

    local function Readout()
        local convar = GetConVar("acf_generator_tool_hp")
        local hp     = ACFLazers.ClampGenHP(convar and convar:GetFloat() or Config.GenHPDefault)

        if cachedHP ~= hp then
            cachedHP   = hp
            cachedShow = ACFLazers.GetGenReadout(hp)
        end

        return cachedShow
    end

    -- A big number with its unit after it, centred on cx. Returns the height used.
    local function BigNumber(value, unit, cx, y, color)
        local text = Commas(value)

        surface.SetFont("ACFLazersGenBig")
        local tw, th = surface.GetTextSize(text)

        surface.SetFont("ACFLazersGenMid")
        local uw, uh = surface.GetTextSize(unit)

        local gap = 6
        local x   = cx - (tw + gap + uw) / 2

        draw.SimpleText(text, "ACFLazersGenBig", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(unit, "ACFLazersGenMid", x + tw + gap, y + th - uh - 3, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        return th
    end

    -- Draws the readout block (used by the menu panel and by the toolgun screen). `show` is ACFLazers.GetGenReadout's table.
    local function DrawReadout(show, w, top, heading)
        local cx = w / 2
        local _, lh = draw.SimpleText(heading, "ACFLazersGenSmall", cx, top, ColGrey, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        local y = top + lh + 2

        y = y + BigNumber(show.rate, "kJ/s", cx, y, ColAmber) + 2

        _, lh = draw.SimpleText(string.format("%d hp x %g kJ per hp", show.hp, show.kjPerHP), "ACFLazersGenSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        _, lh = draw.SimpleText(string.format("at 0%% health: %s kJ/s (x%g)", Commas(show.rateDamaged), show.efficiencyDamaged), "ACFLazersGenSmall", cx, y, ColHurt, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        _, lh = draw.SimpleText(string.format("%d unit cap full in %s", show.capSize, Duration(show.fillSeconds)), "ACFLazersGenSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        return y + lh
    end

    -- [CHANGED 2] The toolgun's own screen. [KNOW] TOOL:DrawToolScreen(width, height) is called every frame on the client while this tool is held; the screen is a square (256 x 256).
    function TOOL:DrawToolScreen(w, h)
        local show = Readout()

        surface.SetDrawColor(ColBack)
        surface.DrawRect(0, 0, w, h)

        draw.SimpleText("GENERATOR HUB", "ACFLazersGenMid", w / 2, 10, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        DrawReadout(show, w, 44, string.format("%d hp rating makes", show.hp))
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Generator Hub Configuration", Description = "Tune settings before spawning." })

        -- The rated power is also the size: the model is scaled by it (GenScaleKnots in the config). It is the most horsepower the hub takes from its engines.
        panel:NumSlider("Rated power (hp)", "acf_generator_tool_hp", Config.GenHPMin, Config.GenHPMax, 0)

        -- [CHANGED 1] The big readout. [KNOW] DForm:AddItem(panel) puts a panel on its own full-width row; a DPanel with its own Paint draws whatever we tell it to.
        local box = vgui.Create("DPanel")

        box:SetTall(124)

        function box:Paint(w, h)
            draw.RoundedBox(8, 0, 0, w, h, ColBack)
            DrawReadout(Readout(), w, 6, "ENERGY MADE PER SECOND")
        end

        panel:AddItem(box)

        local info = panel:Help("")

        local function Refresh()
            local show = Readout()

            if IsValid(info) then
                info:SetText(string.format("A %d hp hub: model scale %.2f, mass %d kg. It takes at most %d hp from its engines in total: an engine that pushes more is not harmed, the hub just ignores the rest. "
                    .. "It needs engines that push at least that to make the full amount. The reference capacitor holds %s kJ. A damaged hub makes less energy for the same hp, down to x%g at 0%% health.",
                    show.hp, show.scale, show.mass, show.hp, Commas(show.capacity), show.efficiencyDamaged))
            end
        end

        cvars.AddChangeCallback("acf_generator_tool_hp", Refresh, "acf_generator_tool_refresh")
        Refresh()

        panel:Help("Link an engine to the hub with the right-click (engine first, then the hub), the hub to a capacitor, and the capacitor to a lazer. The engine must be in front of the hub's input (within " .. Config.GenInputAngle .. " degrees of straight ahead from it). Ropes show with ACF's acf_mobilityropelinks setting.")
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

    -- The entity clamps this again server-side (VerifyData in the generator's init.lua), so a stale ConVar is safe.
    local Data = {
        RatedHP = ply:GetInfoNum("acf_generator_tool_hp", Config.GenHPDefault),
    }

    -- Tell the player when the server will squeeze the rating into the allowed range.
    if Data.RatedHP < Config.GenHPMin or Data.RatedHP > Config.GenHPMax then
        Say(ply, "Info", string.format("Rating limited to %d hp (the allowed range is %d to %d hp).", ACFLazers.ClampGenHP(Data.RatedHP), Config.GenHPMin, Config.GenHPMax))
    end

    -- Aiming at one of our generators: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_generator" then
        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that generator.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in the generator's init.lua

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn standing on the surface we aimed at, with its front (+X, the side the engine's shaft plugs into) turned toward the player. [GUESS] that the model's up is +Z and
    -- its front is +X (the input point GenInputPos = 20, 0, 1 says front is +X). Vector:AngleEx(up) makes an angle whose forward is that vector and whose up is the surface normal.
    local toPlayer = ply:GetPos() - trace.HitPos

    toPlayer = toPlayer - trace.HitNormal * toPlayer:Dot(trace.HitNormal) -- along the surface only

    local angles

    if toPlayer:LengthSqr() > 1 then
        angles = toPlayer:GetNormalized():AngleEx(trace.HitNormal)
    else
        angles = trace.HitNormal:Angle() -- standing right on top of the spot: the wiremod way (the surface normal's angle, pitched 90 degrees)
        angles.pitch = angles.pitch + 90
    end

    local ok, result = Entities.Spawn("acf_generator", ply, trace.HitPos, angles, Data) -- calls MakeACFGenerator in the generator's init.lua

    if not ok then
        Say(ply, "Error", "Couldn't create the generator: " .. tostring(result))

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
