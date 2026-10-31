-- =========================================================================
-- NEW (16.6). Goes to:  lua/weapons/gmod_tool/stools/acf_heat_tool.lua      (a NEW file: game folder and server)
--
-- THE HEAT CHECKER. A tool that shows where the heat is, so nobody has to guess.
--   While it is out, look at ANY part within HeatCheckDistance units (a plain prop, a lazer, a PPC, a radiator ...). Next to the crosshair:
--       class, mass
--       temperature, and what share of the HOT temperature that is (a plate is burned through at 100%); for a lazer, a PPC or a capacitor also the share of ITS OWN limit
--       the heat it holds (kJ above room temperature), and how much of it it loses BY ITSELF in the next second
--       how much the RADIATORS took out of it in their last sweep (kJ per second), and what the whole pool took
--   Left-click        lists where the heat is around the spot you aim at (the radius is the slider; any spot, a part or the sky): the summary goes to chat, the list to your CONSOLE (press ~). It says
--                     how many parts hold heat and how much, the machines (lazers, PPCs, capacitors) against everything else, the hottest parts, and the share of a radiator's work the machines would get.
--   The same list without the tool:  acf_lazers_heat_scan [radius]   (console).
-- The tool changes nothing: it only reads the heat (acf_lazers_heat.lua: Heat.Describe, Heat.ScanPrint).
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Heat Checker"

-- Same shared table the entities use. Autorun files load before tools, so it exists by now.
local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_heat_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.HeatCheckNumber and ACFLazers.ClampHeatCheckRadius and ACFLazers.HeatScanSummary, "[acf_heat_tool] lua/autorun/acf_lazers_config.lua is older than this file (it has no heat checker helpers). Copy the config of the same batch (16.6).")

TOOL.ClientConVar["radius"]  = ACFLazers.HeatCheckNumber("HeatCheckRadius")
TOOL.ClientConVar["celsius"] = 0

if CLIENT then
    language.Add("tool.acf_heat_tool.name", "ACF Heat Checker")
    language.Add("tool.acf_heat_tool.desc", "Look at any part to read its heat. Left-click lists where the heat is around the spot you aim at.")
    language.Add("tool.acf_heat_tool.0", "Left-click: list the heat around the spot you aim at (the list goes to your console).")

    surface.CreateFont("ACFLazersHeatBig",   { font = "Arial", size = 18, weight = 700 })
    surface.CreateFont("ACFLazersHeatSmall", { font = "Arial", size = 15, weight = 600 })

    local ColWhite = Color(235, 235, 235)
    local ColAmber = Color(255, 190, 40)
    local ColHurt  = Color(255, 90, 70)
    local ColGrey  = Color(160, 165, 175)
    local ColCool  = Color(120, 220, 160)

    local function Commas(n)
        local digits = string.format("%d", math.floor((tonumber(n) or 0) + 0.5))
        local out    = ""

        while #digits > 3 do
            out    = "," .. string.sub(digits, -3) .. out
            digits = string.sub(digits, 1, -4)
        end

        return digits .. out
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Heat Checker", Description = "Look at any part to read its heat. Left-click lists where the heat is around the spot you aim at." })

        panel:NumSlider("Scan radius (units)", "acf_heat_tool_radius", 50, ACFLazers.HeatCheckNumber("HeatCheckRadiusMax"), 0)

        panel:AddControl("Checkbox", {
            Label = "Show the temperature of what I look at in Celsius",
            Command = "acf_heat_tool_celsius"
        })

        panel:Help("Next to the crosshair: the part's class and mass, its temperature, the heat it holds, how much it loses by itself per second and how much the radiators take out of it. The scan (left-click) lists the hottest parts around the spot you aim at in your console, and the share of a radiator's work the lazers, PPCs and capacitors would get. The same list: the console command acf_lazers_heat_scan.")
    end

    -- ===================== the readout of what you look at =====================
    -- The server answers a question about one entity at a time (acf_lazers_heat.lua, ACFLazers_HeatCheckQuery). This asks at most every HeatCheckQueryInterval seconds.
    local Reading = {}
    local AskedAt = 0

    net.Receive("ACFLazers_HeatCheckReply", function()
        Reading = {
            ent = net.ReadEntity(), time = CurTime(), class = net.ReadString(), mass = net.ReadFloat(), capacity = net.ReadFloat(), kJ = net.ReadFloat(), degF = net.ReadFloat(),
            pct = net.ReadFloat(), own = net.ReadFloat(), natural = net.ReadFloat(), rad = net.ReadFloat(), pool = net.ReadFloat(),
        }
    end)

    hook.Add("HUDPaint", "ACFLazers_HeatCheckReadout", function()
        local ply = LocalPlayer()

        if not IsValid(ply) or ply:InVehicle() then return end

        local weapon = ply:GetActiveWeapon()

        -- [KNOW] the toolgun's weapon table has GetMode(): the name of the tool that is selected
        if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" or weapon:GetMode() ~= "acf_heat_tool" then return end

        local from = ply:EyePos()
        local tr   = util.TraceLine({ start = from, endpos = from + ply:GetAimVector() * ACFLazers.HeatCheckNumber("HeatCheckDistance"), filter = ply })
        local ent  = tr.Entity

        if not (tr.Hit and not tr.HitWorld and IsValid(ent) and not ent:IsPlayer()) then return end

        local now      = CurTime()
        local interval = math.max(ACFLazers.HeatCheckNumber("HeatCheckQueryInterval"), 0.05)

        if (Reading.ent ~= ent or now - (Reading.time or 0) >= interval) and now - AskedAt >= interval then
            AskedAt = now

            net.Start("ACFLazers_HeatCheckQuery")
            net.WriteEntity(ent)
            net.SendToServer()
        end

        local x, y = ScrW() / 2 + 28, ScrH() / 2 + 20

        if Reading.ent ~= ent or now - (Reading.time or 0) > 2 then
            draw.SimpleText("...", "ACFLazersHeatBig", x, y, ColGrey, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)

            return
        end

        local celsius = GetConVar("acf_heat_tool_celsius")
        local degrees, unit = Reading.degF, "F"

        if celsius and celsius:GetBool() then degrees, unit = (Reading.degF - 32) * 5 / 9, "C" end

        local color = Reading.pct >= 1 and ColHurt or (Reading.pct >= 0.5 and ColAmber or ColWhite)
        local head  = string.format("%d %s  (%d%% of HOT)", math.floor(degrees + 0.5), unit, math.floor(Reading.pct * 100 + 0.5))

        if Reading.own >= 0 then head = head .. string.format("  |  %d%% of its own limit", math.floor(Reading.own * 100 + 0.5)) end

        local _, lh = draw.SimpleText(head, "ACFLazersHeatBig", x, y, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        local row   = y + lh + 1

        draw.SimpleText(string.format("%s, %s kg", Reading.class, Commas(Reading.mass)), "ACFLazersHeatSmall", x, row, ColGrey, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        row = row + 16
        draw.SimpleText(string.format("%s kJ above room temperature, loses %s kJ/s by itself", Commas(Reading.kJ), Commas(Reading.natural)), "ACFLazersHeatSmall", x, row, ColGrey, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        row = row + 16

        if Reading.rad > 0 then
            draw.SimpleText(string.format("radiators take %s kJ/s out of it (their pool: %s kJ/s)", Commas(Reading.rad), Commas(Reading.pool)), "ACFLazersHeatSmall", x, row, ColCool, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText("no radiator is taking heat out of it", "ACFLazersHeatSmall", x, row, ColGrey, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
    end)
end

-- Left-click: list the heat around the spot you aim at.
function TOOL:LeftClick(trace)
    if CLIENT then return true end

    local ply  = self:GetOwner()
    local Heat = ACFLazers.Heat

    if not (Heat and Heat.ScanPrint) then
        if IsValid(ply) then ply:ChatPrint("[heat checker] the heat system is not loaded (lua/autorun/acf_lazers_heat.lua is missing or older than this tool).") end

        return true
    end

    local radius = ACFLazers.ClampHeatCheckRadius(ply:GetInfoNum("acf_heat_tool_radius", ACFLazers.HeatCheckNumber("HeatCheckRadius")))
    local pos    = (trace and trace.HitPos) or ply:GetPos()

    Heat.ScanPrint(ply, pos, radius)

    return true
end

function TOOL:RightClick() return false end

function TOOL:Reload() return false end
