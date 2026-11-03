-- =========================================================================
-- THE FLAMETHROWER'S PROJECTILE  (22; 22.1: the fire sprites widen with the sphere, the drag is 40 x a shell's)
-- Goes to:  lua/acf/entities/ammo_types/lazers_flame.lua      (NEW FILE. ACF loads every file of that folder in every addon, server and client, with no AddCSLuaFile needed)
--
-- An ACF "ammo type" is the rulebook of one kind of projectile: what happens when it hits something and how it is drawn. This one is only ever fired by the flamethrower (acf_flamer names it on every
-- projectile: ACFLazers.FlameAmmoID). It is blacklisted for every ACF weapon, so it never shows up in an ammo crate's menu.
--
--   * Flight: ACF's own, with GRAVITY and DRAG (FlameDragMult times an ordinary shell's; 40 since 22.1), and a KillTime: ACF deletes the projectile FlameLifetime (3) seconds after the shot, before anything else
--     is looked at, so the three seconds always win.
--   * THE SPHERE. Every step of the flight (ACF calls Ammo.FlameFlightStep after each one) the projectile sweeps an invisible sphere along the path it just flew. The sphere is FlameSphereStart (16)
--     units across when it leaves the gun and grows in a straight line to FlameSphereGrow (3) times that at the end of its life. It is as wide at the touch as it is old; the path is swept (not only
--     the end point) so a fast projectile cannot jump over a thin plate. A thing is "touched" when the swept sphere reaches its bounding box (the box of the entity, in its own turned space).
--   * WHAT IT TOUCHES, once per projectile each (a projectile heats a given part once, not once per step):
--       - a PART (a prop or any other ACF entity that is not a person): heat of FlameHeatSmall .. Big PERCENT OF HOT, fire for FlameIgniteSmall .. Big seconds, and, when the part is at or over
--         FlameDamageHeatPct percent of HOT, FlameHPSmall .. Big points of ACF health (through ACF's own damage call, so its permissions and hooks apply; a part it kills is destroyed the way a bullet
--         destroys it). The first part touched starts the FlameLinger (0.05 s) clock: the projectile ends then (an ACF "fuze"), so the flame does not go through a vehicle.
--         A plain prop (not an "acf_" entity) that is on fire from this cools FlameCoolMult as fast (lua/autorun/acf_lazers_heat.lua).
--       - a PERSON (ACF's "Squishy": players, NPCs): FlamePlayerDamageSmall .. Big damage and the same fire. The projectile goes on.
--     The projectile's thin ray (ACF's flight) looks through people (hook ACF_OnFilterBullet below), so it only ever ends on a part, the ground or its lifetime.
--     NOT touched: the shooter's own contraption (the projectile's filter, copied from the contraption at the muzzle; a player sitting in it is not touched either), anything in a safezone, anything
--     ACF's damage permissions refuse, anything a listener of the hook ACFLazers_CanFlame (ent, gun) answers false for.
--   * The end of the flight on the ground or a wall: one more touch test where it ended, then the projectile is removed.
--   * THE PICTURE (client, below): a trail of fire sprites, an optional loop of sound on every Nth projectile, a little burst where it ends, and, with the console command acf_lazers_flame_sphere 1,
--     the sphere drawn as a wireframe (green while it flies, red where it ended).
-- =========================================================================

local ACF       = ACF
local Classes   = ACF.Classes
local AmmoTypes = Classes.AmmoTypes
local Clock     = ACF.Utilities.Clock

local ID   = (ACFLazers and ACFLazers.FlameAmmoID) or "LazerFlame"
local Ammo = AmmoTypes.Register(ID, "AP")

function Ammo:OnLoaded()
    Ammo.BaseClass.OnLoaded(self)

    self.Name        = "Flame"
    self.Description = "The projectile of an ACF flamethrower. Made only by a flamethrower."
    self.Blacklist   = ACF.GetWeaponBlacklist({}) -- every weapon: not in any ammo menu
end

-- No penetration: the flame does its work with the sphere.
function Ammo:GetPenetration()
    return 0
end

if SERVER then
    local Damage = ACF.Damage

    -- Everything the projectile's RAY touches ends its flight: ACF asks the ammo type what to do on a hit, and "false" means "nothing special, the flight is over" (OnFlightEnd below).
    function Ammo:PropImpact()
        return false
    end

    function Ammo:WorldImpact()
        return false
    end

    local function Number(name)
        return ACFLazers.FlameNumber(name)
    end

    -- Did the flamethrower stand in a safezone when it fired (the projectile carries the answer: FlameSafe), or does it stand in one now (if it is still there)?
    local function ShooterProtected(Bullet)
        if Bullet.FlameSafe then return true end

        local Now = Clock.CurTime

        if Now >= (Bullet.FlameSafeCheck or 0) then -- (looked at twice a second, not every step: the answer rarely changes)
            local Gun = Bullet.Gun

            Bullet.FlameSafeCheck = Now + 0.5
            Bullet.FlameSafeNow   = IsValid(Gun) and ACFLazers.IsProtectedBySafezone(Gun) or false
        end

        return Bullet.FlameSafeNow
    end

    -- The projectile's filter as a set (made once, from the list the flamethrower copied from its contraption).
    local function FilterSet(Bullet)
        local Set = Bullet.FlameFilterSet

        if not Set then
            Set = {}

            for _, Ent in ipairs(Bullet.Filter or {}) do Set[Ent] = true end

            Bullet.FlameFilterSet = Set
        end

        return Set
    end

    -- Ask ACF whether the shooter may damage this thing, the very question ACF's own dealDamage asks first (the "ACF_PreDamageEntity" hook: safezones, damage modes, prop protection). A failing
    -- lookup counts as "yes"; only an answer of false says no.
    local function Permitted(Bullet, Ent)
        local Objects = Damage and Damage.Objects

        if not (Objects and Objects.DamageResult and Objects.DamageInfo) then return true end

        local Ok, Answer = pcall(function()
            local Result = Objects.DamageResult(1, 1, 1, 0, 1, 1)
            local Pos    = Ent:GetPos()
            local Info   = Objects.DamageInfo(IsValid(Bullet.Owner) and Bullet.Owner or Bullet.Gun, Bullet.Gun, DMG_BURN, Pos, Pos, 0)

            return hook.Run("ACF_PreDamageEntity", Ent, Result, Info)
        end)

        return not (Ok and Answer == false)
    end

    local function Allowed(Bullet, Ent)
        if ACFLazers.IsProtectedBySafezone(Ent) then return false end
        if hook.Run("ACFLazers_CanFlame", Ent, Bullet.Gun) == false then return false end

        return Permitted(Bullet, Ent)
    end

    -- Entity:Ignite restarts a fire each time it is called; once in half a second is plenty.
    local function IgniteThrottled(Ent, Seconds)
        local Now = CurTime()

        if (Ent.ACFLazers_NextFlameIgnite or 0) > Now then return end

        Ent.ACFLazers_NextFlameIgnite = Now + 0.5

        Ent:Ignite(Seconds)
    end

    -- A PERSON: damage and fire, and the projectile goes on.
    local function TouchPerson(Bullet, Ent)
        if Ent.Alive and not Ent:Alive() then return end
        if Ent.Health and Ent:Health() <= 0 then return end
        if not Allowed(Bullet, Ent) then return end

        local Caliber = Bullet.FlameCaliber
        local Dealt   = ACFLazers.GetFlamePlayerDamage(Caliber)

        if Dealt > 0 then
            local Info = DamageInfo()

            Info:SetDamage(Dealt)
            Info:SetAttacker(IsValid(Bullet.Owner) and Bullet.Owner or Bullet.Gun)
            Info:SetInflictor(IsValid(Bullet.Gun) and Bullet.Gun or game.GetWorld())
            Info:SetDamageType(DMG_BURN)

            Ent:TakeDamageInfo(Info)
        end

        if IsValid(Ent) then
            local Seconds = ACFLazers.GetFlameIgniteSeconds(Caliber)

            if Seconds > 0 and (not Ent.Alive or Ent:Alive()) then IgniteThrottled(Ent, Seconds) end
        end

        return true
    end

    -- A PART: heat, fire, and (over the threshold) health; the first one starts the linger clock. Returns true if it was touched (false = refused).
    local function TouchPart(Bullet, Ent)
        if Ent.ACF_Killed or Ent.Exploding then return end
        if not Allowed(Bullet, Ent) then return end

        local Heat    = ACFLazers.Heat
        local Caliber = Bullet.FlameCaliber
        local Seconds = ACFLazers.GetFlameIgniteSeconds(Caliber)

        if Heat then
            if Seconds > 0 and Heat.SetFire then Heat.SetFire(Ent, Seconds) end

            local KJ = ACFLazers.GetFlameHeatKJ(ACFLazers.GetFlameHeatPct(Caliber), Heat.GetCapacity(Ent))

            if KJ > 0 then Heat.Add(Ent, KJ) end
        end

        if Seconds > 0 and ACFLazers.FlameFlag("FlameIgniteProps") then IgniteThrottled(Ent, Seconds) end

        -- over the threshold: ACF health, through ACF's own damage call (Heat.Hurt), and a part it kills is destroyed the way ACF destroys what a bullet killed
        if Heat and Heat.GetPctHot and Heat.GetPctHot(Ent) * 100 >= Number("FlameDamageHeatPct") then
            local HP = ACFLazers.GetFlameHP(Caliber)

            if HP > 0 then
                local Res, Info = Heat.Hurt(Ent, HP)

                if Res and Res.Kill and IsValid(Ent) then
                    local Power = math.min(Number("FlameKillDebrisPower"), ACFLazers.Config.MaxDebrisPower or 65535)

                    ACF.APKill(Ent, Bullet.Flight:GetNormalized(), Power, Info)
                end
            end
        end

        -- the first part ends the projectile FlameLinger seconds later (an ACF fuze: an absolute time once the bullet exists). The lifetime still comes first (KillTime).
        if not Bullet.FlameFuzed then
            Bullet.FlameFuzed = true
            Bullet.Fuze       = Clock.CurTime + math.max(Number("FlameLinger"), 0)
        end

        return true
    end

    -- One thing the swept sphere may touch? (Everything cheap that rules it out comes first.)
    local function Candidate(Bullet, Ent, Set)
        if not IsValid(Ent) or Ent == Bullet.Gun then return false end
        if Bullet.FlameHit[Ent] or Set[Ent] then return false end
        if ACF.GlobalFilter and ACF.GlobalFilter[Ent:GetClass()] then return false end
        if Ent.ACF_InvisibleToBallistics then return false end

        return true
    end

    -- Sweep the sphere along from -> to (the radius is the one of the projectile's age right now) and touch what it reaches.
    local function Sweep(Bullet, From, To)
        if ShooterProtected(Bullet) then return end

        local Radius = ACFLazers.GetFlameSphereDiameter(Clock.CurTime - (Bullet.FlameStart or Clock.CurTime)) * 0.5
        local Mid    = (From + To) * 0.5
        local Reach  = (To - From):Length() * 0.5 + Radius + 8 -- (ents.FindInSphere finds the entities whose bounding box reaches the sphere: this holds every candidate)
        local Set    = FilterSet(Bullet)

        for _, Ent in ipairs(ents.FindInSphere(Mid, Reach)) do
            if Candidate(Bullet, Ent, Set) then
                local A, B = Ent:WorldToLocal(From), Ent:WorldToLocal(To)

                if ACFLazers.SegmentTouchesBox(A.x, A.y, A.z, B.x, B.y, B.z, Ent:OBBMins(), Ent:OBBMaxs(), Radius) then
                    Bullet.FlameHit[Ent] = true -- touched (or refused, or not an ACF thing): it is not looked at again by this projectile

                    local Type = ACF.Check(Ent)

                    if Type == "Squishy" then
                        -- a person sitting in the shooter's own vehicle is part of the shooter's contraption
                        if not (Ent.InVehicle and Ent:InVehicle() and Set[Ent:GetVehicle()]) then TouchPerson(Bullet, Ent) end
                    elseif Type then
                        TouchPart(Bullet, Ent)
                    end
                end
            end
        end
    end

    -- ACF calls this after every step of the flight (it is the bullet's PostCalcFlight: the flamethrower puts it on the projectile). Bullet.Pos is where the step started, Bullet.NextPos where it ended.
    -- A step that ended the flight (the ray hit something) was already handled by OnFlightEnd below.
    function Ammo.FlameFlightStep(Bullet)
        if Bullet.Removed or Bullet.FlameEnded or not Bullet.NextPos then return end

        local Ok, Err = pcall(Sweep, Bullet, Bullet.Pos, Bullet.NextPos)

        if not Ok and CurTime() >= (Ammo.NextErrorPrint or 0) then
            Ammo.NextErrorPrint = CurTime() + 5
            ErrorNoHalt("[acf_flamer] the flame's touch test failed: " .. tostring(Err) .. "\n")
        end
    end

    -- THE RAY LOOKS THROUGH PEOPLE. ACF flies a projectile as a thin ray and ends the flight at the first thing the ray runs into, a person included. A flame must go on through people (their touch is
    -- done by the sphere), so for this projectile ACF is told, for each thing its ray meets, to look through it when it is a person. (ACF asks the hook "ACF_OnFilterBullet"; false = skip that
    -- thing: ACF puts it on the projectile's filter and flies on. ACF's own answer is a gamemode function that runs last, so ours wins. Every other projectile gets no answer from us.)
    hook.Add("ACF_OnFilterBullet", "ACFLazers_FlameThroughPeople", function(Ent, Bullet)
        if not Bullet or Bullet.Type ~= ID then return end

        if ACF.Check(Ent) == "Squishy" then return false end
    end)

    function Ammo:OnFlightEnd(Bullet, Trace)
        if not Bullet.FlameEnded and Bullet.Pos and Bullet.FlameHit then
            Bullet.FlameEnded = true

            -- one more touch test where it ended: on the ray's hit point, or, for the fuze, where the fuze put it
            local To = Bullet.Pos

            if not Bullet.DetByFuze and Trace and Trace.Hit and Trace.HitPos then To = Trace.HitPos end

            local Ok, Err = pcall(Sweep, Bullet, Bullet.Pos, To)

            if not Ok and CurTime() >= (Ammo.NextErrorPrint or 0) then
                Ammo.NextErrorPrint = CurTime() + 5
                ErrorNoHalt("[acf_flamer] the flame's touch test failed: " .. tostring(Err) .. "\n")
            end
        end

        Bullet.KillTime = Clock.CurTime

        Ammo.BaseClass.OnFlightEnd(self, Bullet, Trace) -- ACF's own: removes the projectile
    end
else
    -- =====================  THE PICTURE (client)  =====================
    -- Everything here is optional dressing around ACF's own bullet picture, and nothing here may throw: it would end the effect's Init (the hook runs inside it) before the lifetime below is set. If
    -- any part fails the projectile is simply drawn the plain ACF way.

    local Sphere = CreateClientConVar("acf_lazers_flame_sphere", "0", true, false, "1 = draw the flamethrower projectiles' touch spheres as wireframes (green while flying, red where they ended)")

    concommand.Add("acf_lazers_flame_sphere_toggle", function()
        RunConsoleCommand("acf_lazers_flame_sphere", Sphere:GetBool() and "0" or "1")
    end, nil, "Switches the display of the flamethrower projectiles' touch spheres on or off (same as acf_lazers_flame_sphere 1 / 0)")

    local Live  = {} -- [effect] = true: the pictures of the projectiles in flight
    local Ended = {} -- list of { pos, radius, untilTime }: the spheres of projectiles that ended, kept for a moment

    local GREEN, RED = Color(60, 255, 60, 255), Color(255, 60, 60, 255)
    local SHOW_ENDED = 0.6 -- seconds a finished sphere stays on screen

    local Emitters = {} -- [effect] = ParticleEmitter

    local function Now() return Clock.CurTime end

    local function FlameMaterial()
        local List = ACFLazers.FlameSoundList("FlameTrailMaterials")

        if #List == 0 then return nil end

        return List[math.random(#List)]
    end

    -- one flame sprite. Age = how old the projectile is (seconds) when the sprite is made. The fire widens exactly as the hit sphere does (22.1): the sprite starts as wide as the sphere was at that age
    -- (times FlameTrailSizeStart) and ends as wide as the sphere is at the age the sprite dies (times FlameTrailSizeEnd)
    local function Puff(Emitter, Pos, Age, Fast)
        local Material = FlameMaterial()

        if not Material then return end

        local P = Emitter:Add(Material, Pos)

        if not P then return end

        local Life = ACFLazers.FlameNumber("FlameTrailLife")
        local Die  = Life * (Fast and 0.7 or 1) * math.Rand(0.8, 1.2)

        P:SetDieTime(Die)
        P:SetStartAlpha(math.Clamp(ACFLazers.FlameNumber("FlameTrailAlpha"), 0, 255))
        P:SetEndAlpha(0)
        P:SetStartSize(ACFLazers.GetFlameSphereDiameter(Age) * ACFLazers.FlameNumber("FlameTrailSizeStart") * math.Rand(0.8, 1.2))
        P:SetEndSize(ACFLazers.GetFlameSphereDiameter(Age + Die) * ACFLazers.FlameNumber("FlameTrailSizeEnd") * math.Rand(0.8, 1.2))
        P:SetRoll(math.Rand(0, 360))
        P:SetRollDelta(math.Rand(-2, 2))
        P:SetColor(math.Clamp(ACFLazers.FlameNumber("FlameTrailColorR"), 0, 255), math.Clamp(ACFLazers.FlameNumber("FlameTrailColorG"), 0, 255), math.Clamp(ACFLazers.FlameNumber("FlameTrailColorB"), 0, 255))
        P:SetVelocity(VectorRand() * (Fast and 60 or 12))
        P:SetGravity(Vector(0, 0, 30))
        P:SetAirResistance(40)
        P:SetCollide(false)
    end

    local function Cleanup(Effect)
        Live[Effect] = nil

        local Emitter = Emitters[Effect]

        if Emitter then
            if IsValid(Emitter) then Emitter:Finish() end

            Emitters[Effect] = nil
        end

        if Effect.FlameSnd then
            Effect.FlameSnd:Stop()
            Effect.FlameSnd = nil
        end

        if IsValid(Effect.FlameSndEnt) then
            Effect.FlameSndEnt:Remove()
            Effect.FlameSndEnt = nil
        end
    end

    -- the diameter the server's sphere has at the age of the picture (FlameBorn is set in Decorate: CreateTime is moved to end the picture on time, so it cannot be the age)
    local function AgeOf(Effect)
        return Now() - (Effect.FlameBorn or Now())
    end

    local function Diameter(Effect)
        return ACFLazers.GetFlameSphereDiameter(AgeOf(Effect))
    end

    local Counter = 0

    local function Decorate(Effect, BulletData)
        local Crate = BulletData.Crate

        if not IsValid(Crate) then return end

        -- (1) the lifetime: ACF keeps a client picture for 45 seconds, whatever the server does. The server deletes the projectile after FlameLifetime, so the picture is told to stop then
        local Life = Crate:GetNW2Float("FlightLife", 0)

        if Life > 0 and Life < 45 and isnumber(Effect.CreateTime) then
            Effect.CreateTime = Effect.CreateTime + Life - 45 -- ACF's effect ends when CreateTime is more than 45 seconds old
        end

        Effect.FlameBorn = Now()

        -- (2) the trail, the sound and the sphere follow the movement ACF gives the picture every frame. The emitter comes FIRST: if it cannot be made (an error, or nothing returned), the rest is not
        -- touched and ACF draws the projectile its plain way, so there is always something to see.
        local Emitter = ParticleEmitter(Effect:GetPos(), false)

        if not Emitter then return end

        Emitters[Effect] = Emitter
        Live[Effect]     = BulletData

        -- (3) the picture of the projectile itself is not drawn: the trail is the picture
        Effect.Render = function() end

        Counter = Counter + 1

        local Every = math.max(math.floor(ACFLazers.FlameNumber("FlameProjSoundEvery")), 1)
        local Path  = ACFLazers.PickFlameSound("FlameProjSound")
        local Eye   = IsValid(LocalPlayer()) and LocalPlayer():EyePos()

        if Path and Counter % Every == 0 and Eye and Eye:DistToSqr(Effect:GetPos()) <= ACFLazers.FlameNumber("FlameProjSoundDist") ^ 2 then
            local Source = ClientsideModel("models/props_junk/PopCan01a.mdl", RENDERGROUP_OPAQUE)

            if IsValid(Source) then
                Source:SetNoDraw(true)
                Source:SetPos(Effect:GetPos())

                local Snd = CreateSound(Source, Path)

                if Snd then
                    Snd:SetSoundLevel(ACFLazers.FlameNumber("FlameProjLevel"))
                    Snd:PlayEx(math.Clamp(ACFLazers.FlameNumber("FlameProjVolume"), 0, 1), 100)

                    Effect.FlameSnd, Effect.FlameSndEnt = Snd, Source
                else
                    Source:Remove()
                end
            end
        end

        local BaseMove, BaseThink = Effect.ApplyMovement, Effect.Think

        if isfunction(BaseMove) then
            Effect.ApplyMovement = function(self, Bullet)
                BaseMove(self, Bullet)

                local Ok, Err = pcall(function()
                    local Emitter = Emitters[self]
                    local Pos     = Bullet.SimPos
                    local Last    = Bullet.SimPosLast or Pos
                    local Time    = Now()
                    local Dt      = Time - (self.FlameLast or Time)

                    self.FlameLast = Time

                    if IsValid(self.FlameSndEnt) then self.FlameSndEnt:SetPos(Pos) end

                    if Emitter and IsValid(Emitter) and Dt > 0 then
                        self.FlameCarry = (self.FlameCarry or 0) + Dt * ACFLazers.FlameNumber("FlameTrailPerSecond")

                        local Count = math.floor(self.FlameCarry)
                        local Age   = AgeOf(self)

                        self.FlameCarry = self.FlameCarry - Count

                        for I = 1, math.min(Count, 8) do
                            Puff(Emitter, LerpVector(I / Count, Last, Pos), Age, false)
                        end
                    end
                end)

                if not Ok and not Ammo.PicFailed then
                    Ammo.PicFailed = true
                    ErrorNoHalt("[acf_flamer] the flame picture failed: " .. tostring(Err) .. "\n")
                end
            end
        end

        if isfunction(BaseThink) then
            Effect.Think = function(self)
                local Alive = BaseThink(self)

                if not Alive then
                    -- the sphere stays on screen for a moment where it ended
                    local Bullet = Live[self]

                    if Bullet and Bullet.SimPos then
                        Ended[#Ended + 1] = { pos = Bullet.SimPos, radius = Diameter(self) * 0.5, untilTime = Now() + SHOW_ENDED }
                    end

                    Cleanup(self)
                end

                return Alive
            end
        end
    end

    hook.Add("ACF_OnCreateBulletEffect", "ACFLazers_FlamePicture", function(Effect, BulletData)
        if BulletData.AmmoType ~= ID then return end

        local Ok, Err = pcall(Decorate, Effect, BulletData)

        if not Ok then
            ErrorNoHalt("[acf_flamer] the flame picture could not be set up: " .. tostring(Err) .. "\n")
        end
    end)

    -- The end of the flight: a small burst of flame where it ended (ACF calls this when the server says the projectile is over).
    function Ammo:ImpactEffect(_, Bullet)
        pcall(function()
            local Emitter = ParticleEmitter(Bullet.SimPos, false)

            if not Emitter then return end

            local Age  = Now() - ((Bullet.Effect and Bullet.Effect.FlameBorn) or Now())
            local Size = ACFLazers.GetFlameSphereDiameter(Age)

            for _ = 1, 8 do Puff(Emitter, Bullet.SimPos + VectorRand() * Size * 0.25, Age, true) end

            Emitter:Finish()
        end)
    end

    -- the wireframe spheres (acf_lazers_flame_sphere 1)
    hook.Add("PostDrawTranslucentRenderables", "ACFLazers_FlameSphere", function(Depth, Skybox)
        if Skybox or not Sphere:GetBool() then
            if not Sphere:GetBool() then Ended = {} end

            return
        end

        local Time = Now()

        for Effect, Bullet in pairs(Live) do
            if IsValid(Effect) and Bullet.SimPos then
                render.DrawWireframeSphere(Bullet.SimPos, Diameter(Effect) * 0.5, 12, 12, GREEN, true)
            end
        end

        for I = #Ended, 1, -1 do
            local Gone = Ended[I]

            if Gone.untilTime < Time then
                table.remove(Ended, I)
            else
                render.DrawWireframeSphere(Gone.pos, Gone.radius, 12, 12, RED, true)
            end
        end
    end)
end
