-- =========================================================================
-- NEW FILE (23, changed in 23.1 and 23.3).  Goes to:  lua/weapons/gmod_tool/stools/acf_gauss_tool.lua
-- The GAUSS RIFLE spawner. One slider (the rifle's size, 30 to 300 mm = model scale 0.3 to 3) and a readout of what that size gives. (23.3: no tracer switch any more: the DART's tracer is always on.)
--   Left-click            spawns a gauss rifle, or updates the one you are aiming at (its size).
--   Shift + left-click    spawns an INERT AMMO BOX (ACF's own scalable ammo crate, same models and the same size sliders as the napalm tank of the flamethrower tool, holding the DART, the rifle's one ammo
--                         type: a box of darts never cooks off and never explodes), or updates the DART box you are aiming at (its size, and its caliber: the box takes the rifle size set above, and an update
--                         unlinks the rifles that no longer fit). An ammo crate that holds anything else is never touched: it says so instead.
--   The box's size is on the same settings page, under the rifle's. ACF fits whole rounds in a box, so a box can come out bigger than the sliders (a round of a big rifle is longer than the default box).
--   Right-click, Shift + right-click and Reload (link / unlink) come from the shared link kit like every tool of this addon: link an inert box to the rifle.
-- Needs the 23.3 config (lua/autorun/acf_lazers_config.lua: the Gauss... knobs and helpers), the 23 link kit, the weapon class and the ammo type of the rifle (lua/acf/entities/weapons/lazers_gauss.lua and
-- lua/acf/entities/ammo_types/lazers_dart.lua) and entities/acf_gauss.
-- =========================================================================

TOOL.Category = "ACF - LaZers"
TOOL.Name = "Gauss Rifle Spawner"

local Config = ACFLazers and ACFLazers.Config
assert(Config, "[acf_gauss_tool] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.GaussNumber and ACFLazers.GetGaussReadout and ACFLazers.ClampGaussCaliber and ACFLazers.GetGaussToolData, "[acf_gauss_tool] lua/autorun/acf_lazers_config.lua is older than this tool (the gauss rifle helpers are missing): copy the new config too")
assert(ACFLazers.LinkKit, "[acf_gauss_tool] lua/autorun/acf_lazers_linkkit.lua is missing or did not load")

local BoxDefault = 24 -- gmu. ACF's own default for a size that is missing. [GUESS] a good first size for an ammo box; the sliders go from ACF.AmmoMinSize to ACF.AmmoMaxLength / AmmoMaxWidth

TOOL.ClientConVar["caliber"] = ACFLazers.GaussNumber("GaussCaliberBase")
TOOL.ClientConVar["boxx"]    = BoxDefault
TOOL.ClientConVar["boxy"]    = BoxDefault
TOOL.ClientConVar["boxz"]    = BoxDefault

-- Right-click (select / link), Shift + right-click, Reload (unlink), Holster, and the help lines at the bottom-left of the screen: the shared link kit.
ACFLazers.LinkKit.Install(TOOL, "acf_gauss_tool", "Spawn a gauss rifle with this size, or update the one you are aiming at")

-- The kit's help lines do not know about the Shift + left-click: add that line.
TOOL.Information = TOOL.Information or {}
TOOL.Information[#TOOL.Information + 1] = { name = "left_shift" }

--- The three box sizes, each squeezed into what ACF allows for an ammo crate (ACF.AmmoMinSize .. ACF.AmmoMaxLength for the length, .. ACF.AmmoMaxWidth for the others; 6, 192 and 96).
local function ClampBox(x, y, z)
    local lo   = (ACF and ACF.AmmoMinSize) or 6
    local long = (ACF and ACF.AmmoMaxLength) or 192
    local wide = (ACF and ACF.AmmoMaxWidth) or 96

    local function c(v, hi) return math.Clamp(math.Round(tonumber(v) or BoxDefault), lo, hi) end

    return c(x, long), c(y, wide), c(z, wide)
end

if CLIENT then
    language.Add("tool.acf_gauss_tool", "ACF Gauss Rifle Spawner Tool")
    language.Add("tool.acf_gauss_tool.name", "ACF Gauss Rifle Spawner Tool")
    language.Add("tool.acf_gauss_tool.desc", "Spawns an ACF gauss rifle (fires DART rounds from linked inert ammo boxes), or updates the one you are aiming at. Hold Shift and left-click to spawn or update an inert ammo box instead. Also links gauss rifles to ammo boxes, and the other things of this addon (right-click, Shift + right-click and Reload).")
    language.Add("tool.acf_gauss_tool.left_shift", "(Hold Shift) Spawn an inert ammo box with the size below (and the rifle size above as its caliber), or update the inert box you are aiming at")

    -- Whole rounds ACF fits in a box of this size (about: the server also holds a box to ACF's maximum). nil when ACF's numbers are not there.
    local function BoxRounds(caliber, x, y, z)
        local Namespace = ACF and ACF.Classes and ACF.Classes[ACFLazers.GaussRegistry]
        local Class     = Namespace and Namespace.Get and Namespace.Get(ACFLazers.GaussClassID)

        if not (Class and ACF.GetProjectileCountsFromCrateSize) then return nil end

        local Ok, cx, cy, cz = pcall(ACF.GetProjectileCountsFromCrateSize, Vector(x, y, z), Class,
            { Weapon = ACFLazers.GaussClassID, Destiny = ACFLazers.GaussRegistry, Caliber = caliber },
            { PropLength = 0, ProjLength = ACFLazers.GetGaussDartLengthCm(caliber) })

        if not Ok or not (tonumber(cx) and tonumber(cy) and tonumber(cz)) then return nil end

        return cx * cy * cz, cx, cy, cz
    end

    -- The one line under the slider: what a rifle of this size is. All the numbers come from the config's helpers, the same ones the server uses.
    local function ReadoutText(caliber)
        local info = ACFLazers.GetGaussReadout(caliber)
        local pen  = info.penetration and string.format(" It goes through about %.0f mm of steel at the muzzle.", info.penetration) or ""
        local power = Config.RequireCapacitor and string.format(" A shot takes %.0f kJ from the capacitors linked to the rifle.", info.shotKJ) or " Shots are free (RequireCapacitor is off in the config)."

        return string.format("A %g mm gauss rifle (model scale %.2f, %d kg): muzzle velocity %.0f m/s, one shot every %.2f s. The DART is %.0f cm long, %.0f mm wide and weighs %.1f kg, carries %.0f kJ.%s It flies straight (no drop) for %g s (%.1f km).%s",
            caliber, info.scale, math.floor(info.mass + 0.5), info.speed, info.refire, info.dartLength, info.dartWidth * 10, info.dartMass, info.energy, pen, info.lifetime, info.range / 1000, power)
    end

    local function BoxText(caliber)
        local x, y, z = ClampBox(GetConVar("acf_gauss_tool_boxx"):GetFloat(), GetConVar("acf_gauss_tool_boxy"):GetFloat(), GetConVar("acf_gauss_tool_boxz"):GetFloat())
        local rounds, cx, cy, cz = BoxRounds(caliber, x, y, z)

        if not rounds then return "" end

        return string.format("An inert box of %d x %d x %d holds about %d rounds of %g mm (%d x %d x %d), %.0f shots at %d round(s) a shot. Rounds of this size are %.0f cm long: a box shorter than that grows to fit one.",
            x, y, z, rounds, caliber, cx, cy, cz, rounds / ACFLazers.GetGaussReadout(caliber).rounds, ACFLazers.GetGaussReadout(caliber).rounds, ACFLazers.GetGaussDartLengthCm(caliber))
    end

    function TOOL.BuildCPanel(panel)
        panel:AddControl("Header", { Text = "ACF Gauss Rifle Configuration", Description = "Pick the size before spawning. Hold Shift when you click to spawn an inert ammo box instead." })

        panel:AddControl("Slider", {
            Label = "Gauss rifle size (mm)",
            Command = "acf_gauss_tool_caliber",
            Min = ACFLazers.GaussNumber("GaussCaliberMin"),
            Max = ACFLazers.GaussNumber("GaussCaliberMax"),
            Value = ACFLazers.GaussNumber("GaussCaliberBase")
        })

        local info = panel:Help("")

        -- The inert ammo box settings: the same page, under the rifle's own.
        panel:Help("INERT AMMO BOX (Shift + left-click)")

        local lo   = (ACF and ACF.AmmoMinSize) or 6
        local long = (ACF and ACF.AmmoMaxLength) or 192
        local wide = (ACF and ACF.AmmoMaxWidth) or 96

        panel:AddControl("Slider", { Label = "Box length (X)", Command = "acf_gauss_tool_boxx", Min = lo, Max = long, Value = BoxDefault })
        panel:AddControl("Slider", { Label = "Box width (Y)",  Command = "acf_gauss_tool_boxy", Min = lo, Max = wide, Value = BoxDefault })
        panel:AddControl("Slider", { Label = "Box height (Z)", Command = "acf_gauss_tool_boxz", Min = lo, Max = wide, Value = BoxDefault })

        local box = panel:Help("")

        local function Refresh(caliber)
            local convar = GetConVar("acf_gauss_tool_caliber")

            caliber = tonumber(caliber) or (convar and convar:GetFloat()) or ACFLazers.GaussNumber("GaussCaliberBase")
            caliber = ACFLazers.ClampGaussCaliber(caliber)

            if IsValid(info) then info:SetText(ReadoutText(caliber)) end
            if IsValid(box) then box:SetText(BoxText(caliber)) end
        end

        -- The same name every time the panel is built, so an old panel's callback is replaced instead of piling up.
        for _, name in ipairs({ "caliber", "boxx", "boxy", "boxz" }) do
            cvars.AddChangeCallback("acf_gauss_tool_" .. name, function() Refresh() end, "acf_gauss_tool_readout")
        end

        Refresh()
        timer.Simple(0, Refresh) -- once more after the sliders have read their saved values

        panel:Help("Link an inert ammo box to the rifle with the right-click link controls of this tool (or any tool of this addon). A box must be inert and, by default, of the same size (caliber) as the rifle. Link a capacitor to the rifle the same way: it takes its shot energy from the capacitors linked to it, like a PPC. The tracer is always on. Fire the rifle with the Fire wire input.")
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

-- ===================== Shift + left click: the inert ammo box =====================

local function InertBox(tool, trace)
    local ply      = tool:GetOwner()
    local Entities = ACF.Classes.Entities
    local Ammo     = ACF.Classes.AmmoTypes

    -- ACF quietly turns an ammo type it does not know into armour piercing; that must never happen here, so look first.
    if not (Ammo.Get(ACFLazers.GaussAmmoID) and ACF.Classes[ACFLazers.GaussRegistry] and ACF.Classes[ACFLazers.GaussRegistry].Get(ACFLazers.GaussClassID)) then
        Say(ply, "Error", "The DART ammo type or the gauss rifle class is not registered: lua/acf/entities/ammo_types/lazers_dart.lua or lua/acf/entities/weapons/lazers_gauss.lua is missing (copy them to the game, the git folder and the server, then restart).")

        return false
    end

    local x, y, z  = ClampBox(ply:GetInfoNum("acf_gauss_tool_boxx", BoxDefault), ply:GetInfoNum("acf_gauss_tool_boxy", BoxDefault), ply:GetInfoNum("acf_gauss_tool_boxz", BoxDefault))
    local caliber  = ACFLazers.ClampGaussCaliber(ply:GetInfoNum("acf_gauss_tool_caliber", ACFLazers.GaussNumber("GaussCaliberBase")))

    local Data = {
        Destiny   = ACFLazers.GaussRegistry,
        Weapon    = ACFLazers.GaussClassID,
        Caliber   = caliber,
        AmmoType  = ACFLazers.GaussAmmoID,
        AmmoShape = "Box",
        AmmoSizeX = x,
        AmmoSizeY = y,
        AmmoSizeZ = z,
        AmmoStage = 1,
    }

    -- Aiming at an ammo crate: update it if it is an inert box, leave it alone if it holds anything else
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_ammo" then
        if not hit.IsInertCrate then
            Say(ply, "Error", "That ammo crate holds " .. tostring(hit.AmmoType) .. ", not DART rounds: this tool only changes boxes of darts (nothing was changed).")

            return false
        end

        if not MayTouch(tool, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that ammo box.")

            return false
        end

        local ok, message = Entities.Update(hit, Data) -- calls ENT:Update in ACF's ammo crate module

        Say(ply, ok and "Info" or "Error", message)

        return true
    end

    -- Spawn: its up (+Z) along the surface we aimed at, its middle half its height (plus 1 unit) above the spot. [GUESS] that ACF's crate models are centred on their origin. ACF fits whole rounds,
    -- so the box can come out bigger than the sliders: it is lifted by its real height afterwards.
    local spawnPos = trace.HitPos + (trace.HitNormal * (z / 2 + 1))

    local angles = trace.HitNormal:Angle()
    angles:RotateAroundAxis(angles:Right(), -90)

    local ok, result = Entities.Spawn("acf_ammo", ply, spawnPos, angles, Data) -- calls ACF.MakeAmmo

    if not ok then
        Say(ply, "Error", "Couldn't create the ammo box: " .. tostring(result))

        return false
    end

    if not result.IsInertCrate then
        Say(ply, "Error", "The new crate came out as " .. tostring(result.AmmoType) .. " instead of DART: it was removed.")
        result:Remove()

        return false
    end

    local okSize, size = pcall(result.GetSize, result)

    if okSize and isvector(size) and size.z > z then
        result:SetPos(trace.HitPos + (trace.HitNormal * (size.z / 2 + 1)))
    end

    Freeze(result)

    return true
end

-- ===================== left click: spawn / update =====================

function TOOL:LeftClick(trace)
    if trace.HitSky then return false end
    if CLIENT then return true end

    local ply = self:GetOwner()

    if ply:KeyDown(IN_SPEED) then return InertBox(self, trace) end

    local Entities = ACF.Classes.Entities

    -- The entity clamps this again server-side (VerifyData in init.lua); the note is only so the player knows.
    local Data = {
        Caliber = ply:GetInfoNum("acf_gauss_tool_caliber", ACFLazers.GaussNumber("GaussCaliberBase")),
        Tracer  = true, -- (23.3) always on; the rifle holds it on whatever this says
    }

    local clamped = ACFLazers.ClampGaussCaliber(Data.Caliber)

    if math.abs(clamped - Data.Caliber) > 0.001 then
        Say(ply, "Info", string.format("Size limited to %g mm (a gauss rifle goes from %g to %g mm).", clamped, ACFLazers.GaussNumber("GaussCaliberMin"), ACFLazers.GaussNumber("GaussCaliberMax")))
    end

    -- Aiming at one of our rifles: update it instead of spawning another
    local hit = trace.Entity

    if IsValid(hit) and hit:GetClass() == "acf_gauss" then
        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to change that gauss rifle.")

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

    local ok, result = Entities.Spawn("acf_gauss", ply, spawnPos, angles, Data) -- calls MakeACFGauss in init.lua

    if not ok then
        Say(ply, "Error", "Couldn't create the gauss rifle: " .. tostring(result))

        return false
    end

    Freeze(result)

    return true
end
