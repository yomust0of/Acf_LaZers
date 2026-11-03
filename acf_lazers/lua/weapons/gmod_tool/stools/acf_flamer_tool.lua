-- =========================================================================
-- NEW FILE (22).  Goes to:  lua/weapons/gmod_tool/stools/acf_flamer_tool.lua
-- The FLAMETHROWER spawner. One slider (the flamethrower's size, 75 to 225 mm = model scale 0.5 to 1.5) and a readout of what that size gives.
--   Left-click            spawns a flamethrower, or updates the one you are aiming at.
--   Shift + left-click    spawns a NAPALM FUEL TANK (ACF's own scalable fuel tank, same models and same size sliders, filled with the new fuel "Napalm"), or updates the napalm tank you are
--                         aiming at (its size and shape; it keeps its fill percentage). A fuel tank that holds something else is never touched: it says so instead.
--   The tank's shape and size are on the same settings page, under the flamethrower's size.
--   Right-click, Shift + right-click and Reload (link / unlink) come from the shared link kit like every tool of this addon: link a napalm tank to the flamethrower.
-- Needs the 22 config (lua/autorun/acf_lazers_config.lua: the Flame... knobs and helpers), the 22 link kit, lua/acf/entities/fuel_types/napalm.lua and entities/acf_flamer.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Flamethrower Spawner"

local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_flamer_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.FlameNumber and ACFLazers.GetFlameReadout and ACFLazers.ClampFlameCaliber, "[acf_flamer_tool] lua/autorun/acf_lazers_config.lua is older than this tool (the flamethrower helpers are missing): copy the new config too")
assert(ACFLazers.LinkKit, "[acf_flamer_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")

local TankDefault = 24 -- gmu. ACF's own default for a size that is missing. [GUESS] a good first size for a napalm tank; the sliders go from ACF.ContainerMinSize to ACF.ContainerMaxSize

TOOL.ClientConVar["caliber"]  = ACFLazers.FlameNumber("FlameCaliberBase")
TOOL.ClientConVar["tankshape"] = "Box"
TOOL.ClientConVar["tankx"]    = TankDefault
TOOL.ClientConVar["tanky"]    = TankDefault
TOOL.ClientConVar["tankz"]    = TankDefault

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the help lines at the bottom-left of the screen: the shared link kit.
ACFLazers.LinkKit.Install(TOOL, "acf_flamer_tool", "Spawn a flamethrower with this size, or update the one you are aiming at")

-- The kit's help lines do not know about the Shift + left-click: add that line.
TOOL.Information = TOOL.Information or {}
TOOL.Information[#TOOL.Information + 1] = { name = "left_shift" }

local Shapes = { "Box", "Sphere", "Cylinder" } -- ACF's three tank shapes (ACF.ContainerShapeModels)

local function ShapeOK(shape)
    for _, name in ipairs(Shapes) do
        if name == shape then return shape end
    end

    return "Box"
end

--- Litres of napalm a tank of this shape and size holds. The very same sum ACF's tank does (acf_container CalcVolumeAndCapacity); nil when ACF's shape table is not there.
local function TankCapacity(shape, x, y, z)
    local calc = ACF and ACF.ContainerShapes and ACF.ContainerShapes[ShapeOK(shape)]

    if not calc or not ACF.ContainerArmor or not ACF.MmToInch or not ACF.gCmToKgIn then return nil end

    local volume = calc(Vector(x, y, z), ACF.ContainerArmor * ACF.MmToInch)

    return volume * ACF.gCmToKgIn
end

--- The three tank sizes, each squeezed into what ACF allows (ACF.ContainerMinSize .. ACF.ContainerMaxSize, 6 .. 96).
local function ClampTank(x, y, z)
    local lo = (ACF and ACF.ContainerMinSize) or 6
    local hi = (ACF and ACF.ContainerMaxSize) or 96

    local function c(v) return math.Clamp(math.Round(tonumber(v) or TankDefault), lo, hi) end

    return c(x), c(y), c(z)
end

if CLIENT then
    language.Add("tool.acf_flamer_tool", "ACF Flamethrower Spawner Tool")
    language.Add("tool.acf_flamer_tool.name", "ACF Flamethrower Spawner Tool")
    language.Add("tool.acf_flamer_tool.desc", "Spawns an ACF flamethrower (burns napalm from linked napalm fuel tanks), or updates the one you are aiming at. Hold Shift and left-click to spawn or update a napalm fuel tank instead. Also links engines, generators, capacitors, lazers, PPCs, radiators, flamethrowers and fuel tanks together.")
    language.Add("tool.acf_flamer_tool.left_shift", "(Hold Shift) Spawn a napalm fuel tank with the shape and size below, or update the napalm tank you are aiming at")

    -- The one line under the slider: what a flamethrower of this size is. All the numbers come from the config's helpers, the same ones the server uses.
    local function ReadoutText(caliber)
        local info = ACFLazers.GetFlameReadout(caliber)

        return string.format("A %g mm flamethrower (model scale %.2f): burns %.2f L of napalm per second (%.3f L per projectile, %g projectiles a second). Projectile speed %.0f m/s at the muzzle, %.0f m/s sideways after %g s (what the drag leaves; gravity pulls it down meanwhile). The flame sphere starts %g units across and ends %g. A hit sets things on fire for %.0f s and heats a part by %.1f%% of its HOT limit; over %g%% it takes %.1f health per hit. A person takes %.1f damage per hit. Mass %d kg.",
            caliber, info.scale, info.fuelRate, info.fuelPerShot, info.shots, info.speed, info.speedSideways, info.lifetime, info.sphereStart, info.sphereEnd, info.ignite, info.heatPct, info.damageAt, info.hp, info.playerDamage, math.floor(info.mass + 0.5))
    end

    local function TankText(caliber)
        local shape = ShapeOK(GetConVar("acf_flamer_tool_tankshape") and GetConVar("acf_flamer_tool_tankshape"):GetString())
        local x, y, z = ClampTank(GetConVar("acf_flamer_tool_tankx"):GetFloat(), GetConVar("acf_flamer_tool_tanky"):GetFloat(), GetConVar("acf_flamer_tool_tankz"):GetFloat())
        local litres = TankCapacity(shape, x, y, z)

        if not litres then return "" end

        local rate = ACFLazers.GetFlameFuelRate(caliber)
        local text = string.format("A %s napalm tank of %d x %d x %d holds %.1f L (%.1f gallons)", shape, x, y, z, litres, litres * (ACF.LToGal or 0.264172))

        if rate > 0 then
            text = text .. string.format(", enough for %.0f s of fire from the %g mm flamethrower above.", litres / rate, caliber)
        else
            text = text .. "."
        end

        return text
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Flamethrower Configuration", Description = "Pick the size before spawning. Hold Shift when you click to spawn a napalm fuel tank instead." })

        panel:AddControl("Slider", {
            Label = "Flamethrower size (mm)",
            Command = "acf_flamer_tool_caliber",
            Min = ACFLazers.FlameNumber("FlameCaliberMin"),
            Max = ACFLazers.FlameNumber("FlameCaliberMax"),
            Value = ACFLazers.FlameNumber("FlameCaliberBase")
        })

        local info = panel:Help("")

        -- The napalm tank settings: the same page, under the flamethrower's own.
        panel:Help("NAPALM FUEL TANK (Shift + left-click)")

        local combo = panel:ComboBox("Tank shape", "acf_flamer_tool_tankshape")

        for _, name in ipairs(Shapes) do
            combo:AddChoice(name, name)
        end

        local lo = (ACF and ACF.ContainerMinSize) or 6
        local hi = (ACF and ACF.ContainerMaxSize) or 96

        panel:AddControl("Slider", { Label = "Tank length (X)", Command = "acf_flamer_tool_tankx", Min = lo, Max = hi, Value = TankDefault })
        panel:AddControl("Slider", { Label = "Tank width (Y)",  Command = "acf_flamer_tool_tanky", Min = lo, Max = hi, Value = TankDefault })
        panel:AddControl("Slider", { Label = "Tank height (Z)", Command = "acf_flamer_tool_tankz", Min = lo, Max = hi, Value = TankDefault })

        local tank = panel:Help("")

        local function Refresh(caliber)
            if IsValid(info) then
                local convar = GetConVar("acf_flamer_tool_caliber")

                caliber = tonumber(caliber) or (convar and convar:GetFloat()) or ACFLazers.FlameNumber("FlameCaliberBase")
                caliber = ACFLazers.ClampFlameCaliber(caliber)

                info:SetText(ReadoutText(caliber))
            end

            if IsValid(tank) then
                local convar = GetConVar("acf_flamer_tool_caliber")
                local c = ACFLazers.ClampFlameCaliber((convar and convar:GetFloat()) or ACFLazers.FlameNumber("FlameCaliberBase"))

                tank:SetText(TankText(c))
            end
        end

        -- The same name every time the panel is built, so an old panel's callback is replaced instead of piling up.
        for _, name in ipairs({ "caliber", "tankshape", "tankx", "tanky", "tankz" }) do
            cvars.AddChangeCallback("acf_flamer_tool_" .. name, function() Refresh() end, "acf_flamer_tool_readout")
        end

        Refresh()
        timer.Simple(0, Refresh) -- once more after the sliders have read their saved values

        panel:Help("Link a napalm tank to the flamethrower with the right-click link controls of this tool (or any tool of this addon). The flamethrower burns napalm only; ACF engines cannot use a napalm tank. Fire it with the Fire wire input.")
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

local function Freeze(ent)
    local phys = ent:GetPhysicsObject()

    if IsValid(phys) then
        phys:EnableMotion(false)
    end
end

-- ===================== Shift + left click: the napalm tank =====================

local function NapalmTank(tool, trace)
    local ply      = tool:GetOwner()
    local Entities = ACF.Classes.Entities

    -- ACF quietly turns a fuel type it does not know into petrol; that must never happen here, so look first.
    if not ACF.Classes.FuelTypes.Get(ACFLazers.FlameFuelID) then
        Say(ply, "Error", "Napalm is not a registered fuel type: lua/acf/entities/fuel_types/napalm.lua is missing (copy it to the game, the git folder and the server, then restart).")

        return false
    end

    local x, y, z = ClampTank(ply:GetInfoNum("acf_flamer_tool_tankx", TankDefault), ply:GetInfoNum("acf_flamer_tool_tanky", TankDefault), ply:GetInfoNum("acf_flamer_tool_tankz", TankDefault))

    local Data = {
        FuelType  = ACFLazers.FlameFuelID,
        FuelShape = ShapeOK(ply:GetInfo("acf_flamer_tool_tankshape")),
        FuelSizeX = x,
        FuelSizeY = y,
        FuelSizeZ = z,
    }

    -- Aiming at a fuel tank: update it if it holds napalm, leave it alone if it holds anything else
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_fueltank" then
        if hit.FuelType ~= ACFLazers.FlameFuelID then
            Say(ply, "Error", "That fuel tank holds " .. tostring(hit.FuelType) .. ", not napalm: this tool only changes napalm tanks (nothing was changed).")

            return false
        end

        if not MayTouch(tool, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that fuel tank.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in ACF's fuel tank module

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn: its up (+Z) along the surface we aimed at, its middle half its height (plus 1 unit) above the spot. [GUESS] that ACF's tank models are centred on their origin
    local spawnPos = trace.HitPos + (trace.HitNormal * (z / 2 + 1))

    local angles = trace.HitNormal:Angle()
    angles:RotateAroundAxis(angles:Right(), -90)

    local ok, result = Entities.Spawn("acf_fueltank", ply, spawnPos, angles, Data) -- calls ACF.MakeFuelTank

    if not ok then
        Say(ply, "Error", "Couldn't create the napalm tank: " .. tostring(result))

        return false
    end

    if result.FuelType ~= ACFLazers.FlameFuelID then
        Say(ply, "Error", "The new tank came out as " .. tostring(result.FuelType) .. " instead of napalm: it was removed.")
        result:Remove()

        return false
    end

    Freeze(result)

    return true
end

-- ===================== left click: spawn / update =====================

function TOOL:LeftClick(trace)
    if trace.HitSky then return false end
    if CLIENT then return true end

    local ply = self:GetOwner()

    if ply:KeyDown(IN_SPEED) then return NapalmTank(self, trace) end

    local Entities = ACF.Classes.Entities

    -- The entity clamps this again server-side (VerifyData in init.lua); the note is only so the player knows.
    local Data = {
        Caliber = ply:GetInfoNum("acf_flamer_tool_caliber", ACFLazers.FlameNumber("FlameCaliberBase")),
    }

    local clamped = ACFLazers.ClampFlameCaliber(Data.Caliber)

    if math.abs(clamped - Data.Caliber) > 0.001 then
        Say(ply, "Info", string.format("Size limited to %g mm (a flamethrower goes from %g to %g mm).", clamped, ACFLazers.FlameNumber("FlameCaliberMin"), ACFLazers.FlameNumber("FlameCaliberMax")))
    end

    -- Aiming at one of our flamethrowers: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_flamer" then
        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that flamethrower.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in init.lua

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn standing on the surface we aimed at (like the PPC: the model's up is turned along the surface normal)
    local spawnPos = trace.HitPos + (trace.HitNormal * 24)

    local angles = trace.HitNormal:Angle()
    angles:RotateAroundAxis(angles:Right(), -90)

    local ok, result = Entities.Spawn("acf_flamer", ply, spawnPos, angles, Data) -- calls MakeACFFlamer in init.lua

    if not ok then
        Say(ply, "Error", "Couldn't create the flamethrower: " .. tostring(result))

        return false
    end

    Freeze(result)

    return true
end
