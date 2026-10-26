-- =========================================================================
-- ACF RADIATOR: SERVER FILE
-- Goes to:  lua/entities/acf_radiator/init.lua      (the server runs this one. The CLIENT file is cl_init.lua next to it: never put this file there)
--           NEEDS the 15.2 config (lua/autorun/acf_lazers_config.lua) AND lua/autorun/acf_lazers_heat.lua: it refuses to load without them
--
-- NEW (15.2). THE RADIATOR (heat sink): takes heat out of the parts around it. All the cooling logic is HERE; the parts hold none.
--   * size: the tool slider is the WIDTH in units (config RadWidthMin..RadWidthMax). The model (RadModel, 42 x 42 x 30 at scale 1) is scaled by width / RadModelWidth. The width sets the
--     mass (RadMassMin..RadMassMax), the radius (RadRadiusSmall..Big), the sap rate (RadSapSmall..Big, in kJ per second at overclock 1) and the waste share (RadWasteSmall..Big)
--   * members: every entity with a physics object in the radiator's CONTRAPTION (ACF's own tracking, CFW) and inside its radius, except players, NPCs and radiators. The list is rebuilt
--     when CFW says the contraption changed (parts added / removed, merged, split), when the radiator is resized or linked, and every RadRefreshInterval seconds as a safety net
--   * work: ONE timer for all radiators (every RadSweepInterval seconds). Per sweep a radiator pool takes  rate x time  kJ out of the hot members, each giving in proportion to its
--     temperature above room temperature ^ RadWeightPower (a part never goes below room temperature; what it cannot give goes to the others)
--   * pools: radiators linked to each other (the link tools) are one pool: one combined member list (a part counts once) and the sum of the sap rates. Each keeps its own heat,
--     overclock and efficiency. A radiator on its own is a pool of one
--   * its own heat: it makes waste heat (RadWaste x the work it TRIES to do); its efficiency is 100% up to RadEffStartPct of HOT, falls in a straight line to RadEffFloorPct at 100%;
--     over 100% it damages itself (RadDamage, quadratic, through ACF's damage pipeline) until it dies. It cools by itself like any ACF entity
--   * wire:  input Overclock (multiplies the sap rate and the waste; unwired = RadOverclockDefault, 0 = off, at most RadOverclockMax)
--            outputs SapRate (kJ/s it really takes out), Attempted (kJ/s it tries to take out), Efficiency (percent), Members (parts in range), HotParts (hot parts in its pool),
--            Pool (radiators in its pool), Radius (units), HeatKJ, HeatF, HeatPct (percent of the HOT temperature)
-- All numbers live in lua/autorun/acf_lazers_config.lua (everything starting with Rad...).
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Damage      = ACF.Damage
local Objects     = Damage.Objects
local Entities    = ACF.Classes.Entities

local CFG = ACFLazers and ACFLazers.Config

if not CFG then
    ErrorNoHalt("[acf_radiator] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

if not (ACFLazers.Heat and ACFLazers.Heat.Add and ACFLazers.GetHeatCapacity) then
    ErrorNoHalt("[acf_radiator] the heat system is missing: copy lua/autorun/acf_lazers_heat.lua and the 15.2 lua/autorun/acf_lazers_config.lua, then restart.\n")
    return
end

if not (ACFLazers.GetRadSap and ACFLazers.RadPoolStep and ACFLazers.WeightedFill) then
    ErrorNoHalt("[acf_radiator] lua/autorun/acf_lazers_config.lua is older than this file (it has no radiator knobs or helpers). Copy the config of the same batch (15.2), then restart.\n")
    return
end

local Heat = ACFLazers.Heat

local VERSION = "15.2"
MsgN("[acf_radiator] init.lua version " .. VERSION .. " loaded")

-- How many radiators one player may own (GMod reads a server variable called sbox_max<name>; CreateConVar does nothing if it already exists).
CreateConVar("sbox_maxacf_radiators", tostring(CFG.RadMaxPerPlayer), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF radiators one player may spawn")

-- ===================== THE MANAGER =====================
-- Every radiator is in Rad.List (a weak set: a removed radiator drops out by itself). Rad.Groups = the pools (lists of radiators), rebuilt when a link changed (ACFLazers.LinkVersion)
-- or a radiator appeared / went. One timer runs the work of every pool.
ACFLazers.Rad = ACFLazers.Rad or {}

local Rad = ACFLazers.Rad

Rad.List         = Rad.List or setmetatable({}, { __mode = "k" })
Rad.Groups       = Rad.Groups or {}
Rad.GroupVersion = Rad.GroupVersion or -1
Rad.GroupsDirty  = true

local function ByIndex(a, b) return a:EntIndex() < b:EntIndex() end

-- The pools: connected sets of linked radiators, each in a fixed order (by entity index), so everything that depends on the order is repeatable.
function Rad.BuildGroups()
    local list = {}

    for radiator in pairs(Rad.List) do
        if IsValid(radiator) then list[#list + 1] = radiator end
    end

    table.sort(list, ByIndex)

    local seen, groups = {}, {}

    for _, radiator in ipairs(list) do
        if not seen[radiator] then
            local group, head = { radiator }, 1

            seen[radiator] = true

            while head <= #group do
                local current = group[head]

                head = head + 1

                for other in pairs(current.Links) do
                    if IsValid(other) and Rad.List[other] and not seen[other] then
                        seen[other]        = true
                        group[#group + 1] = other
                    end
                end
            end

            table.sort(group, ByIndex)

            groups[#groups + 1] = group
        end
    end

    Rad.Groups       = groups
    Rad.GroupVersion = ACFLazers.LinkVersion
    Rad.GroupsDirty  = false
end

-- The hot parts of a pool: every entity with a heat record that is a member of ANY radiator in it (a part counts once). Returns the entities, their weights, their limits (the kJ each
-- holds) and the total kJ. The heat store's registry is small (only parts that are warm), so this costs by the number of hot parts, not by the size of the contraption.
local function GatherHot(live)
    local hot, weights, limits, avail = {}, {}, {}, 0
    local power = CFG.RadWeightPower

    for ent in pairs(Heat.Registry) do
        if IsValid(ent) then
            local member = false

            for _, radiator in ipairs(live) do
                if radiator.Members[ent] then
                    member = true

                    break
                end
            end

            if member then
                local kJ = Heat.GetKJ(ent)

                if kJ > 0 then
                    local weight = (kJ / Heat.GetCapacity(ent)) ^ power -- temperature above room temperature, ^ RadWeightPower

                    if weight ~= weight or weight <= 0 then weight = 1e-9 end -- (a hot part always gets some weight, so it is never left out)

                    hot[#hot + 1]         = ent
                    weights[#weights + 1] = weight
                    limits[#limits + 1]   = kJ
                    avail                 = avail + kJ
                end
            end
        end
    end

    return hot, weights, limits, avail
end

-- One pool, one sweep. `dt` = seconds since the last sweep.
function Rad.RunGroup(group, now, dt)
    local live = {}

    for _, radiator in ipairs(group) do
        if IsValid(radiator) and not radiator.HeatDying then
            if radiator.MembersDirty or now >= radiator.NextRefresh then radiator:RebuildMembers(now) end

            live[#live + 1] = radiator
        end
    end

    if #live == 0 then return end

    -- 1. what the pool could take, and what is there to take
    local hot, weights, limits, avail = GatherHot(live)
    local items = {}

    for i, radiator in ipairs(live) do
        local overclock = radiator:GetOverclock()
        local sap       = ACFLazers.GetRadSap(radiator:GetWidth()) * overclock

        radiator.Overclock  = overclock
        radiator.NominalSap = sap
        radiator.Efficiency = ACFLazers.GetRadEfficiency(radiator:GetHeatPct())

        items[i] = { sap = sap, eff = radiator.Efficiency }
    end

    -- 2. the step: how much is removed, and how much work each radiator did
    local total, out = ACFLazers.RadPoolStep(items, avail, dt)

    -- 3. take it out of the hot parts (each gives by weight, never more than it holds)
    if total > 0 then
        local takes = ACFLazers.WeightedFill(weights, limits, total)

        for i, ent in ipairs(hot) do
            if takes[i] > 0 and IsValid(ent) then Heat.Add(ent, -takes[i]) end
        end
    end

    -- 4. the radiators: waste heat, readings, then each one's own damage / outputs / hover text
    for i, radiator in ipairs(live) do
        local step = out[i]

        if step.work > 0 then Heat.Add(radiator, step.work * ACFLazers.GetRadWaste(radiator:GetWidth())) end

        radiator.Attempted = dt > 0 and step.work / dt or 0
        radiator.SapRate   = dt > 0 and step.removed / dt or 0
        radiator.PoolSap   = dt > 0 and total / dt or 0
        radiator.PoolSize  = #live
        radiator.HotParts  = #hot
    end

    for _, radiator in ipairs(live) do radiator:Finish(dt) end
end

function Rad.Sweep()
    local now = CurTime()
    local dt  = math.Clamp(now - (Rad.LastSweep or now), 0, math.max(CFG.RadMaxDeltaTime, 0.05))

    Rad.LastSweep = now

    if Rad.GroupsDirty or Rad.GroupVersion ~= ACFLazers.LinkVersion then Rad.BuildGroups() end

    for _, group in ipairs(Rad.Groups) do Rad.RunGroup(group, now, dt) end
end

timer.Create("ACFLazers_RadiatorSweep", math.max(CFG.RadSweepInterval, 0.05), 0, function() Rad.Sweep() end)

-- ===================== CFW EVENTS =====================
-- [GUESS] the arguments: entityAdded / entityRemoved (contraption, entity), created / removed (contraption), merged (contraption, the one it was merged into), split (previous, new)
-- [SEEN in track_cost_sv.lua, entity_tracking_sv.lua, kill_tracking_sv.lua, acf_rack/init.lua:446-453]. Only the contraption is used: radiators in it rebuild their member list at the
-- next sweep. For the rare structural events every radiator rebuilds.
local function MarkContraption(contraption)
    for radiator in pairs(Rad.List) do
        if IsValid(radiator) then
            if not istable(contraption) or not radiator.HasContraption or radiator:GetMyContraption() == contraption then radiator.MembersDirty = true end
        end
    end
end

hook.Add("cfw.contraption.entityAdded", "ACFLazers_RadiatorMembers", function(contraption) MarkContraption(contraption) end)
hook.Add("cfw.contraption.entityRemoved", "ACFLazers_RadiatorMembers", function(contraption) MarkContraption(contraption) end)

for _, event in ipairs({ "created", "removed", "merged", "split" }) do
    hook.Add("cfw.contraption." .. event, "ACFLazers_RadiatorMembers", function() MarkContraption(nil) end)
end

-- ===================== WIRE =====================

-- The Overclock input, made safe (0 .. RadOverclockMax). Nothing wired = RadOverclockDefault. [GUESS] that Wire keeps the entity a wire comes from in Inputs[name].Src (the generator's
-- Draw input and the capacitor's AllowCharge rely on the same thing). Should this Wire not have it, the last value sent to TriggerInput is used as soon as one has arrived.
function ENT:GetOverclock()
    local input = self.Inputs and self.Inputs.Overclock
    local value = CFG.RadOverclockDefault

    if input and IsValid(input.Src) then
        self.SrcWorks = true
        value         = tonumber(input.Value) or 0
    elseif not self.SrcWorks and self.OverclockTouched then
        value = self.WireOverclock
    end

    return ACFLazers.ClampRadOverclock(value)
end

function ENT:TriggerInput(name, value)
    if name == "Overclock" then
        self.WireOverclock    = tonumber(value) or 0
        self.OverclockTouched = true
    end

    self:UpdateOverlay()
end

-- ===================== SPAWN AND SIZE =====================

function ENT:Initialize()
    self.Width          = CFG.RadWidthDefault
    self.Links          = {}      -- the radiators linked to this one (a set)
    self.Members        = setmetatable({}, { __mode = "k" }) -- the parts it can cool (a set, rebuilt by RebuildMembers)
    self.MemberCount    = 0
    self.MembersDirty   = true
    self.NextRefresh    = 0
    self.HasContraption = false
    self.Overclock      = CFG.RadOverclockDefault
    self.NominalSap     = 0       -- kJ/s it tries to take out (sap rate x overclock), as of the last sweep
    self.Attempted      = 0       -- kJ/s of work it really did in the last sweep (less than nominal when the parts around it are nearly cold)
    self.SapRate        = 0       -- kJ/s it really took out (the work x its efficiency)
    self.Efficiency     = 1
    self.PoolSap        = 0       -- kJ/s the whole pool took out
    self.PoolSize       = 1
    self.HotParts       = 0
    self.Status         = "Not set up yet"
    self.StatusKind     = "new"
    self.OverlaySig     = ""
    self.HeatDying      = false

    Rad.List[self]  = true
    Rad.GroupsDirty = true

    if WireLib then
        WireLib.CreateInputs(self, { "Overclock" })
        WireLib.CreateOutputs(self, {
            "SapRate",    -- kJ per second it really takes out
            "Attempted",  -- kJ per second it tries to take out
            "Efficiency", -- percent
            "Members",    -- parts in range (in its contraption and inside its radius)
            "HotParts",   -- hot parts in its pool
            "Pool",       -- radiators in its pool
            "Radius",     -- units
            "HeatKJ",     -- kJ of heat above room temperature
            "HeatF",      -- temperature in Fahrenheit
            "HeatPct"     -- percent of the HOT temperature (100 = HOT, above = damaging itself)
        })
    end

    self:UpdateWireOutputs()
end

-- Clamp whatever the tool / a dupe / an update sends us (the server never trusts the client).
local function VerifyData(Data)
    Data.Width = ACFLazers.ClampRadWidth(Data.Width)
end

-- Model, scale, ACF health and mass for a width. Same order the lazer, the capacitor and the generator use: scale first (that makes the physics object), then ACF.Activate, then the mass.
function ENT:ApplyScale(width)
    self:SetScaledModel(CFG.RadModel)
    self:SetScale(ACFLazers.GetRadScale(width))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetRadMass(width))
end

-- Apply a whole Data table {Width = units}. Used by spawn AND by update. Width is a plain field on purpose: the duplicator saves entity fields (see Entities.Register at the bottom).
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.Width = Data.Width
    self.Name  = string.format("%d-unit Radiator", Data.Width) -- the undo list uses Entity.Name

    self:SetNW2Int("ACFRadWidth", self.Width)
    self:ApplyScale(Data.Width)

    self.MembersDirty = true -- the radius changed

    self:UpdateWireOutputs()
end

-- Gun-style health and armour (acf_gun/init.lua:1344-1364), with the model scale in place of a caliber and the multipliers from the config.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = CFG.RadArmourAtOne * ACFLazers.GetRadScale(self.Width or CFG.RadWidthDefault) * ACF.ArmorMod
    local Health  = Area / ACF.Threshold * CFG.RadHealthMult
    local Percent = 1

    if Recalc and SelfACF.Health and SelfACF.MaxHealth then
        Percent = SelfACF.Health / SelfACF.MaxHealth
    end

    SelfACF.Area      = Area
    SelfACF.Health    = Health * Percent
    SelfACF.MaxHealth = Health
    SelfACF.Armour    = Armour * (0.5 + Percent * 0.5)
    SelfACF.MaxArmour = Armour
    SelfACF.Type      = "Prop"
end

-- ===================== THE MEMBERS =====================

-- CFW's contraption this radiator is in (nil when it is not constrained to anything, or CFW is missing).
function ENT:GetMyContraption()
    if not self.CFW_GetContraption then return nil end

    return self:CFW_GetContraption()
end

-- Can this entity be cooled by a radiator? Anything with a physics object, except players, NPCs and radiators.
local function Eligible(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() or ent:IsNPC() then return false end
    if ent:GetClass() == "acf_radiator" then return false end

    return IsValid(ent:GetPhysicsObject())
end

-- Rebuild the list of parts this radiator can cool: its contraption's entities that are inside its radius. One squared-distance check per part.
function ENT:RebuildMembers(now)
    local members, count = setmetatable({}, { __mode = "k" }), 0
    local contraption    = self:GetMyContraption()

    if contraption and contraption.ents then
        local center  = self:WorldSpaceCenter()
        local radius  = ACFLazers.GetRadRadius(self:GetWidth())
        local radius2 = radius * radius

        for ent in pairs(contraption.ents) do
            if ent ~= self and Eligible(ent) and ent:WorldSpaceCenter():DistToSqr(center) <= radius2 then
                members[ent] = true
                count        = count + 1
            end
        end
    end

    self.Members        = members
    self.MemberCount    = count
    self.HasContraption = contraption ~= nil
    self.MembersDirty   = false
    self.NextRefresh    = now + CFG.RadRefreshInterval
end

-- ===================== HEAT =====================
-- Heat is kept by lua/autorun/acf_lazers_heat.lua; the manager above puts the waste in. The radiator's 100% is the HOT temperature, like a plate's.

function ENT:GetHeatPct()
    return Heat.GetPctHot(self)
end

-- Over its limit the radiator hurts itself: RadDamage percent of its max health per second at twice the limit, growing with the square of how far over it is. It goes through ACF's
-- damage pipeline (Heat.Hurt), so ACF's own rules apply; a kill makes it die like a prop killed by a bullet.
function ENT:HeatThink(dt)
    local over = self:GetHeatPct() - 1

    if over <= 0 or dt <= 0 or self.HeatDying then return end

    local acf = self.ACF

    if not (acf and acf.MaxHealth and acf.MaxHealth > 0) then return end

    local HitRes = Heat.Hurt(self, acf.MaxHealth * ACFLazers.GetHeatDamagePct(over, CFG.RadDamage) / 100 * dt)

    if HitRes and HitRes.Kill then self:HeatDeath() end
end

function ENT:HeatDeath()
    if self.HeatDying then return end

    self.HeatDying = true

    Rad.GroupsDirty = true

    local dmgInfo = Objects.DamageInfo(Heat.GetAttacker(self), self)

    ACF.APKill(self, VectorRand(), math.min(CFG.HeatDeathDebrisPower, CFG.MaxDebrisPower), dmgInfo)
end

-- The end of a sweep for this radiator: its own damage, the one-line state, the wire outputs and the hover text.
function ENT:Finish(dt)
    self:HeatThink(dt)

    if self.HeatDying or not IsValid(self) then return end

    self:UpdateStatus()
    self:UpdateWireOutputs()
    self:RefreshOverlay()
end

-- ===================== STATE, WIRE + OVERLAY =====================

-- The one-line state for the hover text, and a short key for it (the hover text only refreshes when something worth showing changed).
function ENT:UpdateStatus()
    local pct = self:GetHeatPct()

    if pct > 1 then
        self.StatusKind = "over"
        self.Status     = string.format("OVER ITS LIMIT (%.0f%% of HOT): it is damaging itself. Lower the overclock or link more radiators", pct * 100)
    elseif not self.CFW_GetContraption then
        self.StatusKind = "nocfw"
        self.Status     = "ACF's contraption tracking (CFW) was not found: nothing can be cooled"
    elseif not self.HasContraption then
        self.StatusKind = "free"
        self.Status     = "Not constrained to anything: it has no parts to cool"
    elseif self.Overclock <= 0 then
        self.StatusKind = "off"
        self.Status     = "Overclock input is 0: switched off"
    elseif self.MemberCount == 0 then
        self.StatusKind = "empty"
        self.Status     = string.format("No other part of its contraption is within %.0f units", ACFLazers.GetRadRadius(self:GetWidth()))
    elseif self.HotParts == 0 then
        self.StatusKind = "cold"
        self.Status     = string.format("Nothing in range is hot (%d parts in range)", self.MemberCount)
    elseif self.Efficiency < 0.999 then
        self.StatusKind = "hot"
        self.Status     = string.format("Cooling at %.0f%% efficiency (it is hot itself): %.0f kJ/s", self.Efficiency * 100, self.SapRate)
    else
        self.StatusKind = "work"
        self.Status     = string.format("Cooling: taking %.0f kJ/s out of %d hot parts", self.SapRate, self.HotParts)
    end
end

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    WireLib.TriggerOutput(self, "SapRate", self.SapRate)
    WireLib.TriggerOutput(self, "Attempted", self.Attempted)
    WireLib.TriggerOutput(self, "Efficiency", self.Efficiency * 100)
    WireLib.TriggerOutput(self, "Members", self.MemberCount)
    WireLib.TriggerOutput(self, "HotParts", self.HotParts)
    WireLib.TriggerOutput(self, "Pool", self.PoolSize)
    WireLib.TriggerOutput(self, "Radius", ACFLazers.GetRadRadius(self:GetWidth()))
    WireLib.TriggerOutput(self, "HeatKJ", Heat.GetKJ(self))
    WireLib.TriggerOutput(self, "HeatF", Heat.GetTempF(self))
    WireLib.TriggerOutput(self, "HeatPct", self:GetHeatPct() * 100)
end

-- The hover text (ACF's overlay system calls this; ENT:UpdateOverlay() asks it to refresh).
function ENT:ACF_UpdateOverlayState(State)
    if self.StatusKind == "over" then
        State:AddError(self.Status)
    elseif self.StatusKind == "work" then
        State:AddSuccess(self.Status)
    elseif self.StatusKind == "hot" or self.StatusKind == "free" or self.StatusKind == "nocfw" or self.StatusKind == "empty" then
        State:AddWarning(self.Status)
    else
        State:AddLabel(self.Status)
    end

    local width = self:GetWidth()

    State:AddKeyValue("Size", string.format("%d units wide (model scale %.2f), %d kg", width, ACFLazers.GetRadScale(width), ACFLazers.GetRadMass(width)))
    State:AddKeyValue("Radius", string.format("%.0f units, %d parts in range", ACFLazers.GetRadRadius(width), self.MemberCount))
    State:AddKeyValue("Sap rate", string.format("%.0f kJ/s at overclock 1", ACFLazers.GetRadSap(width)))
    State:AddKeyValue("Overclock", string.format("x%.2f (%.0f kJ/s tried)", self.Overclock, self.NominalSap))
    State:AddKeyValue("Taking out", string.format("%.0f kJ/s (efficiency %.0f%%)", self.SapRate, self.Efficiency * 100))
    State:AddKeyValue("Temperature", string.format("%.0f F (%.0f%% of HOT)", Heat.GetTempF(self), self:GetHeatPct() * 100))

    if self.PoolSize > 1 then
        State:AddKeyValue("Pool", string.format("%d radiators, %.0f kJ/s together, %d hot parts", self.PoolSize, self.PoolSap, self.HotParts))
    end
end

-- Refresh the hover text, but only when something worth showing changed (ACF's overlay networks changes).
function ENT:RefreshOverlay()
    local signature = table.concat({
        self.StatusKind,
        math.floor(self:GetHeatPct() * 20),                                   -- the heat in steps of 5% of HOT
        math.floor(self.Efficiency * 20),
        math.floor(self.SapRate / math.max(self.NominalSap, 1) * 10),         -- the work as tenths of what it could do
        self.MemberCount,
        self.HotParts,
        self.PoolSize,
        math.floor(self.Overclock * 10),
    }, "|")

    if signature ~= self.OverlaySig then
        self.OverlaySig = signature
        self:UpdateOverlay()
    end
end

-- ===================== LINKING =====================
-- radiator <-> radiator uses ACF's link system, like capacitor <-> capacitor. The tools call  a:Link(b)  and  a:Unlink(b). Linked radiators are one POOL (see the top of this file).

ACF.RegisterLinkSource("acf_radiator", "Links")

ACF.RegisterClassLink("acf_radiator", "acf_radiator", function(A, B)
    if A == B then return false, "A radiator cannot be linked to itself." end
    if A.Links[B] or B.Links[A] then return false, "These radiators are already linked." end

    A.Links[B] = true
    B.Links[A] = true

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    A:UpdateOverlay(true)
    B:UpdateOverlay(true)

    return true, "Radiators linked into one pool."
end)

ACF.RegisterClassUnlink("acf_radiator", "acf_radiator", function(A, B)
    if not (A.Links[B] or B.Links[A]) then return false, "These radiators are not linked." end

    A.Links[B] = nil
    B.Links[A] = nil

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    A:UpdateOverlay(true)
    B:UpdateOverlay(true)

    return true, "Radiators unlinked."
end)

-- Breaks every link this radiator has. Returns how many it broke. (The link tools' reload uses it.)
function ENT:UnlinkAll()
    local count = 0

    for other in pairs(self.Links) do
        if IsValid(other) and ACF.PerformClassUnlink(self, other) then
            count = count + 1
        else
            self.Links[other] = nil
        end
    end

    return count
end

function ENT:OnRemove()
    -- Straight table clean-up instead of ACF.PerformClassUnlink: the entity is on its way out and we only need everybody to forget it.
    for other in pairs(self.Links) do
        if IsValid(other) and other.Links then other.Links[self] = nil end
    end

    Rad.List[self]  = nil
    Rad.GroupsDirty = true

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
end

-- ===================== UPDATE, SPAWN, DUPES =====================

-- Click-to-update (Entities.Update calls this). Same shape as the generator's.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Radiator updated successfully!"
end

-- Duplicator: the linked radiators' ids are saved and linked again on paste (the same way the generator does it).
function ENT:PreEntityCopy()
    local links = {}

    for other in pairs(self.Links) do
        if IsValid(other) then links[#links + 1] = other:EntIndex() end
    end

    if #links > 0 then duplicator.StoreEntityModifier(self, "ACFRadLinks", links) end

    self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
    local mods = Ent.EntityMods

    if mods and mods.ACFRadLinks then
        for _, id in pairs(mods.ACFRadLinks) do
            local other = CreatedEntities[id]

            if IsValid(other) and other ~= self then self:Link(other) end
        end

        mods.ACFRadLinks = nil
    end

    self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

-- Signature (Player, Pos, Angle, Data) is what Entities.Register wants (registration.lua:1007).
function MakeACFRadiator(ply, pos, angles, Data)
    if not istable(Data) then Data = {} end

    if IsValid(ply) and not ply:CheckLimit("acf_radiators") then return nil end

    -- The model is your buddy's. If it is missing the scalable base cannot build a physics mesh, so say so instead of failing with a pile of errors.
    if not util.IsValidModel(CFG.RadModel) then
        local msg = "[acf_radiator] the model " .. CFG.RadModel .. " is missing on this server (RadModel in acf_lazers_config.lua). Is it installed and is the file name spelled right?"

        ErrorNoHalt(msg .. "\n")

        if IsValid(ply) then ply:ChatPrint(msg) end

        return nil
    end

    local ent = ents.Create("acf_radiator")
    if not IsValid(ent) then return nil end

    -- ACF wants this table and a model BEFORE Spawn (acf_gun/init.lua:482-488)
    ent.ACF = {}
    Contraption.SetModel(ent, CFG.RadModel)

    ent:SetPos(pos)
    ent:SetAngles(angles)

    ent:Spawn()
    ent:Activate()

    ent:ApplyData(Data)

    if IsValid(ply) then
        if ent.SetPlayer then ent:SetPlayer(ply) end
        if CPPI then ent:CPPISetOwner(ply) end
        ply:AddCount("acf_radiators", ent)
        ply:AddCleanup("acf_radiators", ent)
    end

    return ent
end

-- Dupe key: Width.
Entities.Register("acf_radiator", MakeACFRadiator, "Width")
