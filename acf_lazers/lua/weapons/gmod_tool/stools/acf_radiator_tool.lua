-- =========================================================================
-- NEW (15.2), CHANGED (15.3, 15.4). Goes to:  lua/weapons/gmod_tool/stools/acf_radiator_tool.lua
--
-- THE RADIATOR TOOL (based on the generator tool).
--   Left-click        spawn a radiator with the slider's width and the colour of the coolant (the colour picker), or update the radiator you are aiming at. The width sets the model scale,
--                     the mass, the radius it reaches, how much heat it can take out per second and the size of its coolant tank (RadWidthMin..RadWidthMax and the Rad... knobs in the config)
--   Right-click       LINK (from the link kit, lua/autorun/acf_lazers_linkkit.lua). Click the first thing: it turns green. Then click what to link it to. Radiators linked to each
--                     other are ONE POOL: one member list, the sum of their sap rates.
--   Shift + right-click   add one more thing to the selection, or take a selected thing off it. Then a plain right-click links ALL selected things to the one you aim at.
--   Reload            UNLINK. With things selected, aim at the one to unlink them from. With nothing selected, it breaks every link of the thing you aim at.
--   Right-click on nothing, or putting the tool away, clears the selection.
-- While the toolgun is out (any tool) and you aim at a radiator, the sphere of its radius is drawn around it (the radiator's cl_init.lua).
-- While THIS tool is out, look at any part within RadReadoutDistance units: its temperature is shown next to the crosshair (plain props have no hover text of their own).
-- All the numbers on the screen come from ACFLazers.GetRadReadout in the config, so the tool cannot disagree with the radiator.
-- (15.3) The coolant colour is the colour of the steam a radiator vents when its Flush wire input is on. The readout also shows the size of the tank and how fast a flush empties it.
-- (15.4) No overclock any more: the readout shows what the radiator takes out and where its own heat settles when it works flat out.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Radiator Spawner"

-- Same shared table the entities use. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_radiator_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.LinkKit, "[acf_radiator_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")
assert(ACFLazers.GetRadReadout, "[acf_radiator_tool] lua/autorun/acf_lazers_config.lua is older than this file (it has no radiator helpers). Copy the config of the same batch (15.4).")
assert(ACFLazers.GetRadCoolantCapacity, "[acf_radiator_tool] lua/autorun/acf_lazers_config.lua is older than this file (it has no coolant helpers). Copy the config of the same batch (15.4).")

TOOL.ClientConVar["width"]   = Config.RadWidthDefault
TOOL.ClientConVar["celsius"] = 0

-- [CHANGED 1] the colour of the coolant (the steam of a flush): the config's default until the player picks another
do
    local r, g, b = ACFLazers.ClampRadColor(nil, nil, nil)

    TOOL.ClientConVar["coolantr"] = r
    TOOL.ClientConVar["coolantg"] = g
    TOOL.ClientConVar["coolantb"] = b
end

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the little help lines at the bottom-left of the screen.
ACFLazers.LinkKit.Install(TOOL, "acf_radiator_tool", "Spawn a radiator this wide, or update the one you are aiming at")

if CLIENT then
    language.Add("tool.acf_radiator_tool.name", "ACF Radiator Tool")
    language.Add("tool.acf_radiator_tool.desc", "Spawns radiators (they take heat out of the parts around them) and links radiators into pools. Look at any part to read its temperature.")

    -- Fonts for the readouts. [KNOW] surface.CreateFont(name, table) is client-only; a font family the computer does not have falls back to a default one.
    surface.CreateFont("ACFLazersRadBig",   { font = "Arial", size = 42, weight = 900 })
    surface.CreateFont("ACFLazersRadMid",   { font = "Arial", size = 20, weight = 700 })
    surface.CreateFont("ACFLazersRadSmall", { font = "Arial", size = 15, weight = 600 })
    surface.CreateFont("ACFLazersRadHUD",   { font = "Arial", size = 18, weight = 700 })

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

    -- The colour picked for the coolant (read from the ConVars every time: three numbers, cheap).
    local function CoolantColor()
        local r, g, b = ACFLazers.ClampRadColor(GetConVar("acf_radiator_tool_coolantr") and GetConVar("acf_radiator_tool_coolantr"):GetInt(),
                                                GetConVar("acf_radiator_tool_coolantg") and GetConVar("acf_radiator_tool_coolantg"):GetInt(),
                                                GetConVar("acf_radiator_tool_coolantb") and GetConVar("acf_radiator_tool_coolantb"):GetInt())

        return Color(r, g, b)
    end

    -- Only works the numbers out again when the slider moved (the screen is drawn every frame).
    local cachedWidth, cachedShow

    local function Readout()
        local convar = GetConVar("acf_radiator_tool_width")
        local width  = ACFLazers.ClampRadWidth(convar and convar:GetFloat() or Config.RadWidthDefault)

        if cachedWidth ~= width then
            cachedWidth = width
            cachedShow  = ACFLazers.GetRadReadout(width)
        end

        return cachedShow
    end

    -- A big number with its unit after it, centred on cx. Returns the height used.
    local function BigNumber(value, unit, cx, y, color)
        local text = Commas(value)

        surface.SetFont("ACFLazersRadBig")
        local tw, th = surface.GetTextSize(text)

        surface.SetFont("ACFLazersRadMid")
        local uw, uh = surface.GetTextSize(unit)

        local gap = 6
        local x   = cx - (tw + gap + uw) / 2

        draw.SimpleText(text, "ACFLazersRadBig", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        draw.SimpleText(unit, "ACFLazersRadMid", x + tw + gap, y + th - uh - 3, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        return th
    end

    -- Draws the readout block (used by the menu panel and by the toolgun screen). `show` is ACFLazers.GetRadReadout's table.
    local function DrawReadout(show, w, top, heading)
        local cx = w / 2
        local _, lh = draw.SimpleText(heading, "ACFLazersRadSmall", cx, top, ColGrey, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        local y = top + lh + 2

        y = y + BigNumber(show.sap, "kJ/s", cx, y, ColAmber) + 2

        _, lh = draw.SimpleText(string.format("%d units wide, %d kg, radius %d", show.width, show.mass, math.floor(show.radius + 0.5)), "ACFLazersRadSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        _, lh = draw.SimpleText(string.format("working flat out its own heat settles at %d%% of HOT", math.floor(show.settle * 100 + 0.5)), "ACFLazersRadSmall", cx, y, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        y = y + lh + 1

        if show.eff < 0.999 then
            _, lh = draw.SimpleText(string.format("there it works at %d%% efficiency: %s kJ/s", math.floor(show.eff * 100 + 0.5), Commas(show.net)), "ACFLazersRadSmall", cx, y, ColAmber, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
            y = y + lh + 1
        end

        if show.liters and show.liters > 0 then
            -- [CHANGED 1] the tank, in the colour of its steam
            local tank = show.liters >= 10 and string.format("coolant tank %d L", math.floor(show.liters + 0.5)) or string.format("coolant tank %.1f L", show.liters)

            _, lh = draw.SimpleText(tank, "ACFLazersRadSmall", cx, y, CoolantColor(), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
            y = y + lh + 1

            _, lh = draw.SimpleText(string.format("flush: %.1f L/s, %s kJ/s extra", show.flushRate, Commas(show.flushKJ)), "ACFLazersRadSmall", cx, y, ColGrey, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
            y = y + lh
        end

        return y
    end

    -- The toolgun's own screen. [KNOW] TOOL:DrawToolScreen(width, height) is called every frame on the client while this tool is held; the screen is a square (256 x 256).
    function TOOL:DrawToolScreen(w, h)
        local show = Readout()

        surface.SetDrawColor(ColBack)
        surface.DrawRect(0, 0, w, h)

        draw.SimpleText("RADIATOR", "ACFLazersRadMid", w / 2, 10, ColWhite, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        DrawReadout(show, w, 44, "takes out up to")
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Radiator Configuration", Description = "Tune settings before spawning." })

        -- The width is also the size: the model is scaled by it, and the mass, radius and sap rate follow (the Rad... knobs in the config).
        panel:NumSlider("Width (units)", "acf_radiator_tool_width", Config.RadWidthMin, Config.RadWidthMax, 0)

        local box = vgui.Create("DPanel")

        box:SetTall(200)

        function box:Paint(w, h)
            draw.RoundedBox(8, 0, 0, w, h, ColBack)
            DrawReadout(Readout(), w, 6, "HEAT TAKEN OUT PER SECOND")
        end

        panel:AddItem(box)

        -- [CHANGED 1] [KNOW] the "Color" control is a colour mixer bound to three ConVars (Red / Green / Blue)
        panel:AddControl("Color", {
            Label     = "Coolant (steam) colour",
            Red       = "acf_radiator_tool_coolantr",
            Green     = "acf_radiator_tool_coolantg",
            Blue      = "acf_radiator_tool_coolantb",
            ShowAlpha = 0,
            ShowHSV   = 1,
            ShowRGB   = 1,
            Multiplier = 255
        })

        local info = panel:Help("")

        local function Refresh()
            local show = Readout()

            if IsValid(info) then
                info:SetText(string.format("A radiator %d units wide: model scale %.2f, mass %d kg, radius %d units. It takes up to %s kJ/s out of the hot parts of its own contraption that are inside its radius, "
                    .. "the hottest parts giving the most. Working makes waste heat (%.1f%% of the work it tries to do); from %d%% of HOT its efficiency falls to %d%% at 100%%. It never damages itself from heat, "
                    .. "and it sheds its own heat %g times as fast as a prop. Working flat out its own heat settles at %d%% of HOT.\n\n"
                    .. "Coolant: the tank holds %.1f litres. A full tank is full strength, an empty one works at %d%%. The Flush wire input vents %.1f litres a second as a cloud of steam in the colour above "
                    .. "and takes %s kJ/s of heat out of the hot parts on top. A supply crate refills the tank like a fuel tank.",
                    show.width, show.scale, show.mass, math.floor(show.radius + 0.5), Commas(show.sap), show.wasteFrac * 100, Config.RadEffStartPct, Config.RadEffFloorPct, Config.HeatCoolMultRad,
                    math.floor(show.settle * 100 + 0.5), show.liters, math.floor(ACFLazers.GetRadCoolantMult(0) * 100 + 0.5), show.flushRate, Commas(show.flushKJ)))
            end
        end

        cvars.AddChangeCallback("acf_radiator_tool_width", Refresh, "acf_radiator_tool_refresh")
        Refresh()

        panel:AddControl("Checkbox", {
            Label = "Show the temperature of what I look at in Celsius (this tool's readout only)",
            Command = "acf_radiator_tool_celsius"
        })

        panel:Help("Link radiators to each other with the right-click (first one, then the other): linked radiators are one pool that shares its members and adds up its rates. The radiator must be constrained to what it should cool. Aim at a radiator with any tool to see its radius.")
    end

    -- ===================== the temperature of what you look at =====================
    -- The server answers a question about one entity at a time (acf_lazers_heat.lua, ACFLazers_HeatQuery). This asks at most every RadReadoutInterval seconds.
    local Reading = {}       -- the last answer: ent, time, kJ, degrees F, percent of HOT (a fraction), mass
    local AskedAt = 0

    net.Receive("ACFLazers_HeatReply", function()
        Reading = { ent = net.ReadEntity(), time = CurTime(), kJ = net.ReadFloat(), degF = net.ReadFloat(), pct = net.ReadFloat(), mass = net.ReadFloat() }
    end)

    hook.Add("HUDPaint", "ACFLazers_RadiatorReadout", function()
        local ply = LocalPlayer()

        if not IsValid(ply) or ply:InVehicle() then return end

        local weapon = ply:GetActiveWeapon()

        -- [KNOW] the toolgun's weapon table has GetMode(): the name of the tool that is selected
        if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or weapon:GetMode() ~= "acf_radiator_tool" then return end

        local from = ply:EyePos()
        local tr   = util.TraceLine({ start = from, endpos = from + ply:GetAimVector() * Config.RadReadoutDistance, filter = ply })
        local ent  = tr.Entity

        if not (tr.Hit and not tr.HitWorld and IsValid(ent) and not ent:IsPlayer()) then return end

        local now = CurTime()

        if (Reading.ent ~= ent or now - (Reading.time or 0) >= Config.RadReadoutInterval) and now - AskedAt >= Config.RadReadoutInterval then
            AskedAt = now

            net.Start("ACFLazers_HeatQuery")
            net.WriteEntity(ent)
            net.SendToServer()
        end

        local x, y = ScrW() / 2 + 28, ScrH() / 2 + 20

        if Reading.ent ~= ent or now - (Reading.time or 0) > 2 then
            draw.SimpleText("...", "ACFLazersRadHUD", x, y, ColGrey, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

            return
        end

        local celsius = GetConVar("acf_radiator_tool_celsius")
        local degrees, unit = Reading.degF, "F"

        if celsius and celsius:GetBool() then degrees, unit = (Reading.degF - 32) * 5 / 9, "C" end

        local color = Reading.pct >= 1 and ColHurt or (Reading.pct >= 0.5 and ColAmber or ColWhite)
        local _, lh = draw.SimpleText(string.format("%d %s  (%d%% of HOT)", math.floor(degrees + 0.5), unit, math.floor(Reading.pct * 100 + 0.5)), "ACFLazersRadHUD", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

        draw.SimpleText(string.format("%s kJ above room temperature, %d kg", Commas(Reading.kJ), math.floor(Reading.mass + 0.5)), "ACFLazersRadSmall", x, y + lh + 1, ColGrey, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end)
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

    -- The entity clamps this again server-side (VerifyData in the radiator's init.lua), so a stale ConVar is safe.
    local Data = {
        Width    = ply:GetInfoNum("acf_radiator_tool_width", Config.RadWidthDefault),
        CoolantR = ply:GetInfoNum("acf_radiator_tool_coolantr", Config.RadCoolantColor[1]), -- [CHANGED 1] the entity clamps all three again (VerifyData)
        CoolantG = ply:GetInfoNum("acf_radiator_tool_coolantg", Config.RadCoolantColor[2]),
        CoolantB = ply:GetInfoNum("acf_radiator_tool_coolantb", Config.RadCoolantColor[3]),
    }

    -- Tell the player when the server will squeeze the width into the allowed range.
    if Data.Width < Config.RadWidthMin or Data.Width > Config.RadWidthMax then
        Say(ply, "Info", string.format("Width limited to %d units (the allowed range is %d to %d units).", ACFLazers.ClampRadWidth(Data.Width), Config.RadWidthMin, Config.RadWidthMax))
    end

    -- Aiming at one of our radiators: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_radiator" then
        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that radiator.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in the radiator's init.lua

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn standing on the surface we aimed at (the usual Wiremod trick: the surface normal's angle, pitched 90 degrees). [GUESS] that the model's up is +Z.
    local angles = trace.HitNormal:Angle()
    angles.pitch = angles.pitch + 90

    local ok, result = Entities.Spawn("acf_radiator", ply, trace.HitPos, angles, Data) -- calls MakeACFRadiator in the radiator's init.lua

    if not ok then
        Say(ply, "Error", "Couldn't create the radiator: " .. tostring(result))

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
