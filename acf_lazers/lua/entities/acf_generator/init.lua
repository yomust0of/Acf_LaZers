-- =========================================================================
-- CHANGES vs the generator init.lua you have now (version 12). Search this file for [CHANGED n].
--   [CHANGED 1] No more overload that breaks engine links. The hub takes AT MOST its rated hp from its engines in total; engines can push more, the rest is ignored (every engine's
--               load is scaled down together, so the engines feel no more drag than the rating). Hover text says when it is at its rating. CheckOverload is gone
--   [CHANGED 2] Damage: the energy made per hp is multiplied by ACFLazers.GetGenEfficiency(health): 1 at full health, GenDamagedEfficiency (0.5) at 0 health. The engines are still
--               loaded by the same hp: only the kJ drop. Hover text shows the efficiency
--   [CHANGED 3] The "At its rating" hover line quotes what the linked engines are RATED for (their peak hp added up) instead of the load the hub would have asked for: that number
--               swells with rpm when the cap holds an engine back, and read like a power no engine could give. New function ENT:GetEnginesRatedHP, display only
--   Goes to:  lua/entities/acf_generator/init.lua
--
-- THE ACF GENERATOR HUB. A flywheel load: ACF engines are linked to it, it slows their flywheels (the "drag") and stores the power it took as kJ in the capacitors linked to it.
--   * size: the tool slider is the RATED power in hp (config GenHPMin..GenHPMax); the model scale follows it through GenScaleKnots (50 hp 0.5, 350 hp 1, 3500 hp 2)
--   * engines: linked the way ACF links an engine to a gearbox. Same distance rule (ACF.MobilityLinkDistance), same kind of angle test (see GetShaftAngles) with the generator's own
--     limit (GenInputAngle, 45 degrees) on the input side, the same "stretched to 1.5 times the length it had" rule. A link that stops being valid breaks, with a warning to its owner.
--   * drag: every server tick, for every linked engine that is running with throttle, the flywheel loses  torque / inertia  rpm, exactly the way ACF's engine loses rpm to a gearbox
--     [SEEN acf_engine/init.lua:812-859]. The torque comes from ACFLazers.GetGenLoadTorque (config: GenLoad...). The hp this takes becomes kJ: hp x GenKJPerHP per second.
--   * capacitors: linked generator <-> capacitor. The energy is shared out with ACFLazers.WaterFill into the free room of the whole capacitor group, like a dump. When there is no
--     room nothing is taken from the engines. A capacitor with AllowCharge switched off takes nothing.
--   * rating: the total hp taken from all engines is never more than the rated hp. The energy per hp (GenKJPerHP) is multiplied by 1 at full health down to GenDamagedEfficiency at 0.
--   * wire:  input Draw (0 = take nothing ... 100 = take everything; unwired counts as GenDrawDefault)
--            outputs Energy (kJ per second going into the capacitors), HP (taken from the engines), Rated (hp rating), Load (percent of the rating), Engines, Full (1 = capacitors full)
-- All numbers live in lua/autorun/acf_lazers_config.lua (everything starting with Gen...).
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities

local CFG = ACFLazers and ACFLazers.Config

if not CFG then
    ErrorNoHalt("[acf_generator] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

local VERSION = "13"
MsgN("[acf_generator] init.lua version " .. VERSION .. " loaded")

-- How many generators one player may own (GMod reads a server variable called sbox_max<name>; CreateConVar does nothing if it already exists).
CreateConVar("sbox_maxacf_generators", tostring(CFG.GenMaxPerPlayer), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF generator hubs one player may spawn")

local UnlinkSound = "physics/metal/metal_box_impact_bullet%s.wav" -- the clunk ACF plays when a mobility link breaks [SEEN acf_engine/init.lua:120]

-- ACF's chat / sound helpers, wrapped: a missing or changed helper must never stop a link from breaking.
local function Warn(ent, title, text)
    local Notify = ACF.Utilities and ACF.Utilities.Notify

    if Notify and Notify.EntityWarning then pcall(Notify.EntityWarning, ent, title, text) end -- [SEEN acf_gearbox/init.lua:268]
end

local function Clunk(...)
    local Sounds = ACF.Utilities and ACF.Utilities.Sounds

    if not (Sounds and Sounds.SendSound) then return end

    for _, ent in ipairs({ ... }) do
        if IsValid(ent) then pcall(Sounds.SendSound, ent, UnlinkSound:format(math.random(1, 3)), 70, 100, 1) end -- [SEEN acf_engine/init.lua:164]
    end
end

local function EngineName(engine)
    return IsValid(engine) and tostring(engine.Name or engine:GetClass()) or "an engine"
end

-- ===================== WIRE =====================

-- The Draw input as a fraction 0..1. Nothing wired = GenDrawDefault. [GUESS] that Wire keeps the entity a wire comes from in Inputs[name].Src (the capacitor's AllowCharge relies on the
-- same thing). Should this Wire not have it, the last value sent to TriggerInput is used as soon as one has arrived.
function ENT:GetDraw()
    local input = self.Inputs and self.Inputs.Draw
    local value = CFG.GenDrawDefault

    if input and IsValid(input.Src) then
        self.SrcWorks = true
        value         = tonumber(input.Value) or 0
    elseif not self.SrcWorks and self.DrawTouched then
        value = self.WireDraw
    end

    if value ~= value then value = 0 end -- NaN (a broken E2 can send one) means nothing; math.Clamp would let it through

    return math.Clamp(value, 0, CFG.GenDrawMax) / math.max(CFG.GenDrawMax, 1e-6)
end

function ENT:TriggerInput(name, value)
    if name == "Draw" then
        self.WireDraw    = tonumber(value) or 0
        self.DrawTouched = true
    end

    self:UpdateOverlay()
end

-- ===================== SPAWN AND SIZE =====================

function ENT:Initialize()
    self.RatedHP        = CFG.GenHPDefault
    self.Engines        = {}      -- engines linked to this generator (a set: key = engine, value = { RopeLen, Time, HP }). HP = the hp taken from that engine, smoothed
    self.Caps           = {}      -- capacitors linked to this generator (a set)
    self.EngineList     = {}      -- the engines as a list in a fixed order (oldest link first); rebuilt when the set changes
    self.ListDirty      = true
    self.Pool           = {}      -- the capacitor group the energy goes to (rebuilt when ACFLazers.LinkVersion changes)
    self.PoolVersion    = -1
    self.In             = nil     -- the driveshaft input plane (set by ApplyScale)
    self.PowerHP        = 0       -- hp taken from all engines, smoothed
    self.EnergyRate     = 0       -- kJ per second going into the capacitors (smoothed)
    self.Room           = 0       -- free room in the capacitors, kJ (as of the last tick)
    self.Refusing       = 0       -- capacitors with room that refuse energy because their AllowCharge is off (as of the last tick)
    self.Status         = "Not set up yet"
    self.OfferedHP      = 0       -- hp the hub's load WOULD take at the engines' present rpm if it had no rating (smoothed). It is what the cap compares with the rating, not what an engine can give: an engine held back by the cap revs up and this number grows with rpm
    self.Efficiency     = 1       -- energy multiplier from the hub's health (1 = undamaged)
    self.LastThink      = CurTime()
    self.NextCheck      = CurTime() + CFG.GenCheckInterval
    self.NextOutput     = 0
    self.OverlaySig     = ""
    self.Exploding      = false

    if WireLib then
        WireLib.CreateInputs(self, { "Draw" })
        WireLib.CreateOutputs(self, {
            "Energy", -- kJ per second going into the capacitors
            "HP",     -- hp being taken from the engines
            "Rated",  -- the rating in hp
            "Load",   -- percent of the rating
            "Engines", -- how many engines are linked
            "Full"    -- 1 while the capacitors are full (nothing is taken from the engines)
        })
    end

    self:NextThink(CurTime())
    self:UpdateWireOutputs()
end

-- Clamp whatever the tool / a dupe / an update sends us (the server never trusts the client).
local function VerifyData(Data)
    Data.RatedHP = ACFLazers.ClampGenHP(Data.RatedHP)
end

-- The input plane, the way ACF keeps a gearbox's:  ACF.LocalPlane(position, direction)  [SEEN acf/core/utilities/util_sh.lua:297]. For an INPUT the direction is the one
-- pointing back INTO the model: ApplyTo turns it round, so the "straight" line of the shaft ends up pointing out of the front (forward, +X) from the input point.
-- That is how ACF sets up the gearbox shapes with the input on the front [SEEN acf_gearbox/init.lua:222: -vector_forward].
function ENT:BuildInputPlane()
    self.In = ACF.LocalPlane(self:GetInputLocal(), Vector(-1, 0, 0))
end

-- Model, scale, ACF health and mass for a rated power. Same order the lazer and the capacitor use: scale first (that makes the physics object), then ACF.Activate, then the mass.
function ENT:ApplyScale(hp)
    self:SetScaledModel(CFG.GenModel)
    self:SetScale(ACFLazers.GetGenScale(hp))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetGenMass(hp))
end

-- Apply a whole Data table {RatedHP = hp}. Used by spawn AND by update. RatedHP is a plain field on purpose: the duplicator saves entity fields (see Entities.Register at the bottom).
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.RatedHP = Data.RatedHP
    self.Name    = string.format("%d-hp Generator Hub", Data.RatedHP) -- the undo list uses Entity.Name

    self:SetNW2Int("ACFGenHP", self.RatedHP)
    self:ApplyScale(Data.RatedHP)
    self:BuildInputPlane()

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    -- The input point moved with the scale: every engine must still fit (ACF's gearboxes do this when they are updated [SEEN acf_gearbox/init.lua:442-462]).
    self:CheckLinks()
    self:UpdateWireOutputs()
end

-- Gun-style health and armour (acf_gun/init.lua:1344-1364), with the model scale in place of a caliber and the multipliers from the config.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = CFG.GenArmourAtOne * ACFLazers.GetGenScale(self.RatedHP or CFG.GenHPDefault) * ACF.ArmorMod
    local Health  = Area / ACF.Threshold * CFG.GenHealthMult
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

-- ===================== THE ENGINE LINK =====================

-- How crooked is the shaft between this generator's input and `Engine`'s driveshaft? Two numbers in degrees, worked out exactly the way ACF.DetermineDriveshaftAngle does it
-- for engine -> gearbox [SEEN acf/core/utilities/util_sh.lua:312-355], but kept apart so the generator can have its own limit on its side:
--   toInput  = how far the line from the generator's input to the engine's shaft end is from "straight ahead from the input" (the 45 degree cone)
--   toEngine = how far the same line is from "straight out of the engine's shaft"                       (ACF's own limit, ACF.MaxDriveshaftAngle)
-- ApplyTo returns the world position of the plane and the world direction of its "straight" line [SEEN util_sh.lua:303-305].
function ENT:GetShaftAngles(Engine)
    local OutPos, OutDir = Engine.Out:ApplyTo(Engine)
    local InPos, InDir   = self.In:ApplyTo(self)
    local between        = OutPos - InPos

    if between:Length() < 1e-6 then return 0, 0, 0 end

    local line = between:GetNormalized()

    local toInput  = math.deg(math.acos(math.Clamp(line:Dot(InDir), -1, 1)))
    local toEngine = math.deg(math.acos(math.Clamp((-line):Dot(OutDir), -1, 1)))

    return toInput, toEngine, between:Length()
end

-- Is `Engine` allowed to be linked to this generator right now? Used when linking (link == nil) and by the periodic check (link = the stored link table).
-- Returns true, or false and the reason (a sentence for the player).
function ENT:CheckEngine(Engine, link)
    if not IsValid(Engine) then return false, "The engine is gone." end

    local out = Engine.Out

    if not (out and out.ApplyTo) or not self.In then return false, "This is not a normal ACF engine (no driveshaft)." end

    local maxDistance = ACF.MobilityLinkDistance

    if Engine:GetPos():DistToSqr(self:GetPos()) > maxDistance * maxDistance then
        return false, "Too far away!"
    end

    local toInput, toEngine, length = self:GetShaftAngles(Engine)

    if toInput > CFG.GenInputAngle then
        return false, string.format("Excessive driveshaft angle! The engine is %d degrees off the generator's input (the limit is %d). Put the engine in front of the input.", math.Round(toInput), CFG.GenInputAngle)
    end

    if toEngine > (ACF.MaxDriveshaftAngle or 85) then
        return false, string.format("Excessive driveshaft angle! The generator is %d degrees off the engine's shaft (the limit is %d).", math.Round(toEngine), ACF.MaxDriveshaftAngle or 85)
    end

    if link and length > link.RopeLen * CFG.GenStretchFactor then
        return false, "Excessive distance! The link was stretched."
    end

    return true, nil, length
end

-- The periodic check (and the one after a resize): break every engine link that is no longer valid.
function ENT:CheckLinks()
    for Engine, link in pairs(self.Engines) do
        local ok, why = self:CheckEngine(Engine, link)

        if not ok then
            self:BreakEngineLink(Engine, "Generator to Engine connection broken", why)
        end
    end
end

-- Break the link to one engine with a warning and a clunk. If ACF's unlink refuses for any reason the link is dropped by hand: a broken link must never survive.
function ENT:BreakEngineLink(Engine, title, why)
    local name = EngineName(Engine)

    if IsValid(Engine) then
        Clunk(self, Engine)

        local ok = self:Unlink(Engine)

        if not ok then self:ForgetEngine(Engine) end
    else
        self:ForgetEngine(Engine)
    end

    Warn(self, title, name .. ": " .. tostring(why))
end

-- Drop an engine from our tables only (no messages). Used by the unlink function, by engine removal and by BreakEngineLink's fallback.
function ENT:ForgetEngine(Engine)
    self.Engines[Engine] = nil
    self.ListDirty       = true

    if IsValid(Engine) then
        if Engine.ACFGenerators then Engine.ACFGenerators[self] = nil end

        Engine:RemoveCallOnRemove("ACFGenLink" .. self:EntIndex())
    end

    self:SyncRopes()
end

-- The linked engines as a list, oldest link first (a fixed order, so everything that depends on it is repeatable).
function ENT:GetEngineList()
    if self.ListDirty then
        local list = {}

        for Engine, link in pairs(self.Engines) do
            if IsValid(Engine) then
                list[#list + 1] = { engine = Engine, link = link }
            else
                self.Engines[Engine] = nil
            end
        end

        table.sort(list, function(a, b)
            if a.link.Time ~= b.link.Time then return a.link.Time < b.link.Time end

            return a.engine:EntIndex() < b.engine:EntIndex()
        end)

        self.EngineList = list
        self.ListDirty  = false
    end

    return self.EngineList
end

function ENT:CountEngines()
    local count = 0

    for _ in pairs(self.Engines) do count = count + 1 end

    return count
end

-- Tell the clients which engines to draw ropes to (NW2 values reach players who join later too).
function ENT:SyncRopes()
    local i = 0

    for Engine in pairs(self.Engines) do
        if IsValid(Engine) and i < CFG.GenMaxEngines then
            i = i + 1
            self:SetNW2Entity("ACFGenEngine" .. i, Engine)
        end
    end

    for j = i + 1, CFG.GenMaxEngines do
        self:SetNW2Entity("ACFGenEngine" .. j, NULL)
    end
end

-- ===================== THE CAPACITORS =====================

-- The capacitors the energy can go to: the whole group of every linked capacitor (like a lazer's pool). Rebuilt only when a link changed somewhere.
function ENT:GetPool()
    if self.PoolVersion ~= ACFLazers.LinkVersion then
        self.Pool        = ACFLazers.GetCapGroup(self.Caps)
        self.PoolVersion = ACFLazers.LinkVersion
    end

    return self.Pool
end

-- Free room (kJ) in every capacitor that will take energy from a generator: it must exist, not be exploding and have AllowCharge on.
-- Returns the total, the two lists WaterFill wants (who, and how much room each has), and how many capacitors have room but refuse because their AllowCharge is off.
function ENT:GetRoom()
    local caps, limits, total, refusing = {}, {}, 0, 0

    for _, cap in ipairs(self:GetPool()) do
        if IsValid(cap) and not cap.Exploding then
            local room = math.max(cap.Capacity - cap.Charge, 0)

            if room > 0 then
                local allowed = true

                if cap.IsChargeAllowed then allowed = cap:IsChargeAllowed() else allowed = cap.Allowing ~= false end -- (the old capacitor file has no IsChargeAllowed: its mirror is used)

                if not allowed then
                    refusing = refusing + 1
                else
                    caps[#caps + 1]     = cap
                    limits[#limits + 1] = room
                    total               = total + room
                end
            end
        end
    end

    return total, caps, limits, refusing
end

-- ===================== THE LOAD =====================

-- What this engine gives right now, or nil when ACF itself would not load it (not running, disabled, no throttle, or on the rev limiter: the engine only talks to its
-- gearboxes while it has throttle [SEEN acf_engine/init.lua:834] and is not rev limited [SEEN :788]).
local function ReadEngine(Engine)
    if not IsValid(Engine) then return end
    if not Engine.Active or Engine.Disabled then return end
    if (Engine.Throttle or 0) <= 0 or Engine.RevLimited then return end

    local rpm, idle, inertia = Engine.FlyRPM, Engine.IdleRPM, Engine.Inertia

    if not (rpm and idle and inertia and Engine.PeakPower and Engine.PeakPowerRPM) then return end
    if rpm <= 0 or inertia <= 0 then return end

    return rpm, idle, inertia, Engine.PeakPower, Engine.PeakPowerRPM
end

-- One tick of work. `dt` = seconds since the last tick.
function ENT:Run(now, dt)
    if now >= self.NextCheck then
        self.NextCheck = now + CFG.GenCheckInterval
        self:CheckLinks()
    end

    local draw = self:GetDraw()
    local list = self:GetEngineList()
    local room, caps, limits, refusing = self:GetRoom()

    -- ACF's flywheel works in whole server ticks: every tick the engine loses  torque / inertia  rpm to what it drives [SEEN acf_engine/init.lua:850]. This pass covers `ticks`
    -- ticks (exactly 1 when the hub thinks every tick, as it does), so the rpm loss is scaled by it and the energy by the seconds (dt).
    local ticks = dt / math.max(engine.TickInterval(), 1e-6)

    -- 1. What would each engine give if nothing limited it? Torque taken (Nm) and the rpm that costs, then the power that is worth.
    local jobs, totalKW, offeredHP = {}, 0, 0

    if draw > 0 and room > 0 and ticks > 0 then
        for _, item in ipairs(list) do
            local rpm, idle, inertia, peakKW, peakRPM = ReadEngine(item.engine)

            if rpm then
                local torque = ACFLazers.GetGenLoadTorque(draw, rpm, peakKW, peakRPM)
                local loss   = math.min(torque / inertia * ticks, math.max(rpm - idle, 0)) -- the flywheel cannot be pulled below idle, like ACF's gearboxes
                local taken  = loss * inertia / ticks                                        -- torque really taken, per tick (Nm)
                local kW     = taken * rpm / CFG.GenKwRpmConstant

                jobs[#jobs + 1] = { item = item, loss = loss, kW = kW, rpm = rpm }
                totalKW         = totalKW + kW
                offeredHP       = offeredHP + ACFLazers.GetGenHP(kW)
            end
        end
    end

    -- 2. The rating: never more than RatedHP in total. Everything is scaled down together (each engine gives its share of the rating), so the engines only feel that much.
    local capShare = 1

    if offeredHP > self.RatedHP then capShare = self.RatedHP / offeredHP end

    -- 3. Not more than the capacitors can hold either (the kJ that would be stored, with the hub's health in it).
    local efficiency = ACFLazers.GetGenEfficiency(self:GetHealthFraction())
    local wantKJ     = ACFLazers.GetGenEnergy(totalKW * capShare, dt) * efficiency
    local share      = capShare

    if wantKJ > room then share = capShare * room / wantKJ end

    -- 4. Do it: slow the flywheels, add up the energy.
    local hpNow = {}
    local storedKJ = 0

    for _, job in ipairs(jobs) do
        local eng = job.item.engine

        eng.FlyRPM = math.max(eng.FlyRPM - job.loss * share, 0)

        hpNow[job.item] = ACFLazers.GetGenHP(job.kW * share)
        storedKJ        = storedKJ + ACFLazers.GetGenEnergy(job.kW * share, dt) * efficiency
    end

    if storedKJ > 0 then
        local takes = ACFLazers.WaterFill(limits, storedKJ)

        for i, cap in ipairs(caps) do
            if takes[i] > 0 then cap:AddCharge(takes[i]) end
        end
    end

    -- 5. The readings: each engine's hp, smoothed, and the total.
    local alpha = 1 - math.exp(-dt / math.max(CFG.GenPowerSmoothing, 1e-6))
    local total = 0

    for _, item in ipairs(list) do
        local hp = hpNow[item] or 0

        item.link.HP = item.link.HP + (hp - item.link.HP) * alpha
        total        = total + item.link.HP
    end

    self.OfferedHP  = self.OfferedHP + (offeredHP - self.OfferedHP) * alpha
    self.Efficiency = efficiency
    self.PowerHP    = total
    self.EnergyRate = total * CFG.GenKJPerHP * efficiency
    self.Room       = room
    self.RoomCaps   = #caps
    self.Refusing   = refusing

    self:UpdateStatus(draw, room, #jobs)

    -- 6. Wire outputs and hover text, a few times a second.
    if now >= self.NextOutput then
        self.NextOutput = now + CFG.GenOutputInterval
        self:UpdateWireOutputs()
        self:RefreshOverlay()
    end
end

-- 0..1: the hub's ACF health as a share of its maximum (1 when it has none, so a hub that is not set up yet counts as undamaged).
function ENT:GetHealthFraction()
    local SelfACF = self.ACF

    if SelfACF and SelfACF.Health and SelfACF.MaxHealth and SelfACF.MaxHealth > 0 then
        return math.Clamp(SelfACF.Health / SelfACF.MaxHealth, 0, 1)
    end

    return 1
end

-- hp the linked engines are rated for: their peak power (ACF's own number for each engine), added up. Display only (the hover text). [CHANGED 3]
function ENT:GetEnginesRatedHP()
    local total = 0

    for Engine in pairs(self.Engines) do
        if IsValid(Engine) and Engine.PeakPower then total = total + ACFLazers.GetGenHP(Engine.PeakPower) end
    end

    return total
end

-- The one-line state for the hover text.
function ENT:UpdateStatus(draw, room, running)
    if next(self.Engines) == nil then
        self.Status = "No engine linked"
    elseif next(self.Caps) == nil then
        self.Status = "No capacitor linked (nothing to store the energy in)"
    elseif room <= 0 and self.Refusing > 0 then
        self.Status = "AllowCharge is off on the capacitors (nothing is taken from the engines)"
    elseif room <= 0 then
        self.Status = "Capacitors full (nothing is taken from the engines)"
    elseif draw <= 0 then
        self.Status = "Draw is 0 (nothing is taken from the engines)"
    elseif running == 0 then
        self.Status = "Engines are off or have no throttle"
    elseif self.OfferedHP > self.RatedHP * 1.01 then
        self.Status = string.format("At its %d hp rating (the linked engines are rated %.0f hp, the extra is ignored): generating %.0f kJ/s", self.RatedHP, self:GetEnginesRatedHP(), self.EnergyRate)
    else
        self.Status = string.format("Generating %.0f kJ/s", self.EnergyRate)
    end
end

-- ===================== WIRE + OVERLAY =====================

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    WireLib.TriggerOutput(self, "Energy", self.EnergyRate)
    WireLib.TriggerOutput(self, "HP", self.PowerHP)
    WireLib.TriggerOutput(self, "Rated", self.RatedHP)
    WireLib.TriggerOutput(self, "Load", self.RatedHP > 0 and self.PowerHP / self.RatedHP * 100 or 0)
    WireLib.TriggerOutput(self, "Engines", self:CountEngines())
    WireLib.TriggerOutput(self, "Full", (next(self.Caps) ~= nil and self.Room <= 0 and self.Refusing == 0) and 1 or 0)
end

-- The hover text (ACF's overlay system calls this; ENT:UpdateOverlay() asks it to refresh).
function ENT:ACF_UpdateOverlayState(State)
    local linkedEngines, linkedCaps = self:CountEngines(), 0

    for _ in pairs(self.Caps) do linkedCaps = linkedCaps + 1 end

    if linkedEngines > 0 and self.EnergyRate > 0 then
        State:AddSuccess(self.Status)
    elseif linkedEngines == 0 or linkedCaps == 0 then
        State:AddWarning(self.Status)
    else
        State:AddLabel(self.Status)
    end

    State:AddKeyValue("Rated power", string.format("%d hp (model scale %.2f)", self.RatedHP, ACFLazers.GetGenScale(self.RatedHP)))
    State:AddKeyValue("Taking from engines", string.format("%.0f hp (%.0f%% of the rating)", self.PowerHP, self.RatedHP > 0 and self.PowerHP / self.RatedHP * 100 or 0))
    State:AddKeyValue("Making", string.format("%.0f kJ/s", self.EnergyRate))
    State:AddKeyValue("Health efficiency", string.format("%.0f%% (x%.2f energy per hp)", self.Efficiency * 100, self.Efficiency))
    State:AddKeyValue("Draw input", string.format("%.0f%%", self:GetDraw() * 100))
    State:AddKeyValue("Linked", string.format("%d engine(s), %d capacitor(s)", linkedEngines, linkedCaps))

    if linkedCaps > 0 then
        local charge, capacity = 0, 0

        for _, cap in ipairs(self:GetPool()) do
            if IsValid(cap) then
                charge   = charge + cap.Charge
                capacity = capacity + cap.Capacity
            end
        end

        State:AddKeyValue("Capacitors", string.format("%.0f / %.0f kJ", charge, capacity))
    end
end

-- Refresh the hover text, but only when something worth showing changed (ACF's overlay networks changes).
function ENT:RefreshOverlay()
    local signature = self.Status .. "|" .. math.floor(self.PowerHP / 10) .. "|" .. self:CountEngines() .. "|" .. math.floor(self:GetDraw() * 100) .. "|" .. math.floor(self.Efficiency * 100)

    if signature ~= self.OverlaySig then
        self.OverlaySig = signature
        self:UpdateOverlay()
    end
end

-- ===================== THINK =====================

function ENT:Think()
    local now = CurTime()
    local dt  = math.Clamp(now - self.LastThink, 0, CFG.GenMaxDeltaTime)

    self.LastThink = now

    if dt > 0 then self:Run(now, dt) end

    self:NextThink(now + engine.TickInterval()) -- one pass per server tick, like ACF's engine [SEEN acf_engine/init.lua:757]

    return true
end

-- ===================== LINKING =====================
-- engine <-> generator and generator <-> capacitor use ACF's link system, like the lazer <-> capacitor link does. The tools call  a:Link(b)  and  a:Unlink(b).
-- (A link made from either side works: ACF tries the registered pair in both orders.)

ACF.RegisterLinkSource("acf_generator", "Engines")
ACF.RegisterLinkSource("acf_generator", "Caps")

ACF.RegisterClassLink("acf_engine", "acf_generator", function(Engine, Gen)
    if Gen.Engines[Engine] then return false, "This engine is already linked to this generator." end
    if Gen:CountEngines() >= CFG.GenMaxEngines then return false, string.format("This generator already has %d engines linked (the most it can have).", CFG.GenMaxEngines) end

    local ok, why, length = Gen:CheckEngine(Engine, nil)

    if not ok then return false, "Cannot link: " .. tostring(why) end

    Gen.Engines[Engine] = { RopeLen = length, Time = CurTime(), HP = 0 }
    Gen.ListDirty       = true

    Engine.ACFGenerators = Engine.ACFGenerators or {}
    Engine.ACFGenerators[Gen] = true

    -- an engine that is removed while linked must leave the generator's tables [same idea as acf_gearbox LinkWheel's CallOnRemove]
    Engine:CallOnRemove("ACFGenLink" .. Gen:EntIndex(), function()
        if IsValid(Gen) then Gen:ForgetEngine(Engine) end
    end)

    Gen:SyncRopes()
    Gen:UpdateOverlay(true)

    return true, "Engine linked to the generator."
end)

ACF.RegisterClassUnlink("acf_engine", "acf_generator", function(Engine, Gen)
    if not Gen.Engines[Engine] then return false, "This engine is not linked to this generator." end

    Gen:ForgetEngine(Engine)
    Gen:UpdateOverlay(true)

    return true, "Engine unlinked from the generator."
end)

ACF.RegisterClassLink("acf_generator", "acf_capacitor", function(Gen, Cap)
    if Gen.Caps[Cap] then return false, "This generator is already linked to this capacitor." end

    Gen.Caps[Cap]        = true
    Cap.Generators       = Cap.Generators or {}
    Cap.Generators[Gen]  = true

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1 -- every pool rebuilds the next time it is needed

    Gen:UpdateOverlay(true)
    Cap:UpdateOverlay(true)

    return true, "Generator linked to the capacitor."
end)

ACF.RegisterClassUnlink("acf_generator", "acf_capacitor", function(Gen, Cap)
    if not (Gen.Caps[Cap] or (Cap.Generators and Cap.Generators[Gen])) then return false, "This generator is not linked to this capacitor." end

    Gen.Caps[Cap] = nil

    if Cap.Generators then Cap.Generators[Gen] = nil end

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    Gen:UpdateOverlay(true)
    Cap:UpdateOverlay(true)

    return true, "Generator unlinked from the capacitor."
end)

-- Breaks every link this generator has. Returns how many it broke. (The link tools' reload uses it.)
function ENT:UnlinkAll()
    local count = 0

    for Engine in pairs(self.Engines) do
        if IsValid(Engine) and self:Unlink(Engine) then
            count = count + 1
        else
            self:ForgetEngine(Engine)
        end
    end

    for Cap in pairs(self.Caps) do
        if IsValid(Cap) and self:Unlink(Cap) then
            count = count + 1
        else
            self.Caps[Cap] = nil
        end
    end

    return count
end

function ENT:OnRemove()
    -- Straight table clean-up instead of ACF.PerformClassUnlink: the entity is on its way out and we only need everybody to forget it.
    for Engine in pairs(self.Engines) do
        self:ForgetEngine(Engine)
    end

    for Cap in pairs(self.Caps) do
        if IsValid(Cap) and Cap.Generators then Cap.Generators[self] = nil end
    end

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
end

-- ===================== UPDATE, SPAWN, DUPES =====================

-- Click-to-update (Entities.Update calls this). Same shape as the capacitor's.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Generator updated successfully!"
end

-- Duplicator: the linked engines' and capacitors' ids are saved and linked again on paste (the same way the lazer and the capacitor do it). The links are checked again when
-- they are made, so an engine that no longer fits where the dupe lands just does not link.
function ENT:PreEntityCopy()
    local engines, caps = {}, {}

    for Engine in pairs(self.Engines) do
        if IsValid(Engine) then engines[#engines + 1] = Engine:EntIndex() end
    end

    for Cap in pairs(self.Caps) do
        if IsValid(Cap) then caps[#caps + 1] = Cap:EntIndex() end
    end

    if #engines > 0 then duplicator.StoreEntityModifier(self, "ACFGenEngines", engines) end
    if #caps > 0 then duplicator.StoreEntityModifier(self, "ACFGenCaps", caps) end

    self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
    local mods = Ent.EntityMods

    if mods and mods.ACFGenEngines then
        for _, id in pairs(mods.ACFGenEngines) do
            local other = CreatedEntities[id]

            if IsValid(other) then self:Link(other) end
        end

        mods.ACFGenEngines = nil
    end

    if mods and mods.ACFGenCaps then
        for _, id in pairs(mods.ACFGenCaps) do
            local other = CreatedEntities[id]

            if IsValid(other) then self:Link(other) end
        end

        mods.ACFGenCaps = nil
    end

    self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

-- Signature (Player, Pos, Angle, Data) is what Entities.Register wants (registration.lua:1007).
function MakeACFGenerator(ply, pos, angles, Data)
    if not istable(Data) then Data = {} end

    if IsValid(ply) and not ply:CheckLimit("acf_generators") then return nil end

    -- The model is your buddy's. If it is missing the scalable base cannot build a physics mesh, so say so instead of failing with a pile of errors.
    if not util.IsValidModel(CFG.GenModel) then
        local msg = "[acf_generator] the model " .. CFG.GenModel .. " is missing on this server (GenModel in acf_lazers_config.lua). Is it installed and is the file name spelled right?"

        ErrorNoHalt(msg .. "\n")

        if IsValid(ply) then ply:ChatPrint(msg) end

        return nil
    end

    local ent = ents.Create("acf_generator")
    if not IsValid(ent) then return nil end

    -- ACF wants this table and a model BEFORE Spawn (acf_gun/init.lua:482-488)
    ent.ACF = {}
    Contraption.SetModel(ent, CFG.GenModel)

    ent:SetPos(pos)
    ent:SetAngles(angles)

    ent:Spawn()
    ent:Activate()

    ent:ApplyData(Data)

    if IsValid(ply) then
        if ent.SetPlayer then ent:SetPlayer(ply) end
        if CPPI then ent:CPPISetOwner(ply) end
        ply:AddCount("acf_generators", ent)
        ply:AddCleanup("acf_generators", ent)
    end

    return ent
end

-- Dupe key: RatedHP.
Entities.Register("acf_generator", MakeACFGenerator, "RatedHP")
