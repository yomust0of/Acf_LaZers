-- =========================================================================
-- NEW (16.8). Goes to:  lua/weapons/gmod_tool/stools/acf_fusion_tool.lua
--
-- THE FUSION ENGINE TOOL (based on the generator tool).
--   Left-click        spawn a fusion engine of the size picked in the drop-down (Large: 10,000 kg, model scale 1, the energy of a 6500 hp generator hub; Small: 1,500 kg, scale 0.25,
--                     250 hp; FusionTypes in the config), or change the fusion engine you are aiming at to that size
--   Right-click       LINK (from the link kit, lua/autorun/acf_lazers_linkkit.lua). Click the fusion engine first (it turns green), then the capacitor to link it to.
--   Shift + right-click   add one more thing to the selection, or take a selected thing off it. Then a plain right-click links ALL selected things to the one you aim at.
--   Reload            UNLINK. With things selected, aim at the one to unlink them from. With nothing selected, it breaks every link of the thing you aim at.
--   Right-click on nothing, or putting the tool away, clears the selection.
-- The energy readout in the menu and on the toolgun's own screen comes from ACFLazers.GetFusionReadout in the config, so the tool cannot disagree with the engine.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Fusion Engine Spawner"

-- Same shared table the entities use. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_fusion_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.LinkKit, "[acf_fusion_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")
assert(ACFLazers.GetFusionReadout and ACFLazers.GetFusionTypes and ACFLazers.ClampFusionType, "[acf_fusion_tool] lua/autorun/acf_lazers_config.lua is older than this file (it has no fusion helpers). Copy the config of the same batch (16.8).")

TOOL.ClientConVar["type"] = ACFLazers.ClampFusionType(nil)

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

    -- The size picked in the drop-down (the default size when the variable is missing or holds anything else).
    local function PickedType()
        local convar = GetConVar("acf_fusion_tool_type")

        return ACFLazers.ClampFusionType(convar and convar:GetString() or nil)
    end

    -- Only works the numbers out again when the pick changed (the screen is drawn every frame).
    local cachedType, cachedShow

    local function Readout()
        local id = PickedType()

        if cachedType ~= id then
            cachedType = id
            cachedShow = ACFLazers.GetFusionReadout(id)
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

    -- Draws the readout block (used by the menu panel and by the toolgun screen). `show` is ACFLazers.GetFusionReadout's table.
    local function DrawReadout(show, w, top, heading)
        local cx = w / 2
        local _, lh = draw.SimpleText(heading, "ACFLazersFusSmall", cx, top, ColGrey, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        local y = top + lh + 2

        y = y + BigNumber(show.rate, "kJ/s", cx, y, ColAmber) + 2

        _, lh = draw.SimpleText(string.format("%g hp x %g kJ per hp", show.hp, show.kjPerHP), "ACFLazersFusSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        _, lh = draw.SimpleText(string.format("%s kg, model scale %g", Commas(show.mass), show.scale), "ACFLazersFusSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        _, lh = draw.SimpleText(string.format("at 0%% health: %s kJ/s (x%g)", Commas(show.rateDamaged), show.efficiencyDamaged), "ACFLazersFusSmall", cx, y, ColHurt, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        draw.SimpleText(string.format("%g unit cap full in %s", show.capSize, Duration(show.fillSeconds)), "ACFLazersFusSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    end

    -- The toolgun's own screen. [KNOW] TOOL:DrawToolScreen(width, height) is called every frame on the client while this tool is held; the screen is a square (256 x 256).
    function TOOL:DrawToolScreen(w, h)
        local show = Readout()

        surface.SetDrawColor(ColBack)
        surface.DrawRect(0, 0, w, h)

        draw.SimpleText("FUSION ENGINE", "ACFLazersFusMid", w / 2, 10, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        DrawReadout(show, w, 44, show.name .. " makes")
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Fusion Engine Configuration", Description = "Pick the size before spawning." })

        -- The size drop-down. Picking a size sets the console variable the left-click reads.
        local startType = PickedType()
        local combo     = vgui.Create("DComboBox")

        combo:SetSortItems(false)

        for _, t in ipairs(ACFLazers.GetFusionTypes()) do
            combo:AddChoice(t.name, t.id, t.id == startType)
        end

        combo.OnSelect = function(_, _, _, id)
            RunConsoleCommand("acf_fusion_tool_type", ACFLazers.ClampFusionType(id))
        end

        panel:AddItem(combo)

        -- The big readout. [KNOW] DForm:AddItem(panel) puts a panel on its own full-width row; a DPanel with its own Paint draws whatever we tell it to.
        local box = vgui.Create("DPanel")

        box:SetTall(140)

        function box:Paint(w, h)
            draw.RoundedBox(8, 0, 0, w, h, ColBack)
            DrawReadout(Readout(), w, 6, "ENERGY MADE PER SECOND")
        end

        panel:AddItem(box)

        local info = panel:Help("")

        local function Refresh()
            local show = Readout()

            if IsValid(info) then
                info:SetText(string.format("A %s: model scale %g, mass %s kg. It makes the energy of a %g hp generator hub with nothing to feed it: %s kJ/s at full health, "
                    .. "less when damaged (down to x%g at 0%% health). The reference capacitor holds %s kJ. It needs no engine: only a capacitor.",
                    show.name, show.scale, Commas(show.mass), show.hp, Commas(show.rate), show.efficiencyDamaged, Commas(show.capacity)))
            end
        end

        cvars.AddChangeCallback("acf_fusion_tool_type", Refresh, "acf_fusion_tool_refresh")
        Refresh()

        panel:Help("Link the fusion engine to a capacitor with the right-click (the engine first, then the capacitor), and the capacitor to a lazer. The Draw wire input (0 to 100) sets how much of its power it makes.")
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

    -- The entity clamps this again server-side (VerifyData in the fusion engine's init.lua), so a stale ConVar is safe.
    local Data = {
        FusionType = ACFLazers.ClampFusionType(ply:GetInfo("acf_fusion_tool_type")),
    }

    -- Aiming at one of our fusion engines: change it to the picked size instead of spawning another
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

    return true
end
