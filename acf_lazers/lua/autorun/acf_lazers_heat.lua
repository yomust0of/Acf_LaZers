-- =========================================================================
-- ACF LAZERS: HEAT STORE (server only)
-- Goes to:  lua/autorun/acf_lazers_heat.lua
--           (a NEW file: game folder and server. It must sit next to acf_lazers_config.lua; the lazer, capacitor and generator files of this batch refuse to load without it)
--
-- Keeps the heat of every entity that is warmer than room temperature, and cools it down. Entities at room temperature have NO record, so a map full of props costs nothing.
--   * the heat is stored as kJ above room temperature in two fields on the entity:  ent.ACFL_HeatKJ  (the amount, as of ent.ACFL_HeatT)  and  ent.ACFL_HeatT  (a CurTime())
--   * cooling is worked out only when somebody READS or CHANGES the heat: it uses the exact solution of the cooling law (ACFLazers.HeatCool, config), so a long gap costs the same as a short
--     one. A sweep every HeatSweepInterval seconds forgets entities that cooled down (and entities that were removed). Nothing thinks per entity.
--   * all the numbers are in the config (everything starting with Heat...). The maths helpers are in the config too (ACFLazers.HeatCool, GetHeatCapacity ...)
-- Console commands:  acf_lazers_heat_info   (anyone: prints the heat of what you are looking at)     acf_lazers_heat_set <F>   (admins: sets it to that temperature, a test aid)
-- 15.2 (search for [CHANGED 1]): the radiator tool asks this file for the temperature of the plain part you look at (two network messages, answered one entity at a time).
-- =========================================================================

if not SERVER then return end

ACFLazers = ACFLazers or {}

local CFG = ACFLazers.Config

if not (CFG and ACFLazers.HeatCool and ACFLazers.GetHeatCapacity) then
    ErrorNoHalt("[acf_lazers_heat] lua/autorun/acf_lazers_config.lua is missing or older than this file (it has no ACFLazers.HeatCool). Copy the config of the same batch.\n")
    return
end

-- Kept across Lua refreshes on purpose: the entity files hold a reference to this table.
ACFLazers.Heat = ACFLazers.Heat or {}

local Heat = ACFLazers.Heat

Heat.Registry = Heat.Registry or setmetatable({}, { __mode = "k" }) -- every entity that has a record (weak: a removed entity drops out by itself)

-- ===================== READING =====================

--- Mass in kg: the physics object's mass, else ACF's own record of it, else nothing (the config's HeatMinMassKg floor applies in GetHeatCapacity).
function Heat.GetMass(ent)
    local mass

    if ent.GetPhysicsObject then
        local phys = ent:GetPhysicsObject()

        if IsValid(phys) and phys.GetMass then mass = phys:GetMass() end
    end

    if not mass and ent.ACF then mass = ent.ACF.Mass end

    return tonumber(mass) or 0
end

--- kJ per kelvin of this entity.
function Heat.GetCapacity(ent)
    return ACFLazers.GetHeatCapacity(Heat.GetMass(ent))
end

--- How fast this kind of entity cools relative to a prop (config): lazers have their own number, every other ACF entity another, everything else 1.
function Heat.GetCoolMult(ent)
    local class = ent.GetClass and ent:GetClass() or ""

    if class == "acf_lazer" then return CFG.HeatCoolMultLazer end
    if string.sub(class, 1, 4) == "acf_" then return CFG.HeatCoolMultACF end

    return 1
end

--- Brings the record up to `now`: cools it for the time that passed. Returns the kJ above room temperature (0 when there is no record).
local function Settle(ent, now)
    local kj = ent.ACFL_HeatKJ

    if not kj then return 0 end

    local dt = now - (ent.ACFL_HeatT or now)

    if dt > 0 then
        local capacity = Heat.GetCapacity(ent)

        kj = ACFLazers.HeatCool(kj / capacity, dt, Heat.GetCoolMult(ent)) * capacity
        ent.ACFL_HeatKJ = kj
        ent.ACFL_HeatT  = now
    end

    return kj
end

--- kJ above room temperature right now.
function Heat.GetKJ(ent)
    if not (ent and ent.ACFL_HeatKJ and IsValid(ent)) then return 0 end

    return Settle(ent, CurTime())
end

--- Kelvin above room temperature right now.
function Heat.GetRiseK(ent)
    local kj = Heat.GetKJ(ent)

    if kj <= 0 then return 0 end

    return kj / Heat.GetCapacity(ent)
end

--- Temperature right now, in kelvin and in Fahrenheit.
function Heat.GetTempK(ent) return ACFLazers.GetHeatAmbientK() + Heat.GetRiseK(ent) end
function Heat.GetTempF(ent) return ACFLazers.KToF(Heat.GetTempK(ent)) end

--- How hot as a fraction of a limit: 0 = room temperature, 1 = the limit, 2 = twice as far above room temperature as the limit. riseK = the limit in kelvin above room temperature
--- (ACFLazers.GetHeatRiseHot / GetHeatRiseLazer / GetHeatRiseCap).
function Heat.GetPct(ent, riseK)
    return Heat.GetRiseK(ent) / math.max(riseK, 1e-6)
end

--- How hot as a fraction of the HOT temperature (a plate's 100%).
function Heat.GetPctHot(ent) return Heat.GetPct(ent, ACFLazers.GetHeatRiseHot()) end

--- Is it HOT (at or above the HOT temperature)? This is what a plate needs to be burned through.
function Heat.IsHot(ent) return Heat.GetPctHot(ent) >= 1 end

-- ===================== CHANGING =====================

local function Register(ent) Heat.Registry[ent] = true end

--- Adds (or, with a negative number, removes) kJ of heat. Never goes below room temperature. Returns the kJ it holds now.
function Heat.Add(ent, kJ)
    if not IsValid(ent) then return 0 end

    kJ = tonumber(kJ) or 0

    if kJ ~= kJ or kJ == 0 then return Heat.GetKJ(ent) end -- NaN (the one number that is not equal to itself) and zero change nothing

    local now = CurTime()
    local kj  = math.max(Settle(ent, now) + kJ, 0)

    if kj <= 0 then
        ent.ACFL_HeatKJ, ent.ACFL_HeatT = nil, nil
        Heat.Registry[ent] = nil

        return 0
    end

    ent.ACFL_HeatKJ = kj
    ent.ACFL_HeatT  = now

    Register(ent)

    return kj
end

--- Sets the temperature in Fahrenheit (a test aid). At or under room temperature clears the record.
function Heat.SetF(ent, degF)
    if not IsValid(ent) then return end

    ent.ACFL_HeatKJ, ent.ACFL_HeatT = nil, nil
    Heat.Registry[ent] = nil

    local rise = ACFLazers.FToK(tonumber(degF) or 0) - ACFLazers.GetHeatAmbientK()

    if rise > 0 then Heat.Add(ent, rise * Heat.GetCapacity(ent)) end
end

-- ===================== DAMAGE FROM HEAT =====================

--- Who gets the blame for heat damage: the owner (so the safezone / damage-mode rules treat it like any other hit by that player), else the entity itself.
function Heat.GetAttacker(ent)
    if ent.GetAttacker then
        local who = ent:GetAttacker()

        if IsValid(who) then return who end
    end

    local owner = ent.Owner

    if not IsValid(owner) and ent.CPPIGetOwner then owner = ent:CPPIGetOwner() end

    if IsValid(owner) then return owner end

    return ent
end

--- Hurts an entity for `hp` ACF health through ACF's own damage pipeline (its hooks, its permission check, its ACF_OnDamage if it has one). Returns ACF's result table
--- (Damage, Kill ...) or nil if nothing could be done. It never kills by itself: whoever calls it acts on result.Kill, exactly as with a bullet.
function Heat.Hurt(ent, hp)
    hp = tonumber(hp) or 0

    if hp ~= hp or hp <= 0 or not IsValid(ent) then return nil end

    local Damage = ACF and ACF.Damage -- looked up now, not when this file loaded

    if not (Damage and Damage.dealDamage and Damage.Objects and Damage.Objects.DamageResult and Damage.Objects.DamageInfo) then return nil end

    local result = Damage.Objects.DamageResult(1, 1, 1, 0, 1, 1)
    local pos    = ent:GetPos()

    result:SetDamage(hp) -- ACF's own "custom damage" slot: Compute() returns exactly this

    local info = Damage.Objects.DamageInfo(Heat.GetAttacker(ent), ent, DMG_BURN, pos, pos, 0)
    local ok, res = pcall(Damage.dealDamage, ent, result, info)

    if not ok then
        if CurTime() >= (Heat.NextErrorPrint or 0) then
            Heat.NextErrorPrint = CurTime() + 5
            ErrorNoHalt("[acf_lazers_heat] ACF's damage call failed for heat damage: " .. tostring(res) .. "\n")
        end

        return nil
    end

    return res, info
end

-- ===================== SWEEP =====================
-- Every HeatSweepInterval seconds: forget what was removed, cool the rest, and forget what is back at room temperature.

function Heat.Sweep()
    local now = CurTime()

    for ent in pairs(Heat.Registry) do
        if not IsValid(ent) then
            Heat.Registry[ent] = nil
        else
            local kj = Settle(ent, now)

            if kj <= 0 or kj / Heat.GetCapacity(ent) < CFG.HeatForgetBelowK then
                ent.ACFL_HeatKJ, ent.ACFL_HeatT = nil, nil
                Heat.Registry[ent] = nil
            end
        end
    end
end

timer.Create("ACFLazers_HeatSweep", math.max(CFG.HeatSweepInterval, 0.5), 0, function() Heat.Sweep() end)

-- ===================== THE READOUT FOR PLAIN PARTS ===================== [CHANGED 1]
-- A plain prop has no hover text (ACF's popups exist only for ACF entities), so the radiator tool asks for the temperature of the part you look at: the client sends the entity, the
-- server answers with its numbers (Fahrenheit; the client converts for its Celsius switch). Nothing is networked for parts nobody looks at. A player who asks faster than half the
-- RadReadoutInterval, or about something far away, gets no answer.
util.AddNetworkString("ACFLazers_HeatQuery")
util.AddNetworkString("ACFLazers_HeatReply")

net.Receive("ACFLazers_HeatQuery", function(_, ply)
    if not IsValid(ply) then return end

    local now = CurTime()

    if now < (ply.ACFL_NextHeatQuery or 0) then return end

    ply.ACFL_NextHeatQuery = now + math.max(CFG.RadReadoutInterval, 0.05) * 0.5

    local ent = net.ReadEntity()

    if not IsValid(ent) or ent:IsWorld() or ent:IsPlayer() then return end

    local eye   = ply:EyePos()
    local reach = CFG.RadReadoutDistance * 2 + 64 -- slack: the client measures to where its trace hit, the server to the nearest point of the entity

    if ent:NearestPoint(eye):DistToSqr(eye) > reach * reach then return end

    net.Start("ACFLazers_HeatReply")
    net.WriteEntity(ent)
    net.WriteFloat(Heat.GetKJ(ent))
    net.WriteFloat(Heat.GetTempF(ent))
    net.WriteFloat(Heat.GetPctHot(ent))
    net.WriteFloat(Heat.GetMass(ent))
    net.Send(ply)
end)

-- ===================== CONSOLE COMMANDS =====================

local function Say(ply, text)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, text .. "\n") else Msg(text .. "\n") end
end

-- The entity the player is looking at (a plain trace: it ignores the player; no ACF detour involved).
local function Aimed(ply)
    if not IsValid(ply) then return nil end

    local from = ply:EyePos()
    local tr   = util.TraceLine({ start = from, endpos = from + ply:GetAimVector() * CFG.HeatInfoDistance, filter = ply })

    if tr and tr.Hit and IsValid(tr.Entity) and not tr.HitWorld then return tr.Entity end

    return nil
end

concommand.Add("acf_lazers_heat_info", function(ply)
    local ent = Aimed(ply)

    if not ent then
        Say(ply, "[heat] look at an entity (within " .. CFG.HeatInfoDistance .. " units) and run this again.")

        return
    end

    local kj      = Heat.GetKJ(ent)
    local mass    = Heat.GetMass(ent)
    local degF    = Heat.GetTempF(ent)
    local ambient = ACFLazers.KToF(ACFLazers.GetHeatAmbientK())
    local parts   = {
        string.format("%s #%d", ent:GetClass(), ent:EntIndex()),
        string.format("mass %.0f kg", mass),
        string.format("%.0f F (room %.0f F)", degF, ambient),
        string.format("heat %.0f kJ above room", kj),
        string.format("%.0f%% of HOT (%.0f F)", Heat.GetPctHot(ent) * 100, CFG.HeatHotF),
    }

    if ent:GetClass() == "acf_lazer" then
        parts[#parts + 1] = string.format("%.0f%% of its lazer limit (%.0f F)", Heat.GetPct(ent, ACFLazers.GetHeatRiseLazer()) * 100, CFG.HeatLazerCapF)
        parts[#parts + 1] = ent.HeatCooling and "COOLING (unavailable)" or (ent.HeatHot and "marked overheated" or "not marked")
    elseif ent:GetClass() == "acf_capacitor" then
        parts[#parts + 1] = string.format("%.0f%% of its critical heat", Heat.GetPct(ent, ACFLazers.GetHeatRiseCap()) * 100)
    end

    Say(ply, "[heat] " .. table.concat(parts, "  |  "))
end, nil, "Prints the heat of the entity you are looking at to your console")

concommand.Add("acf_lazers_heat_set", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then
        Say(ply, "[heat] only admins can set a temperature")

        return
    end

    local degF = tonumber(args[1])

    if not degF then
        Say(ply, "[heat] usage: acf_lazers_heat_set <degrees Fahrenheit>   (look at the entity; room temperature or lower clears its heat)")

        return
    end

    local ent = Aimed(ply)

    if not ent then
        Say(ply, "[heat] look at an entity first.")

        return
    end

    Heat.SetF(ent, degF)
    Say(ply, string.format("[heat] %s #%d is now %.0f F", ent:GetClass(), ent:EntIndex(), Heat.GetTempF(ent)))
end, nil, "Admins: sets the temperature (Fahrenheit) of the entity you are looking at. A test aid")
