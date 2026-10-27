-- =========================================================================
-- ACF LAZERS: SHARED CONFIG
-- Goes to:  lua/autorun/acf_lazers_config.lua
--           (same file in the game folder and on the server. The new lazer / capacitor / generator init.lua files REFUSE to load with the old config: they need the heat knobs and
--            ACFLazers.HeatCool from this one, and the new file lua/autorun/acf_lazers_heat.lua)
--
-- CHANGES vs the config of handoff 14 (everything since is listed, so this is right whether or not you applied 15, 15.1 and 15.2). Search this file for [CHANGED n].
--   1  THE HEAT KNOBS: one new block "HEAT" (everything starting with Heat...), between the generator hub and the linking tools. Temperatures are typed in Fahrenheit.
--   2  THE HEAT HELPERS: new pure-maths section "HEAT HELPERS" (cooling law, heat capacity from mass, the scalars along the size of a lazer / capacitor / generator, the lock-out
--      percent, the quadratic damage, the explosion filler). Nothing in it touches the game.
--   3  (15.1) LAZER HEAT x5: HeatLazerSmall and HeatLazerBig are 5 (were 1). A lazer makes five times as much heat per kJ it spends, and its beam heats props five times as fast (the beam's heat
--      is built from the same rate). To keep the props' heating as it was, set HeatHitSmall and HeatHitBig to 0.2.
--   4  (15.2) THE RADIATOR KNOBS: one new block "RADIATOR" (everything starting with Rad...), right after the heat block: model, width range, mass, reach, sap rate, overclock, waste, efficiency, damage,
--      timers and what the player sees (radius sphere, temperature readout).
--   5  (15.2) THE RADIATOR HELPERS: new pure-maths section "RADIATOR HELPERS" (size -> mass / radius / sap rate / waste, efficiency, the weighted fill that shares the cooling among the hot parts,
--      one step of a radiator pool, where a radiator's own heat settles, and the numbers the tool shows). Nothing in it touches the game.
--   6  (15.2) LinkClasses has acf_radiator, so every tool can select and link radiators.
--   7  (15.3) NATURAL COOLING TWICE AS FAST: HeatCoolTau 150 (was 300).
--   8  (15.3) THE LOCK-OUT IS GONE: a lazer fires whenever it has power, however hot it is. HeatLockStartPct, HeatLockEndPctSmall, HeatLockEndPctBig and the helper GetLazerLockEndPct are removed.
--      Make your own safeguard with the lazer's wire outputs HeatPct / HeatF / HeatKJ.
--   9  (15.3) TURBO DAMAGE: past HeatTurboStartPct of its limit anything that damages itself from heat takes HeatTurboPct percent of its max health per second on top, growing steeply
--      (HeatTurboPower). GetHeatDamagePct has the turbo term.
--   10 (15.3) HOT LAZERS SET PLAYERS ON FIRE: the HeatIgnite... knobs, and the pure box test ObbTouchesAabb the heat file uses.
--   11 (15.3) THE COOLANT: the Rad...Coolant... / RadFlush... / RadPuff... knobs (tank size, how the tank changes the cooling, the flush, the steam, the sounds) and the helpers
--      GetRadCoolantCapacity, GetRadFlushRate, GetRadCoolantMult, ClampRadColor. GetRadReadout also reports the tank.
--   12 (15.4) COOLING: HeatCoolTau is 300 again and the new multiplier HeatCoolSpeed (1.25) sits on top: natural cooling is 1.25 times the speed of 15.2 (15.3 had 2 times). Radiators shed their
--      own heat HeatCoolMultRad (5) times as fast as a prop. ACFLazers.GetHeatCoolRate is the one place the rate is worked out.
--   13 (15.4) NO MORE OVERCLOCK: RadOverclockDefault, RadOverclockMax and RadDamage are gone (a radiator never hurts itself from heat), ClampRadOverclock is gone, GetRadReadout has no overclock
--      rows. The heat a radiator eats per second is RadSapSmall / RadSapBig (5 times what 15.3 had).
--   14 (15.4) THE FLUSH IS A HEAT OBLITERATOR: RadFlushKJPerLiter is 125000 (three 12-wide radiators flushing for 2 seconds take a 100 mm lazer from 115% to 25%). The sounds FADE OUT
--      (RadFlushFadeSeconds), the burst included.
--   15 (15.4) STEAM: RadPuffMaterial is now RadPuffMaterials, a list of ACF's own smoke sprites (the old guess had no texture). ACFLazers.PickRadPuffMaterial picks one.
--   16 (15.4) HeatIgniteSeated: a player sitting in a vehicle is not set on fire by a hot lazer (the crew of the vehicle the lazer is on).
--   (The numbering of earlier handoffs is gone: [CHANGED n] marks restart at 1 with every whole-number handoff.)
--
-- Tags used in comments:  [SEEN] read in the files   [KNOW] standard GMod   [GUESS] needs a test
-- =========================================================================

if SERVER then AddCSLuaFile() end

ACFLazers = ACFLazers or {}

-- Goes up by one every time a link is made or broken or a capacitor is removed. Lazers and capacitors remember the number they last built
-- their capacitor group at; when it differs, they rebuild the group. (Kept across Lua refreshes on purpose.)
ACFLazers.LinkVersion = ACFLazers.LinkVersion or 0

-- Keep the SAME table object across Lua refreshes, so files that grabbed a reference earlier
-- (init.lua does: local LASER_CONFIG = ACFLazers.Config) still see the new numbers.
ACFLazers.Config = ACFLazers.Config or {}
table.Empty(ACFLazers.Config)

table.Merge(ACFLazers.Config, {

    -- ===================== SIZE ("caliber", in millimetres) =====================
    -- The name you picked is "Lenze(TM) Diameter". That is only the TEXT on the tool slider (SizeLabel below).
    -- Identifiers, wire outputs and dupe keys still say "Caliber" on purpose: renaming those would break old dupes and any wiring / E2
    -- that reads the "Caliber" output. Say the word if you want those renamed too.
    -- (The TM sign is written as the byte codes \226\132\162 so this file stays plain ASCII and no editor can garble it.)
    SizeLabel       = "Lenze\226\132\162 Diameter",
    CaliberMin      = 20,     -- smallest lazer the tool can make
    CaliberMax      = 300,    -- biggest lazer the tool can make
    CaliberBase     = 100,    -- the model is its normal size (scale 1.0) at this caliber. scale = caliber / CaliberBase

    -- ===================== MASS (kg) =====================
    -- mass = MassMin + (MassMax - MassMin) * t ^ MassExponent,   t = 0 at CaliberMin ... 1 at CaliberMax
    -- MassExponent bends the curve (bigger = light lazers stay light for longer):
    --   2 -> 100 mm is about 790 kg     3 -> about 269 kg    4 -> about 120 kg    (all hit 9000 kg at CaliberMax)
    MassMin         = 60,     -- kg at CaliberMin. Your server value (was 40)
    MassMax         = 9000,   -- kg at CaliberMax. Your server value (was 2300)
    MassExponent    = 2,      -- was 3. (With the old 40 / 2300 kg ends, 2 gave 224 kg at 100 mm; with your 60 / 9000 it gives 790 kg)

    -- ===================== ACF HEALTH / ARMOUR =====================
    -- Gun-style, copied from acf_gun/init.lua:1344-1364 [SEEN]:
    --   armour (mm) = caliber * ACF.ArmorMod        health = surface area / ACF.Threshold
    -- These two multipliers let you scale them without touching code. 1 = exactly like an ACF gun.
    -- (This is your "lazer volume multiplier": ACF guns have no ductility value, so these two knobs are the whole story.)
    ArmourMult      = 0.5,  -- was 1. Half the armour: a 100 mm lazer has 50 mm, a 300 mm one 150 mm (a gun would have 100 and 300)
    HealthMult      = 1,

    -- ===================== FOCAL LENGTH + FOCUS AMOUNT (tool sliders + the damage curve) =====================
    -- Damage depends on how far from the lazer the beam hits, measured along the beam (units).
    --   * "Focal length" (slider 1) = the distance where the lazer does its MAX damage (1.0). Its longest allowed value is the lazer's "max focal distance":
    --         max focal distance = FocalMaxFraction (3/7) x the lazer's effective range      (effective range: EffectiveRangeSmall ... EffectiveRangeBig, further down)
    --   * "Focus amount" (slider 2, FocusAmountMin..FocusAmountMax = 0 to 100) = how tightly the damage is gathered round the focal length. It sets the RADIUS of the focused zone,
    --     along the beam only, and the radius comes from the lazer's size (it is not a plain number of units any more):
    --         focus amount   0 -> radius = the max focal distance                                   (loosest)
    --         focus amount 100 -> radius = the max focal distance x FocusRadiusMinFraction (1/3)     (sharpest)
    --         in between       -> a straight line between those two
    --     At the edge of the radius (focal length +/- radius) the damage has tapered in a straight line down to FocalEdgeFraction (3/4) of max.
    --   * FARTHER than the far edge: a straight line from FocalEdgeFraction down to FocalFarEndFraction (1/3) at the lazer's effective range.
    --   * CLOSER than the near edge (only when the focal length is bigger than the radius): flat at FocalEdgeFraction (3/4) all the way to the muzzle. It used to taper down to 1/3
    --     at the muzzle, which made the damage climb very steeply whenever the near edge sat just in front of it. If the near edge would be behind the muzzle (radius bigger than the
    --     focal length) there is no closer part: the curve is simply cut off at the muzzle.
    --   * SHARP FOCUS BONUS: a focus amount above FocusBoostStart adds a bonus to the CENTRE only (the edge stays at 3/4 of the normal max). It grows in a straight line
    --     from nothing (at FocusBoostStart) to FocalBoostMax (1.4x) at the sharpest focus amount.
    --   With the numbers below the far edge can never be farther than 3/7 + 3/7 = 6/7 of the effective range, so the curve has no jump anywhere (a radius that reaches past the
    --   effective range would make the damage jump). Changing FocalMaxFraction above 1/2 breaks that; the damage notes in the project state say how to check.
    --   The tool's Focal Length slider follows the lazer size you pick (its top end is ACFLazers.GetFocalLimits for that size) and the server squeezes the number into the same limit again.
    FocalMin        = 200,    -- shortest focal length for any lazer
    FocalDefault    = 300,
    FocalMaxFraction = 3 / 7, -- longest focal length ("max focal distance") as a share of the lazer's effective range. Replaces FocalMaxSmall / FocalMaxBig
    FocusAmountMin     = 0,   -- the Focus amount slider's two ends. 0 = loosest. These only define what "0" and "100" mean; the maths works out the rest
    FocusAmountMax     = 100, -- 100 = sharpest
    FocusAmountDefault = 50,  -- [GUESS] where the slider starts (50 = no sharp-focus bonus yet, see FocusBoostStart)
    FocusRadiusMinFraction = 1 / 3, -- the radius at the sharpest focus amount, as a share of the max focal distance (the loosest radius is the whole max focal distance)
    FocusBoostStart    = 50,  -- the sharp-focus bonus starts at this focus amount (same scale as the slider). Replaces FocalBoostRangeMult: 50 is where "twice the smallest range" fell
    FocalEdgeFraction     = 3 / 4, -- damage at the edge of the radius, as a fraction of the normal max
    FocalFarEndFraction   = 1 / 3, -- damage at the lazer's effective range, as a fraction of the normal max
    FocalBoostMax         = 1.4,   -- centre damage at the sharpest focus amount (1.4 = 1.4x the normal max)

    -- ===================== BEAM =====================
    -- DISTANCE FALLOFF. Every beam loses damage the farther it travels, in ONE straight line:
    --     1.0 right at the muzzle  ...  FalloffAtRange (3/4) at the lazer's "effective range"  ...  and it keeps dropping on the same line down to 0.
    --   "Effective range" is just a name for the distance where the damage has dropped to FalloffAtRange. It depends on the lazer's size, in a straight line:
    --     EffectiveRangeSmall (15000) at the smallest lazer ... EffectiveRangeBig (30000) at the biggest.
    --   Where the line reaches 0 damage the beam stops entirely (it is not even drawn past there). With 3/4 that is at 4 x the effective range
    --   (60000 for the smallest, 120000 for the biggest, but BeamRangeCap below ends every beam first: the biggest one at 50000, where it still does 58% damage). The falloff is MULTIPLIED with the focal curve (focal length / range, above).
    EffectiveRangeSmall = 15000,  -- units. Smallest lazer: damage is FalloffAtRange (3/4) at this distance. Your server value (was 6000)
    EffectiveRangeBig   = 30000,  -- units. Biggest lazer. Your server value (was 20000, 10000 before that). The longest focal length is 3/7 of this (300 mm: 12857)
    FalloffAtRange      = 3 / 4,  -- your server value (was 3/5). Damage multiplier at the effective range (1 = no falloff at all: the beam then goes as far as BeamRangeCap)
    BeamRangeCap        = 50000,  -- units. Safety cap on how far any beam may reach, whatever the falloff numbers say. was 30000. With FalloffAtRange 3/4 the biggest lazer's beam would end at 4 x EffectiveRangeBig = 120000,
    --                                  so a cap below that cuts the beam where its damage is still above 0 (and FalloffAtRange 1 = no falloff = the beam goes all the way to this number)
    MaxBeamHits     = 32,     -- safety cap: most things one beam can pass through in one tick
    MaxDeltaTime    = 0.1,    -- seconds. Caps the "time since last tick" used for damage, so a lag spike can't dump a huge hit
    -- WHAT THE BEAM CAN SEE (trace mask).
    -- The beam is found with a trace (acf_lazer/init.lua, ENT:FireLaserBeam) and a trace only hits what its MASK lists. The lazer used MASK_SHOT on its own.
    -- ACF's own bullets never do: they trace with MASK_SOLID, and bullets under 3 cm trace with "MASK_SOLID and MASK_SHOT"
    -- [SEEN acf/ballistics/ballistics_sv.lua:146-150; the 3 is in cm: acf/core/round_functions.lua:57 says "Bullet caliber will have to stay in cm"].
    -- MASK_SHOT is the only one of these that contains CONTENTS_HITBOX (the shapes used for hit boxes), and ACF's own acf/compatibility/trace_workaround.lua:13 lists
    -- "MASK_SHOT ignores all entities" as a known issue. Reason for the change: you reported that freshly parented / re-duped props are hit by ACF's guns but passed straight through by the lazer,
    -- and this mask is the one difference I found between the two traces (same function ACF.trace, same filter style). [GUESS] that the hit-box bit is why those props were skipped: to be confirmed in game.
    -- Now the lazer asks for what an ACF round of its size asks for:
    --    caliber BELOW this number (mm)  -> MASK_SOLID and MASK_SHOT   (no hit-boxes; thin grates / fences are see-through, like small ACF rounds)
    --    caliber at or above it          -> MASK_SOLID                  (no hit-boxes; grates / fences stop the beam, like bigger ACF rounds)
    BeamMaskSmallBelowMM = 30,  -- mm. ACF's own cut-off between small and big rounds (its 3 cm). 0 = every lazer counts as big. A huge number (100000) = every lazer counts as small
    -- When a lazer cannot hurt a prop (safezone, ACF refused the hit, a crashing damage hook ...) its owner gets a chat message saying why.
    ShowProblemNotices = true,  -- false = never send those messages
    NoticeInterval     = 10,    -- seconds. At most one message per reason per lazer in this time
    NoCapacitorNoticeInterval = 30, -- seconds. A lazer with NO capacitor linked, with Fire held, reminds its owner this often (the only power-related chat line; the hover text says the rest)
    -- true  = a prop that the lazer's safezone check flags is IMMUNE to lazers (the beam stops on it: no damage, no fire). Your earlier rule.
    --               false = lazers treat such a prop like any other: only ACF's own rules (permission mode, ACF safezones, other addons' hooks) can protect it.
    -- Does not touch people: their protection is each player's own toolgun checkbox (IsPersonProtected).
    ProtectSafezoneProps = true,

    -- ===================== DAMAGE TO PROPS / VEHICLES (goes through ACF's own pipeline) =====================
    -- Each tick the beam is treated as a "hit" with:
    --    Area (cm^2)       = beam cross-section * HitsPerSecond * seconds-since-last-tick   <- tick-rate independent
    --    Penetration (mm)  = caliber * PenetrationPerMM                                    <- caliber only, as you asked
    -- ACF then does the rest (armour, angle, health, dirt, debris). See the notes in PROJECT_STATE.md.
    HitsPerSecond     = 0.5,  -- [GUESS] tuning knob: higher = everything dies faster
    -- PenetrationPerMM ONLY feeds ACF's damage maths. It does not decide whether the beam gets through a plate: that is the pass-through rule just below.
    -- ACF's rule ([SEEN] acf/damage/objects_sv/damage_result.lua, Compute): damage to the plate = Area x min(1, penetration / thickness)^2, where thickness = the plate's CURRENT armour / cos(angle)
    -- (the angle here is the real angle x AngleInfluence, below). So a plate no thicker than the penetration takes the full area damage, a thicker one takes (penetration / thickness)^2 of it.
    -- With 0.3 a 100 mm lazer counts as 30 mm of penetration: a 30 mm plate takes the full damage, a 60 mm plate 1/4 of it, a 100 mm plate 9%. (With the old 1.0 it counted as 100 mm,
    -- so every plate up to 100 mm took the full damage: that is why things were being obliterated.) The pass-through line (PenArmourFraction below) is a separate knob.
    PenetrationPerMM  = 0.3,  -- your request (was 1.0): ACF counts the lazer as about a third of its caliber, in mm of penetration

    -- PASS-THROUGH RULE (for normal lazers; burst lazers may get their own numbers later):
    --   * The beam STOPS on the first armoured prop it hits. It only gets through if that prop's CURRENT armour (mm) is below "the line":
    --     PenArmourFraction x the lazer's caliber (mm) x THE DAMAGE MULTIPLIER AT THAT HIT.  The multiplier is the very same number the damage gets at that distance
    --     (the focal curve x the distance falloff, init.lua ENT:CalculateDamageMult), so the line rises and falls with the damage: at multiplier 1 it is exactly PenArmourFraction x caliber
    --     (1/3 of the caliber), at 0.5 half of that, and where the beam has faded to 0 nothing can be pierced any more (ACFLazers.GetPassLine does the sum).
    --     ACF lowers a plate's armour as the plate loses health (never below half of its original).
    --   * The plate being burned through takes the NORMAL damage (at its own multiplier).
    --   * Everything BEHIND it takes the SAME damage multiplier that plate took (focal curve x falloff at THAT plate's distance, remembered when the beam went through),
    --     times a slice of it, so the damage behind = the damage at the first plate's multiplier x the slice, whatever distance the things behind are at (the usual angle effect of each
    --     prop it lands on still applies to it). The slice slides:
    --       armour exactly on the line                        -> nothing
    --       armour at PenRampEnd x the line (or lower)        -> the full PenDamageFraction
    --       in between                                        -> a straight line between those two
    --     Nothing behind it catches fire. People behind the plate follow the same rule.
    --   * A beam can burn through ONE prop only. The next prop that survives it stops it (it still takes the weakened damage).
    --   * A prop that is DESTROYED never blocks the beam and does not use up the one burn-through.
    --   * People, NPCs and things ACF ignores (holograms, E2...) never block the beam and don't use up the burn-through either.
    -- Examples (100 mm lazer HIT AT DAMAGE MULTIPLIER 1, fraction 1/3 -> the line is 33 mm of armour, PenRampEnd 1/2 -> full damage at 16.7 mm; at multiplier 0.6 the line is 20 mm and so on):
    --   * a 10 mm plate is under the line from the very first tick: the beam goes through it, and what is behind takes the full 1/4 (of the damage at the multiplier the 10 mm plate took).
    --   * a 25 mm plate also goes through at once, but what is behind takes about half of the 1/4.
    --   * a 40 mm plate holds the beam until damage has worn its armour under 33 mm, then the beam goes through.
    --   * a 100 mm plate never wears below 50 mm, so it is never pierced (only destroyed). Same for anything over 66 mm. That is on purpose.
    PenArmourFraction = 1 / 3,  -- [GUESS] starting value: the line, as a fraction of the caliber, AT DAMAGE MULTIPLIER 1: the real line at a hit is this x the damage multiplier there
    PenDamageFraction = 1 / 4,  -- [GUESS] starting value: most that the stuff behind a pierced plate takes, as a fraction of normal
    PenRampEnd        = 1 / 2,  -- [GUESS] starting value: the weakened damage reaches its full PenDamageFraction when armour is this fraction of the line

    -- NEW. How much the angle the beam hits at matters. Think of a torch on a wall:
    --   straight on = all the heat lands in a small spot;  tilted = the same heat smears over a longer streak.
    --   0   = angle is ignored completely
    --   1   = the full "smear" (damage rate follows cos of the angle: 60 degrees = half, 80 degrees = a sixth)
    --   0.5 = a gentle version (60 degrees acts like 30, 80 degrees acts like 40). [GUESS] starting value, tune by feel.
    -- It does two things at once, so you see it on thin AND thick plates:
    --   (a) the angle ACF is told about is (real angle * AngleInfluence)  -> thick plates get a bit tougher
    --   (b) the damage area is multiplied by cos(that same scaled angle)  -> thin plates take a bit less too
    AngleInfluence    = 0.5,

    -- ===================== DAMAGE TO PLAYERS / NPCs (kept as your old direct damage, now per second) =====================
    -- Old code did 4 * (caliber/100) per tick; its real speed depended on the server tick rate.
    -- 4 per mm per second = 400 per second for a 100 mm lazer (the old number at a nominal 100 Hz).
    PersonDPSPerMM    = 4,

    -- DISINTEGRATION. A person (player or NPC) killed by a lazer of at least this caliber (mm) has their body disintegrated.
    -- By CALIBER now (you said "by caliber instead"). Not when they were behind a pierced plate or protected by a safezone (see init.lua DamagePerson).
    DisintegrateCaliber = 100, -- [GUESS] starting value, tune by feel
    DisintegrateType  = 0,    -- how the body dissolves: 0 = energy ball, 1 = heavy electrical, 2 = light electrical, 3 = core effect [KNOW: Entity:Dissolve types]

    -- SAFEZONES. Anyone inside a safezone (as your safezone addon reports it, see IsEntityInSafezone in init.lua) takes only this fraction of
    -- the lazer damage and can't be set on fire. Props in a safezone are still fully protected (the beam stops on them).
    -- Whether this is applied at all is now a per-LAZER setting: the "Safezone protection" checkbox on the toolgun (saved on the lazer, dupes
    -- keep it, checked by default). The old server console variable acf_lazer_safezone_protect is gone.
    SafezoneDamageMult = 1 / 6,

    -- FIRE. Wooden props burn for BurnTimeMin seconds at the smallest lazer, scaling in a straight line to BurnTimeMax at the biggest.
    -- People (and NPCs) are only set on fire by lazers at or above PersonIgniteCaliber; their burn time uses the same scale but STARTS at that caliber
    -- (so a lazer right at PersonIgniteCaliber burns for BurnTimeMin, the biggest for BurnTimeMax) and is then multiplied by PersonBurnMult.
    BurnTimeMin         = 3,    -- seconds
    BurnTimeMax         = 15,   -- seconds
    PersonIgniteCaliber = 60,   -- mm. Lazers smaller than this never ignite people. you asked for 60 (was 100)
    PersonBurnMult      = 1.5,  -- people burn this many times longer than props would. [GUESS] starting value

    -- ===================== LAZER POWER: ENERGY COMES FROM CAPACITORS =====================
    -- (The old burst length / forced recharge knobs were removed here .)
    -- A lazer only fires while the capacitors linked to it (and every capacitor grouped with those) hold energy. Energy is counted in kJ, the same unit ACF uses
    -- for HE (ACF.HEPower = 8000 kJ per kg of HE filler), so a capacitor's stored energy can be turned straight into an explosion.
    -- While firing, a lazer eats  draw rate x seconds  of energy every tick (its "bite"). The draw rate slides in a straight line with the lazer's size.
    RequireCapacitor  = true,   -- false = lazers fire for free again (no capacitor needed). Handy for testing the damage side on its own
    -- PLAIN NUMBERS: the draw is worked out over the lazer's size, from LazerDrawSmall at the smallest lazer to LazerDrawBig at the biggest. What you type here is
    --   what those two lazers eat: there are no scale knobs. The sizes in between follow the curve below.
    --   LazerDrawCurve  0   = a straight line:   100 + 39900 x t                    (50 mm 4375, 100 mm 11500, 160 mm 20050, 200 mm 25750 kJ/s)
    --                   1   = fully exponential: 100 x (40000 / 100) ^ t             (50 mm 190,  100 mm 554,  160 mm 2000,  200 mm 4707 kJ/s)
    --                   0.5 = half of each (the default until 13.3):                 (50 mm 2283, 100 mm 6027, 160 mm 11025, 200 mm 15229 kJ/s)
    --                   0.75 = three quarters exponential (the default now):         (50 mm 1236, 100 mm 3290, 160 mm 6512, 200 mm 9968 kJ/s)
    --   where t = (caliber - CaliberMin) / (CaliberMax - CaliberMin) runs from 0 (smallest) to 1 (biggest). The start energy (LazerStartSeconds x draw) follows.
    LazerDrawSmall    = 100,    -- kJ per second the smallest lazer (CaliberMin) eats while firing. Your server value (was 200)
    LazerDrawBig      = 40000,  -- kJ per second the biggest lazer (CaliberMax) eats while firing. Your server value (was 25000 in 13.1, 45000 before that)
    LazerDrawCurve    = 0.75,   -- your server value (was 0.5). 0 = straight line, 1 = fully exponential, in between = a mix (see above). Clamped to 0 .. 1. Lower = the middle sizes eat more
    -- A lazer that ran dry (a "dud") only starts again once the pool holds at least this many SECONDS of its own draw. Without it, a lazer fed by a trickle
    -- would flicker on and off every tick. 0 = restart as soon as the pool can pay for one tick.
    LazerStartSeconds = 1,      -- your server value (was 3 in 13 to 13.3, 0.5 before that). A pool that holds less than this many seconds of the lazer's draw can still start it if it is nearly full (next line)
    -- OVERRIDE for the rule above (9.2): when the whole pool (every capacitor reachable from the lazer) is at least this full, the lazer may start / restart even if the pool holds less than
    -- LazerStartSeconds of its draw. Without it a lazer whose capacitors can never hold the start energy would never fire. 0.9 = 90% full. 0 or less = no override (the LazerStartSeconds rule alone decides).
    -- Above 1 (say 2) also means no override, because a pool can never be more than 100% full.
    LazerStartFullFraction = 0.9,
    LazerEnergyReadInterval = 0.25, -- seconds between refreshes of the lazer's "Energy" wire output while it is in use (it checks once a second when idle)

    -- ===================== SMALL-LAZER BOOST (damage to PROPS only; people are not affected) =====================
    -- Small lazers hit props SmallBoostMult times harder (2 = double). The boost is full at SmallBoostFullMM and below, then slides in a straight line
    -- down to SmallBoostEndMult at SmallBoostEndMM, and every bigger lazer gets SmallBoostEndMult (1 = no boost). With your numbers (20 mm 2x, tapering to 1x at 300 mm) a 160 mm lazer hits props 1.5x.
    SmallBoostMult    = 2,      -- boost for the smallest lazers. Your server value (was 1.19)
    SmallBoostFullMM  = 20,     -- caliber (mm) up to which the boost is at full strength
    SmallBoostEndMM   = 300,    -- caliber (mm) where the boost has tapered off to SmallBoostEndMult. Your server value (was 70)
    SmallBoostEndMult = 1.0,    -- the multiplier at SmallBoostEndMM and above

    -- ===================== CAPACITORS =====================
    -- SIZE. The model is a cylinder CapModelDiameter units across and CapModelHeight units tall at scale 1. A capacitor of diameter d is scaled by d / CapModelDiameter.
    CapModel          = "models/lasers/capacitor.mdl", -- your own capacitor model (changed from the Wiremod one). If the file is missing the capacitor refuses to spawn and says so
    CapModelDiameter  = 10,
    CapModelHeight    = 40,
    CapDiameterMin    = 6,      -- smallest capacitor the tool can make (units across)
    CapDiameterMax    = 60,     -- biggest capacitor the tool can make. Your request (was 100). Bigger ones on a dupe or an update are squeezed down to this
    CapDiameterDefault = 20,    -- starting value of the tool slider
    -- ENERGY. Capacity (kJ) = CapEnergyPerVolume x the model's volume in cubic units. Volume = pi x (d/2)^2 x height, and height = d x CapModelHeight / CapModelDiameter,
    -- so volume = pi x d^3 for this model. With 0.3 x CapEnergyScale (1): a 10-unit capacitor holds 942 kJ, a 20-unit one 7540 kJ, a 60-unit one (the biggest, CapDiameterMax) 203,575 kJ (= 25.4 kg of ACF HE).
    CapEnergyPerVolume = 0.3,   -- kJ per cubic unit: the base power density of the capacitors. Your server value (was 0.2)
    CapEnergyScale     = 1,     -- your server value (was 2/3). ONE scalar on top of that: every capacitor holds this share of CapEnergyPerVolume. 2/3 = "two thirds as power dense overall". 1 = off
    CapNoChargeWhileDrained = true, -- true = a capacitor does NOT charge by itself (its own charger is off) while a lazer is drawing from its pool. It still takes DUMPS from other capacitors. false = it charges all the time, as in 8
    CapDrainHoldSeconds = 0.25, -- seconds the charging stays off after a lazer last drew from the pool. Keep it above CapThinkInterval (0.1) or the charging would flicker between the lazer's draws
    CapChargeRateDefault = 100, -- [GUESS] starting value of the tool's charge-rate slider (kJ per second). A capacitor whose own limit is lower than that (CapChargeRateMaxFraction of its capacity: only the very smallest sizes) is held to its own top
    CapChargeRateMaxFraction = 1 / 3, -- the fastest a capacitor may charge itself, as a share of its capacity per second: the slider and the server's clamp end at capacity x this (it was 1, a full fill in one second)
    CapThinkInterval  = 0.1,    -- seconds between capacitor updates (charging, dumping, wire outputs)
    CapMaxDeltaTime   = 0.5,    -- seconds. Longest "time since last update" a capacitor will charge for (a lag spike cannot dump a huge charge in one go)
    CapRateReadInterval = 0.25, -- seconds between refreshes of the "apparent charge rate" and the wire outputs
    -- BODY. Mass, armour and health of a capacitor (health uses the same rule as ACF guns: surface area / ACF.Threshold).
    CapMassPerVolume  = 0.03,   -- your server value (was 0.009, 0.004 before that). [GUESS] kg per cubic unit: 10 units = 94 kg, 20 = 754 kg, 60 units (the biggest) = 20,358 kg.
    --                                  [KNOW, not tested] the engine caps a physics object at 50,000 kg; with CapDiameterMax 60 no capacitor gets near it (it would from about 81 units up)
    CapArmourPerUnit  = 0.5,    -- [GUESS] mm of armour per unit of diameter (10 units = 5 mm, 60 units = 30 mm)
    CapHealthMult     = 1,      -- multiplier on the health ACF works out from the surface area
    -- EXPLOSION ODDS WHEN DAMAGED (but not destroyed). c = charge as a fraction of capacity, h = health as a fraction of max health (after the hit).
    --   c under CapExplodeMinCharge (10%)            -> never explodes
    --   c under h                                    -> CapExplodeChanceBase (40%)
    --   c from h up to h + CapExplodeRamp (30 points) -> climbs in a straight line from 40% to CapExplodeChanceMax (80%)
    --   c at h + 30 points or more                   -> 80%
    -- The dice are rolled at most once per CapExplodeRollInterval seconds per capacitor, so a lazer beam (which damages every tick) does not roll 60 times a second.
    CapExplodeMinCharge  = 0.10,
    CapExplodeChanceBase = 0.40,
    CapExplodeChanceMax  = 0.80,
    CapExplodeRamp       = 0.30,
    CapExplodeRollInterval = 0.25, -- [GUESS] seconds
    -- WHAT AN EXPLODING CAPACITOR RELEASES (destroyed or exploded): a random share of its stored energy between these two fractions. The energy becomes an ACF
    -- explosion: filler kg = kJ / ACF.HEPower x CapExplosionMult. CapReleaseMinKJ is a floor so an empty capacitor still pops a tiny bit (never exactly 0).
    CapReleaseMinFraction = 0.5,
    CapReleaseMaxFraction = 1.0,
    CapReleaseMinKJ    = 0.1,
    CapExplosionMult   = 1,     -- 1 = exactly the HE equivalent. Raise it for bigger bangs, lower it for smaller ones
    CapMaxPerPlayer    = 20,    -- default for the server variable sbox_maxacf_capacitors (how many capacitors one player may have)

    -- ===================== GENERATOR HUB =====================
    -- WHAT IT IS. A flywheel LOAD for ACF engines. Engines are linked to it (the way they are linked to a gearbox); every server tick it slows each linked engine's flywheel a little
    -- (that is the "drag") and turns the power it took into kJ in the capacitors it is linked to. Details: ACF's engine keeps a flywheel; a gearbox asks for torque, the flywheel
    -- loses RPM equal to the torque given / its inertia [SEEN acf_engine/init.lua:812-859]. The generator does the same to the engine's FlyRPM, ONCE PER ENGINE, so it can
    -- tell how much each engine is giving (for the readouts), and so it can share its rating between them.
    GenModel           = "models/lasers/generator.mdl", -- your buddy's model: sized for 350 hp at scale 1 (the middle knot below). If the file is missing the generator refuses to spawn and says so
    -- SIZE <-> POWER. The tool slider is the generator's RATED power in hp. The model scale follows it through these knots {hp, model scale}. Between two knots the scale follows a
    -- power law (a straight line on a graph with both axes logarithmic), so every knot is hit exactly: 50 hp = 0.5, 350 hp = 1.0, 3500 hp = 2.0 (100 hp = 0.64, 200 hp = 0.82, 1000 hp = 1.37, 2000 hp = 1.69).
    GenHPMin           = 50,    -- smallest rated power the tool can make (hp). Must be the first knot's hp
    GenHPMax           = 3500,  -- biggest rated power (hp). Must be the last knot's hp
    GenHPDefault       = 350,   -- starting value of the tool slider
    GenScaleKnots      = { { 50, 0.5 }, { 350, 1 }, { 3500, 2 } }, -- {hp, scale}, smallest hp first, at least two
    -- THE ENGINE INPUT POINT (copies a gearbox: the engine's driveshaft ends here). Model space. The engine has to be in FRONT of this point: the straight line from this point to the
    -- engine's driveshaft end must be within GenInputAngle degrees of "straight ahead from this point" (the model's forward, +X). Further off than that and the link is refused / broken.
    -- ACF also checks the engine's own end the way it does for gearboxes (its limit is ACF.MaxDriveshaftAngle, 85 by default [SEEN acf/core/globals.lua:178]), so the engine's rear must face the generator.
    GenInputPos        = { 20, 0, 1 },
    GenInputAngle      = 45,    -- degrees. ACF's own gearbox limit is 85
    GenMaxEngines      = 8,     -- most engines one generator can have linked (the wire output and the rope drawing keep one slot per engine)
    GenCheckInterval   = 1,     -- seconds between the checks that every link is still short enough and still straight enough (ACF's engine does it every 3 s; the cone is tighter here)
    GenStretchFactor   = 1.5,   -- a link breaks when the two ends are this many times farther apart than they were when it was made (ACF's gearboxes use 1.5 too)
    -- THE LOAD. For each linked engine, every tick:
    --     torque taken (Nm) = Draw x GenLoadStrength x T_ref x (rpm / peak-power rpm) ^ GenLoadExponent          (never more than the flywheel has above idle, like ACF's gearboxes)
    --   where T_ref = the engine's peak power (kW) x 9548.8 / its peak-power rpm = the torque it makes AT its peak power. "Draw" is the wire input as a fraction (100 = 1, 0 = 0).
    --   So at Draw 100 and full throttle the load line crosses the engine's own torque curve near its peak-power rpm: a real ACF engine settles at 99-114% of its rated kW there
    --   (tried on all 99 engine definitions of this ACF with its real flywheel maths: median 102%, only the tiny 0.5-I1 is above 110%). A load that grows with rpm is also what keeps it stable: the engine finds its own speed.
    --   Below 100 the engine is only partly loaded: it revs higher, at a power below peak. At zero throttle (or on its rev limiter) an ACF engine feeds nothing to gearboxes, so neither does this.
    GenLoadStrength    = 1,     -- 1 = Draw 100 takes the engine's whole peak power at its peak-power rpm. Above 1 = heavier (the engine bogs lower), below 1 = lighter (it revs higher)
    GenLoadExponent    = 1,     -- how fast the load grows with rpm: 0 = constant torque, 1 = like an alternator (default), 2 = like a fan. 2 keeps more power at partial Draw
    GenDrawDefault     = 100,   -- what the Draw input counts as while nothing is wired to it (100 = take everything, like AllowCharge counting as on)
    GenDrawMax         = 100,   -- the Draw input value that means "all" (the wire value is clamped to 0 .. this)
    GenKwRpmConstant   = 9548.8, -- power (kW) = torque (Nm) x rpm / 9548.8. ACF's own number [SEEN acf_engine/init.lua:538]: a constant of nature, not a tuning knob
    GenKwToHp          = 1.341, -- used only if ACF.KwToHp is missing [SEEN acf/core/globals.lua:198]
    GenEngineHPMult    = 1,     -- ACF's engine menu shows the PLAIN kW / hp by default. Its hidden torque multiplier (ACF.TorqueMult, 5) only multiplies the torque handed to WHEELS. If your menu is set to
    --                             show hp multiplied by it, set this to 5 so the hp here is the number you read on the engine
    -- ENERGY. THE energy-per-hp scalar: kJ stored per hp-second taken from the engines (times the damage multiplier below). 60-unit capacitor = 203,575 kJ, 3500 hp x 5.2 = 18,200 kJ/s -> full in 11.19 s.
    GenKJPerHP         = 5.2,   -- was 2.6: twice as effective, so that heat (not the capacitors) is what limits how often you can fire
    -- THE RATING IS A LIMIT, NOT A BREAKING POINT. Engines may push more than the rating: the hub just takes at most its rated hp in total (the tool slider value) and the
    -- engines feel no more drag than that. Nothing here to set. (The old overload knobs, which broke engine links, are gone.)
    -- DAMAGE. A damaged hub makes less energy for the same hp taken: x1 at full health, falling in a straight line to GenDamagedEfficiency at 0 health.
    GenDamagedEfficiency = 0.5,  -- energy multiplier at 0% health (1 at 100%). 0.5 = a hub at 40% health makes 0.7x the energy
    GenPowerSmoothing    = 0.4,  -- seconds. Time constant of the smoothing of the hp reading (wire output, hover text)
    GenToolCapSize       = 60,   -- the generator tool quotes "fills a capacitor this big in N seconds" for this capacitor size (a display number only: changes nothing in the game)
    -- RUNNING. The generator thinks every server tick (like the engine) because it has to slow the flywheel once per engine tick.
    GenMaxDeltaTime    = 0.1,   -- seconds. Longest "time since last tick" it will act for (a lag spike cannot take a huge bite out of an engine)
    GenOutputInterval  = 0.25,  -- seconds between refreshes of the wire outputs and the hover text
    -- BODY. Mass, armour and health. Mass = GenMassAtOne x scale ^ GenMassExponent (a volume-like curve: 50 hp = 50 kg, 350 hp = 400 kg, 3500 hp = 3200 kg).
    GenMassAtOne       = 400,   -- [GUESS] kg at model scale 1 (ACF's 9.0L V8 petrol weighs 400 kg [SEEN acf/entities/engines/v8.lua:36])
    GenMassExponent    = 3,
    GenArmourAtOne     = 40,    -- [GUESS] mm of armour at model scale 1 (scales with the model scale, times ACF.ArmorMod)
    GenHealthMult      = 1,     -- multiplier on the health ACF works out from the surface area
    GenMaxPerPlayer    = 10,    -- default for the server variable sbox_maxacf_generators

    -- ===================== HEAT (the heat core. The radiator block follows it) ===================== [CHANGED 1]
    -- WHAT IT IS. Any entity can hold heat. Heat is kept as kJ ABOVE room temperature, and an entity's heat CAPACITY is its mass: kJ per kelvin = mass (kg) x HeatSpecificHeat.
    -- A heavy plate needs a lot of kJ to warm up, a light lazer very few. An entity at room temperature costs nothing to keep track of, and nothing heats unless we say so:
    --   * a lazer that is firing heats ITSELF          (the kJ it spends x HeatLazerSmall .. HeatLazerBig)
    --   * a lazer BEAM heats the props it hits          (the same heat rate x HeatHitSmall .. HeatHitBig, weakened by focus / angle / burn-through exactly like the damage is)
    --   * a capacitor heats when energy goes in OR out  (kJ moved x HeatCapSmall .. HeatCapBig). A generator hub heats when it makes energy (kJ made x HeatGenSmall .. HeatGenBig)
    -- Everything cools back down by itself (HeatCoolTau and HeatCoolSpeed below). The temperature players see is always Fahrenheit, and every temperature typed in this block is Fahrenheit too.
    -- "Small .. Big" pairs: the Small number is for the smallest size of that thing (CaliberMin lazer, CapDiameterMin capacitor, GenHPMin hub), the Big number for the biggest, a straight line between.
    HeatSpecificHeat    = 0.49,   -- kJ per kg per kelvin: the energy that warms 1 kg by 1 K. 0.49 = steel [KNOW]. Higher = every entity needs more kJ per degree (heat sources warm things more slowly)
    HeatMinMassKg       = 1,      -- kg. An entity with no (or a tiny) physics mass counts as at least this much, so the maths never divides by zero
    HeatAmbientK        = 288.15, -- kelvin. Room temperature; used ONLY if ACF's own ACF.AmbientTemperature is missing [SEEN acf/core/globals.lua:252: 288.15 K = 15 C = 59 F]
    HeatHEPowerFallback = 8000,   -- kJ per kg of HE filler; used ONLY if ACF.HEPower is missing [SEEN acf/core/globals.lua:270]

    -- HOT, AND THE PLATE RULE. A prop is HOT once it reaches HeatHotF. That temperature is the "100%" of a plate (0% = room temperature, 59 F).
    HeatHotF            = 1100,   -- degrees Fahrenheit. 1100 F = 100% of a plate (a dull-red steel). Lower = plates get hot sooner
    HeatPenGate         = true,   -- true = a beam burns THROUGH a plate only if the plate is HOT (100% or more) AND the old armour test allows it (armour under 1/3 x caliber x damage multiplier).
    --                               A destroyed plate always lets the beam through. false = the old rule alone (heat never matters for burn-through)

    -- COOLING. Every entity cools toward room temperature by itself:  loss per second = excess x a x (1 + HeatCoolHotBoost x excess / the HOT excess),  a = multiplier x HeatCoolSpeed / HeatCoolTau.
    -- That is an ordinary exponential cooling (time constant HeatCoolTau / HeatCoolSpeed) that cools faster the hotter the thing is: at the HOT temperature it cools (1 + HeatCoolHotBoost) times as fast.
    -- All props cool at the same rate. Lazers, radiators and the other ACF entities (capacitors, generators ...) have a multiplier of their own, relative to props.
    HeatCoolTau         = 300,    -- seconds. The base cooling time constant (the speed of 15.2): after this long a mildly warm prop has lost 63% of its excess heat. Leave it alone and use HeatCoolSpeed
    HeatCoolSpeed       = 1.25,   -- [CHANGED 12] (15.4) THE multiplier on every natural cooling, relative to the speed of 15.2: 1 = 15.2 (300 s), 2 = what 15.3 had (150 s), 1.25 = 240 s. Lower = everything cools more slowly
    HeatCoolHotBoost    = 1.3,    -- extra cooling at the HOT temperature, as a multiple of the base (0 = plain exponential at every temperature, 1 = twice as fast at HOT, 3 = four times)
    HeatCoolMultLazer   = 1,      -- cooling speed of lazers relative to props (2 = twice as fast)
    HeatCoolMultACF     = 1,      -- cooling speed of every OTHER ACF entity (capacitors, generators ...) relative to props
    HeatCoolMultRad     = 5,      -- [CHANGED 12] (15.4) cooling speed of RADIATORS relative to props (5 = five times as fast): a radiator sheds its own waste heat quickly

    -- BOOKKEEPING (nothing to tune unless you are chasing lag)
    HeatForgetBelowK    = 0.5,    -- kelvin above room temperature. A cooling entity this close to room temperature is forgotten (it costs nothing again)
    HeatSweepInterval   = 5,      -- seconds between the sweeps that forget cooled-down entities and entities that were removed
    HeatCheckInterval   = 0.1,    -- seconds between a lazer's heat checks (the damage a lazer over its limit does to itself). A beam hit / a shot is counted at once, only the checks wait
    HeatMaxDeltaTime    = 0.5,    -- seconds. The longest "time since the last check" a heat check will act for (a lag spike cannot turn into one huge burst of heat damage)

    -- WHERE THE HEAT COMES FROM. Small .. Big = a straight line over the size of the thing (see the top of this block).
    HeatLazerSmall      = 15,      -- a firing lazer adds this many kJ of heat per kJ it spends (the draw). 1 = all of it, 5 = five times as much [CHANGED 3] (15.1: was 1; the beam's heat on props is built from this same rate, so it follows)
    HeatLazerBig        = 30,
    HeatHitSmall        = 1,      -- a beam adds (the lazer's heat rate) x this x the same focus / angle / burn-through weakening as its damage to the prop it hits
    HeatHitBig          = 1,
    HeatCapSmall        = 1 / 3,  -- a capacitor adds this many kJ of heat per kJ that goes in, and again per kJ that goes out
    HeatCapBig          = 1 / 3,
    HeatGenSmall        = 1,      -- a generator hub adds this many kJ of heat per kJ it makes
    HeatGenBig          = 1,

    -- LAZERS: THE LIMIT AND THE DAMAGE. [CHANGED 8] (15.3: the lock-out is GONE. A lazer fires whenever it has power, however hot it is. Make your own safeguard with the wire outputs
    -- HeatPct / HeatF / HeatKJ of the lazer, and use radiators to keep it cool.)
    -- HeatLazerCapF is 100% for a lazer (0% = room temperature). Above 100% the lazer damages itself (see HeatLazerDamage, and the TURBO knobs further down for what happens past 120%).
    HeatLazerCapF       = 900,    -- degrees Fahrenheit. 100% of a lazer. Separate from HeatHotF so the two can be tuned apart (they start equal)
    HeatLazerDamage     = 4,      -- percent of the lazer's MAX HEALTH lost per second when it is twice as hot as its limit (200%). The loss grows with the SQUARE of how far over the limit it is: half as
    --                               far over (150%) = a quarter of this, 10% over = 1/100 of this. 0 = lazers never hurt themselves
    HeatExplodeChance   = 0.8,    -- 0..1. A lazer that dies from its own heat WHILE FIRING explodes with this chance; otherwise (and always when it was not firing) it just dies
    HeatExplodeKJMult   = 2,      -- the explosion's energy = this x the lazer's draw (kJ per second), turned into HE filler the way a capacitor does (kJ / ACF.HEPower, so NOT literal kg)
    HeatExplosionMult   = 1,      -- multiplier on that filler. 1 = exactly the HE equivalent; raise it for bigger bangs
    HeatDeathDebrisPower = 20000, -- [GUESS] how hard the pieces fly when a lazer simply dies of heat (not capped by anything but MaxDebrisPower)

    -- CAPACITORS: THE CRITICAL HEAT AND THE DAMAGE.
    -- A capacitor's critical heat is this share of the HOT excess (HeatHotF minus room temperature): 0.5 = it is critical at half the plate temperature rise (about 579 F with the defaults).
    -- Above it the capacitor damages itself, quadratically like the lazer. When heat kills it, it blows up like any destroyed capacitor (releasing what it stores); a damaged-but-alive
    -- capacitor also rolls its usual explosion dice (CapExplode...), because heat damage is damage.
    HeatCapCritFrac     = 0.5,
    HeatCapDamage       = 4,      -- percent of the capacitor's MAX HEALTH lost per second at twice its critical heat (200%), growing with the square of how far over it is. 0 = never


    -- TURBO DAMAGE. [CHANGED 9] Anything that damages itself from heat (lazers, capacitors; radiators no longer do) takes its normal quadratic damage (the HeatLazerDamage / HeatCapDamage knobs)
    -- AND, once it is past HeatTurboStartPct of its own limit, this on top: HeatTurboPct percent of its MAX HEALTH per second at exactly that temperature, growing with
    -- (how hot / HeatTurboStartPct) ^ HeatTurboPower. With the defaults: 120% = 20% per second (dead in 5 s), 130% = 33% (3 s), 150% = 77% (1.3 s), 200% = 430% (a fraction of a second).
    -- It is a cliff on purpose: below the start it is not there at all. A thing whose own damage knob is 0 ("never hurts itself") takes no turbo damage either.
    HeatTurboStartPct   = 120,    -- percent of the limit where the turbo damage starts
    HeatTurboPct        = 20,     -- percent of MAX health per second at exactly HeatTurboStartPct. 0 = no turbo damage at all
    HeatTurboPower      = 6,      -- how fast it grows past the start: x ((how hot) / HeatTurboStartPct) ^ this. 1 = in proportion, 6 = very steeply

    -- LAZERS SET PLAYERS ON FIRE. [CHANGED 10] A lazer (any class in HeatIgniteClasses) that is at least HeatIgniteF hot sets every player on fire whose body box touches the lazer's box.
    -- The fire is put out HeatIgniteLinger seconds after the player stops touching a hot lazer (or when the lazer cools under HeatIgniteF).
    -- [CHANGED 16] (15.4) A player SITTING IN A VEHICLE (a seat, a pod, a driver seat: whatever Player:InVehicle() counts) is the crew of what the lazer is on and is left alone (HeatIgniteSeated).
    HeatIgniteF         = 500,    -- degrees Fahrenheit. A lazer at or above this ignites players that touch it
    HeatIgniteLinger    = 1,      -- seconds the fire goes on after the player gets off the lazer
    HeatIgniteReach     = 0,      -- units. The lazer's box is grown by this much on every side before the touch test (0 = real contact only)
    HeatIgniteInterval  = 0.1,    -- seconds between the touch checks (one timer for every lazer and player)
    HeatIgniteLife      = 5,      -- seconds a fire we light is lit for in one go. We put it out ourselves at the linger time; this only matters if the check ever stopped running
    HeatIgniteClasses   = { acf_lazer = true }, -- which entities ignite players. Add acf_capacitor = true, acf_radiator = true ... if you want those to burn people too
    HeatIgniteSeated    = false, -- [CHANGED 16] false = a player sitting in a vehicle is never set on fire by a lazer (they only burn outside the vehicle); true = they burn like everyone else

    -- TESTING AID
    HeatInfoDistance    = 4096,   -- units. The console command acf_lazers_heat_info prints the heat of whatever you are looking at, up to this far away

    -- ===================== RADIATOR (the heat sink: it carries heat away from the parts around it) ===================== [CHANGED 4]
    -- WHAT IT IS. A radiator does ALL the cooling work; the parts around it hold no cooling logic at all. Every RadSweepInterval seconds it looks at the parts that are in ITS contraption
    -- (ACF's own contraption tracking, CFW) AND inside its radius, and takes heat out of the ones that are hot, up to its sap rate (kJ per second).
    --   * WHO IS A MEMBER: every entity with a physics object in the radiator's contraption and inside the radius, except players, NPCs and other radiators (a radiator never cools a radiator:
    --     a radiator that could cool itself could never overheat). The list is rebuilt when CFW says the contraption changed, when you resize or link a radiator, and every RadRefreshInterval
    --   * WHO GETS COOLED MOST: the heat is taken in proportion to how hot each part is (its temperature above room temperature ^ RadWeightPower), so a plate cooked by a lazer gives up the
    --     lion's share and the lazer behind it gets less. A part can never be cooled below room temperature: what it cannot give goes to the others
    --   * POOLS: radiators linked to each other (the link tools, right-click) are ONE pool: one combined member list (a part in range of two of them is ONE member, never cooled twice) and the
    --     sum of their sap rates. Each radiator still has its own heat and efficiency
    --   * THE RADIATOR'S OWN HEAT: working makes waste heat (RadWasteSmall .. RadWasteBig x the work it tries to do). Its 100% is the HOT temperature (HeatHotF), like a plate. It cools by itself
    --     (HeatCoolMultRad times as fast as a prop). Up to RadEffStartPct it works at full efficiency; from there its efficiency falls in a straight line to RadEffFloorPct at 100%, and it stays at
    --     that floor above 100%. [CHANGED 13] (15.4) A radiator NEVER hurts itself from heat (RadDamage is gone), and there is no overclock: the heat it eats per second is RadSapSmall .. RadSapBig.
    --     The waste comes from the work it TRIES to do, not from what it removes: a radiator that loses efficiency does not cool itself down by it
    -- "Small .. Big" pairs: the Small number is for the narrowest radiator (RadWidthMin), the Big number for the widest (RadWidthMax), in between along the size (see each knob).
    RadModel          = "models/lasers/heatsink.mdl", -- your model: a squished cube 42 wide x 42 long x 30 tall at scale 1. If the file is missing the radiator refuses to spawn and says so
    RadModelWidth     = 42,     -- units. The width (and length) of that model at scale 1. The tool slider is the WIDTH in units, and the model scale is width / this
    RadWidthMin       = 12,     -- [GUESS] narrowest radiator the tool can make (units). Scale 0.29
    RadWidthMax       = 60,     -- [GUESS] widest (units). Scale 1.43
    RadWidthDefault   = 42,     -- starting value of the tool slider (42 = the model as it is, scale 1)
    RadMassMin        = 15,     -- [GUESS] kg at RadWidthMin
    RadMassMax        = 650,    -- [GUESS] kg at RadWidthMax. In between the mass follows a power law (a straight line on log-log paper), so every width has a sensible mass. A heavier radiator
    --                             holds more heat for the same waste, so it runs cooler (the tool shows where each size settles)
    RadArmourAtOne    = 40,     -- [GUESS] mm of armour at model scale 1 (scales with the model scale, times ACF.ArmorMod)
    RadHealthMult     = 1,      -- multiplier on the health ACF works out from the surface area
    RadMaxPerPlayer   = 10,     -- default for the server variable sbox_maxacf_radiators (how many radiators one player may have)
    -- REACH AND RATE. Radius runs in a straight line along the width. The sap rate is the heat one radiator takes out per second (the "scalar" for how much heat it can eat).
    RadRadiusSmall    = 300,    -- units, for RadWidthMin
    RadRadiusBig      = 800,    -- units, for RadWidthMax
    RadSapSmall       = 1500,   -- [CHANGED 13] (15.4: 5 times the 300 of 15.3, and there is no overclock any more) kJ per second for RadWidthMin
    RadSapBig         = 125000, -- [CHANGED 13] (15.4: 5 times the 25,000 of 15.3) kJ per second for RadWidthMax. Link radiators into a pool for more
    RadSapCurve       = 1,      -- how the sap rate runs between the two: 0 = a straight line, 1 = the same power law as the mass (default), in between = a mix. With 1 a radiator of any width settles at a
    --                             similar share of its own limit; with 0 the middle widths eat a lot more than their mass can take (they run hot). Clamped to 0 .. 1
    RadWeightPower    = 1,      -- how much hotter parts are favoured: a part's share of the cooling is (its temperature above room temperature) ^ this. 0 = everyone gives equally, 1 = in proportion
    --                             to temperature (default), 2 = the hottest part takes far more
    -- THE RADIATOR'S OWN HEAT
    RadWasteSmall     = 0.01,   -- waste heat the radiator makes, as a share of the kJ it TRIES to remove (0.01 = 1%). Small: the narrowest radiator ...
    RadWasteBig       = 0.01,   -- ... and the widest. One knob per end so the two can be tuned apart
    RadEffStartPct    = 50,     -- percent of HOT where the radiator's efficiency starts to fall (below this it is 100%)
    RadEffFloorPct    = 40,     -- the efficiency (percent) it has fallen to at 100% of HOT, and keeps above that
    -- BOOKKEEPING
    RadSweepInterval  = 0.25,   -- seconds between the radiators' work (one timer for all of them). A radiator takes (rate x the time since the last one) out each time
    RadMaxDeltaTime   = 1,      -- seconds. The longest "time since the last sweep" it will act for (a lag spike cannot turn into one huge bite)
    RadRefreshInterval = 15,    -- seconds. Safety refresh: every radiator rebuilds its member list at least this often, even when no event told it to
    -- WHAT THE PLAYER SEES. The radius is drawn as a sphere around the radiator you aim at, while you hold the toolgun (any tool) and are not in a seat.
    RadDrawAimDistance = 4096,  -- units. How far away a radiator can be and still show its radius when you aim at it
    RadDrawColor      = { 255, 170, 40 }, -- red, green, blue of the sphere
    RadDrawFillAlpha  = 10,     -- 0 .. 255. How solid the inside of the sphere looks (0 = just the wire lines)
    RadDrawLines      = 24,     -- lines of the wire sphere in each direction (more = rounder, a little slower)
    -- The temperature of a plain prop (it has no hover text of its own): with the radiator tool out, look at it from RadReadoutDistance units or closer. The server answers at most every
    -- RadReadoutInterval seconds per player.
    RadReadoutDistance = 256,
    RadReadoutInterval = 0.25,

    -- COOLANT. [CHANGED 11] (15.3) Every radiator has a coolant tank. A full tank is a radiator at full strength; the less coolant it holds, the less heat it takes out (RadDryPct at empty).
    -- FLUSH (wire input Flush, any value above 0): the radiator vents its coolant as a coloured cloud of steam, with a hissing sound, and every litre that leaves carries RadFlushKJPerLiter of
    -- heat out of the hot parts around it, on top of its normal rate. A tank is refilled by an ACF SUPPLY CRATE: the radiator is registered with ACF as a fuel tank would be (the Fuel Tanks
    -- list of the supply crate: Amount, Capacity, Consume), so a supply crate within ACF.SupplyDistance tops it up exactly as it tops up a fuel tank. [GUESS] what the coolant does for the
    -- radiator: the dry strength and the heat taken by a flush are my own guesses (RadDryPct = 100 makes the tank irrelevant to the cooling, RadFlushKJPerLiter = 0 makes the flush only a show).
    RadModelLength      = 42,     -- units. The length of the model at scale 1 (RadModelWidth is its width, RadModelHeight its height). The coolant volume comes from the box they make
    RadModelHeight      = 30,     -- units. The height of the model at scale 1
    RadCoolantBoxFrac   = 1 / 8,  -- the tank holds this share of the volume of the radiator's bounding box (1/8 = 108 litres in the default 42 x 42 x 30 radiator)
    RadCoolantLitersPerUnit3 = 0.016387064, -- litres per cubic unit (ACF reads one unit as one inch: 1 cubic inch = 0.016387 litres) [SEEN acf/core/globals.lua:191, used by acf_container's CalcVolumeAndCapacity]
    RadCoolantStart     = 1,      -- how full a new radiator is (1 = full, 0 = empty)
    RadCoolantUnitMass  = 1,      -- kg per litre of coolant: what a supply crate takes out of its own stock for each litre it gives (ACF fuel is 0.7 to 0.85; water is 1)
    RadDryPct           = 25,     -- percent of its sap rate a radiator works at with an EMPTY tank. Between empty and full it is a straight line
    RadFlushFraction    = 0.5,    -- a flush vents this share of a FULL tank ...
    RadFlushSeconds     = 5,      -- ... in this many seconds (default: half the tank in 5 s, the whole tank in 10 s; the speed is the same whatever the level, so a half-full tank empties in 5 s)
    RadFlushKJPerLiter  = 125000,  -- [CHANGED 14] (15.4: was 2260, the boiling heat of water) kJ of heat each litre vented takes out of the hot parts around it. A HEAT OBLITERATOR on purpose: three 12-wide radiators
    --                             flushing for 2 seconds take a 100 mm lazer from 115% to 25% (sim/calib154.lua works it out; the radiators' own cooling is in that too). 0 = the flush takes no heat
    RadFlushPool        = false,  -- false = each radiator only flushes on its own Flush input; true = the Flush input of one radiator flushes EVERY radiator linked to it (the pool)
    RadCoolantColor     = { 90, 220, 150 }, -- red, green, blue of the coolant when the tool does not say (it is the starting colour of the tool's colour picker)
    RadPuffsPerSecond   = 45,     -- particles of steam per second while a radiator of scale 1 vents (bigger radiators puff more)
    RadPuffMaxPerFrame  = 40,     -- the most puffs one radiator makes in one frame (a slow computer must not drown in them)
    RadPuffDistance     = 3000,   -- units. A radiator further away from you than this makes no puffs on your computer
    RadPuffLife         = 1.6,    -- seconds a puff lives
    RadPuffSize         = 12,     -- units. The size of a puff when it is born at scale 1; it grows to 4 times that
    RadPuffSpeed        = 110,    -- units per second the puffs shoot out at (scale 1)
    RadPuffMaterials    = { "particle/smokesprites_0001", "particle/smokesprites_0002", "particle/smokesprites_0003", "particle/smokesprites_0004", "particle/smokesprites_0005",
                            "particle/smokesprites_0006", "particle/smokesprites_0007", "particle/smokesprites_0008", "particle/smokesprites_0009" }, -- [CHANGED 15] the sprites of the puffs, one picked at random for each.
    --                             These are the smoke sprites ACF's own explosion and smoke effects use [SEEN acf/effects/acf_smoke.lua, acf_explosion.lua], so they are in every install that runs ACF. A text instead of a list also works
    RadFlushLoopSound   = "ambient/gas/steam_loop1.wav", -- the hissing that goes on while it vents [GUESS] (an HL2 sound; "" = none). Check:  lua_run_cl print(file.Exists("sound/ambient/gas/steam_loop1.wav", "GAME"))
    RadFlushStartSound  = "ambient/gas/steam2.wav",      -- the burst when a flush starts ("" = none)
    RadFlushVolume      = 0.9,    -- 0..1
    RadFlushFadeSeconds = 0.8,    -- [CHANGED 14] seconds the burst and the hiss take to fade out when the flush ends (0 = they stop at once). Both are stopped for good a moment after the fade
    RadFlushPitchSmall  = 125,    -- the pitch of the hiss of the narrowest radiator (100 = normal) ...
    RadFlushPitchBig    = 80,     -- ... and of the widest


    -- ===================== LINKING TOOLS =====================
    -- The things the link tools (right-click / shift / reload on the lazer, capacitor and generator tools) can select and link. ACF's own link system decides which PAIRS work:
    --   engine <-> generator, generator <-> capacitor, capacitor <-> capacitor, lazer <-> capacitor, radiator <-> radiator (a pool).
    LinkClasses = { acf_lazer = "lazer", acf_capacitor = "capacitor", acf_generator = "generator", acf_engine = "engine", acf_radiator = "radiator" }, -- class -> the word used in chat messages [CHANGED 6]

    -- ===================== WOBBLE: A DAMAGED LAZER LOSES ITS AIM =====================
    -- The lower a lazer's health, the more its beam drifts away from where it points. The drift is SMOOTH (it slowly wanders around, it never
    -- jumps) and stays inside a cone around the true aim. The cone is given in MOA ("minutes of angle"): 60 MOA = 1 degree. [KNOW] 1 degree is about 17 units
    -- of sideways error per 1000 units of distance, so 180 MOA is about 52 units off at 1000 units.
    --   * Health at or above WobbleStartHealth: perfect aim. Below it, the cone grows in a straight line, reaching its full size at 0 health.
    --   * The full size of the cone depends on the lazer's size (bigger lazers suffer more): WobbleMaxMOASmall at the smallest, WobbleMaxMOABig at the biggest.
    --   * "Health" is ACF's own health fraction of the lazer (current / max), so repairing the lazer gives its aim back.
    --   The cone is the LIMIT: the beam wanders inside it and usually sits well within it (it only reaches the edge now and then).
    WobbleStartHealth = 2 / 3,  -- health fraction where the wobble begins (1 = any damage, 0.5 = at half health)
    WobbleMaxMOASmall = 120,    -- [GUESS] full cone at 0 health for the smallest lazer (120 MOA = 2 degrees)
    WobbleMaxMOABig   = 300,    -- full cone at 0 health for the biggest lazer: 300 MOA = 5 degrees (you didn't like 360). A 100 mm lazer lands near 170 MOA (about 2.9 degrees)
    WobbleMaxDegrees  = 5,      -- HARD CAP: no lazer is ever more than this many degrees off its true aim, whatever the two numbers above say
    -- HOW FAST IT DRIFTS. The speed itself wanders, smoothly and randomly, between two limits: now and then it is "slowly maneuvering",
    -- now and then it is "darting around". These are multiples of the normal drift (WobblePeriod): 1 = normal, 3 = three times as busy, 0.2 = a fifth.
    WobblePeriod      = 6,      -- [GUESS] seconds: roughly how long one slow swing takes at normal speed (x1). Bigger = lazier, smaller = busier
    WobbleSpeedSlow   = 0.2,    -- [GUESS] the slowest the drift ever gets (x0.2 = one swing per 30 s)
    WobbleSpeedFast   = 3,      -- [GUESS] the fastest ("darting"): x3 = one swing per 2 s, and its small wiggles are quicker still
    WobbleSpeedChangePeriod = 10, -- [GUESS] seconds: roughly how long the speed takes to go from calm to darting and back

    -- ===================== HIT EFFECTS (sparks / dust at the end of the beam) =====================
    -- 0.2 -> 0.05 seconds between effect bursts per lazer = 20 per second (was 5).
    -- NOTE: this only paces the VISUALS. Damage already ran every server tick and still does, so
    -- "same damage over time" is automatic. Lower it for a denser spray; it can't go faster than the server tick anyway.
    HitEffectInterval = 0.05,
    -- ACF's debris code (ACF.APKill, used when a prop dies) wants a pretend shell. Only used for the debris strength now:
    FakeShellMassPerCm3 = 0.008,  -- kg per (caliber in cm)^3.   100 mm -> 8 kg
    FakeShellSpeed      = 25000,  -- inches per second (ACF stores speeds in in/s). 25000 in/s is about 635 m/s
    MaxDebrisPower      = 65535,  -- ACF writes debris power as a 16-bit number [SEEN debris_sv.lua:16]. Don't raise this.

    -- ===================== MODEL / MUZZLE HUM =====================
    DefaultModel    = "models/lasers/laser.mdl",
    SoundFile       = "weapons/physcannon/superphys_hold_loop.wav",  -- the hum AT THE LAZER while firing
    -- The hum now follows the lazer's size, in a straight line between the two ends:
    --   smallest lazer (CaliberMin) gets the "Small" value, biggest (CaliberMax) gets the "Big" value, and everything between is a straight-line mix.
    -- Pitch is 0-255 (100 = normal; lower number = deeper); the engine cannot go above 255, init.lua clamps it. [KNOW] (GMod wiki: CSoundPatch:ChangePitch)
    -- LOUDNESS: the engine's volume only goes 0 to 1 [KNOW] (GMod wiki: CSoundPatch:ChangeVolume), and the hum was already at 1.0. So the numbers
    -- below are a "loudness" that may go above 1: init.lua gives the engine min(loudness, 1) as the volume, and turns every doubling above 1 into
    -- MuzzleDbPerDoubling extra decibels of SOUND LEVEL, which makes it carry farther (more distance before it fades). [GUESS] that SetSoundLevel works on a
    -- CreateSound; point-blank the hum can't get louder than 1.0, far away the big lazers are clearly louder.
    -- Asked: big twice as loud as small (1.0 x 2 = 2.0), then +0.4 on both = 1.4 and 2.4. (If you meant big = exactly 2 x the NEW small, make it 2.8.)
    MuzzleVolumeSmall = 1.4,    -- loudness of the smallest lazer (was 1.0)
    MuzzleVolumeBig   = 2.4,    -- loudness of the biggest lazer (was 1.0)
    MuzzleSoundLevel    = 75,   -- [GUESS] decibels the hum starts from (75 = the engine's normal level)
    MuzzleDbPerDoubling = 6,    -- [KNOW-ish] +6 dB is about twice the sound pressure; extra dB per doubling of loudness above 1.0. 0 = never use sound level
    -- +60 on both (your new sound pack). 315 is past the engine's 255 ceiling, so the smallest lazers just sit at 255 until the slide comes
    -- down under it (at about 144 mm, 44% of the way up the size range); everything bigger really is 60 higher than before.
    MuzzlePitchSmall  = 315,    -- was 255
    MuzzlePitchBig    = 180,    -- was 120

    -- ===================== END-OF-BEAM SOUNDS =====================
    -- Two looping sounds that sit AT THE END OF THE BEAM (the spot it is burning) and follow it around.
    -- They are started once when the beam starts hitting something and stopped when it stops. Nothing plays "on damage".
    -- [GUESS] every file name below: audition them in the game console with   play <path>   and swap what you don't like.
    --   other candidates to try: ambient/energy/force_field_loop1.wav   ambient/machines/combine_shield_loop3.wav
    BurnSound       = "ambient/energy/electric_loop.wav",   -- the "cutting torch" layer. Plays on any surface
    BurnVolume      = 0.6,    -- 0.0 to 1.0
    BurnPitchSmall  = 140,    -- pitch at CaliberMin (0-255, 100 = normal)
    BurnPitchBig    = 60,     -- pitch at CaliberMax. Lower number = deeper, so bigger lazers sound heavier
    BurnSoundLevel  = 80,     -- decibels: how far away you can hear it (75 is a normal prop, 90 is a loud machine)

    RumbleSound     = "physics/concrete/concrete_scrape_rough_loop1.wav", -- the "ablative" layer. ONLY plays on rock / dirt / sand...
    RumbleVolume    = 0.5,
    RumblePitchSmall = 90,    -- was 120: you said the rumble sounded high. [GUESS] how deep, tune by feel
    RumblePitchBig   = 40,    -- was 70. Very low numbers sound like slow motion; raise it if so

    EmitterModel    = "models/props_junk/PopCan01a.mdl",   -- invisible little entity that carries the two sounds to the beam end

    -- ===================== MULTIPLAYER =====================
    -- true  = every player is always told about every lazer, so a beam stays visible even when the lazer
    --         itself is behind a wall / out of their view. Costs a little network traffic per lazer.
    -- false = normal GMod behaviour (only lazers near the player are sent).
    AlwaysTransmit  = true,

    -- ===================== BEAM COLOURS =====================
    -- Each set is a list of colour stops {red, green, blue} (0-255), spread EVENLY from the smallest lazer to the biggest,
    -- and blended smoothly between neighbours. Add / remove / recolour stops freely: any number of stops works.
    -- Which set a lazer uses is its "ColorSet" flag (0 or 1), saved on the lazer and set from the tool's checkbox.
    -- A lazer can ALSO have its own custom colour (the tool's "Use custom beam colour" box); that replaces both sets.
    BeamPalettes = {
        [0] = { {255, 30, 30}, {40, 255, 60}, {0, 230, 255}, {120, 90, 255} },  -- red > green > cyan > blue-purple (between cyan and purple)
        [1] = { {255, 140, 0}, {255, 230, 0}, {30, 90, 255}, {170, 40, 255} },  -- orange > yellow > blue > purple (planned for burst lazers)
    },
    -- BeamAlphaMin (the lowest opacity a player could pick) used to be here. It is gone, and so is the opacity setting: the beam is always fully opaque
    -- (how dark the colour is decides how faint the beam looks, and a faint beam is still visible on FLIR).
    -- Where the custom colour picker starts, and what an old dupe with no custom colour gets: red, green, blue, each 0-255. (it had a fourth number, the opacity)
    CustomColorDefault = { 255, 255, 255 },
})

-- =========================================================================
-- HELPERS (shared, so the tool or HUD could use them later)
-- =========================================================================

--- Clamp a number that came from a player (tool, dupe, console) into low..high. Anything that is not a real number (nil, text, NaN, infinity) becomes `default` first.
--- math.Clamp on its own lets NaN straight through, and one NaN in a damage formula spreads to everything it touches. The server's VerifyData functions use this for every number.
function ACFLazers.ClampNumber(value, default, low, high)
    value = tonumber(value)

    if not value or value ~= value or value == math.huge or value == -math.huge then value = default end

    return math.Clamp(value, low, high)
end

--- How big the model is for a caliber. 1.0 at CaliberBase.
function ACFLazers.GetScale(caliber)
    return caliber / ACFLazers.Config.CaliberBase
end

-- NEW: 0 at the smallest lazer ... 1 at the biggest. Mass, beam colour and sound pitch all use it,
-- so "how big is this lazer, on a 0-to-1 scale" is answered in exactly ONE place.
function ACFLazers.GetSizeFraction(caliber)
    local C    = ACFLazers.Config
    local span = math.max(C.CaliberMax - C.CaliberMin, 0.0001)

    return math.Clamp((caliber - C.CaliberMin) / span, 0, 1)
end

--- Mass in kg for a caliber, from the anchors + exponent above.
function ACFLazers.GetMass(caliber)
    local C = ACFLazers.Config
    local t = ACFLazers.GetSizeFraction(caliber) -- was computed inline here

    return math.Round(C.MassMin + (C.MassMax - C.MassMin) * t ^ C.MassExponent)
end

--- The longest focal length ("max focal distance") a lazer of this caliber may use: FocalMaxFraction (3/7) of its effective range.
--- Everything about focus is measured against this one number (see GetFocalRange).
function ACFLazers.GetFocalMax(caliber)
    return ACFLazers.Config.FocalMaxFraction * ACFLazers.GetEffectiveRange(caliber)
end

--- The Focus amount slider as a fraction: 0 = the loosest end ... 1 = the sharpest end. A missing or junk value counts as FocusAmountDefault.
function ACFLazers.GetFocusFraction(amount)
    local C    = ACFLazers.Config
    local span = math.max(C.FocusAmountMax - C.FocusAmountMin, 0.0001)
    local a    = tonumber(amount)

    if not a or a ~= a then a = C.FocusAmountDefault end

    return math.Clamp((a - C.FocusAmountMin) / span, 0, 1)
end

--- The radius of the focused zone (units along the beam) for a lazer of this caliber at this Focus amount: the max focal distance at the loosest setting,
--- FocusRadiusMinFraction (1/3) of it at the sharpest, a straight line in between. So the radius grows with the lazer size.
function ACFLazers.GetFocalRange(caliber, amount)
    return ACFLazers.GetFocalMax(caliber) * Lerp(ACFLazers.GetFocusFraction(amount), 1, ACFLazers.Config.FocusRadiusMinFraction)
end

--- The shortest and longest focal length for a lazer of this caliber, in ONE place. The tool's Focal Length slider (client) and VerifyData in the lazer's init.lua
--- (server) both read it. Returns  focalMin, focalMax.  (The Focus amount has the same ends for every size: FocusAmountMin / FocusAmountMax.)
function ACFLazers.GetFocalLimits(caliber)
    local C = ACFLazers.Config

    return C.FocalMin, math.max(ACFLazers.GetFocalMax(caliber), C.FocalMin)
end

--- Sharp-focus bonus for a Focus amount: 1 (none) up to FocusBoostStart, then rising in a straight line to FocalBoostMax at the sharpest focus amount.
--- Only the centre of the curve gets it (see GetFocalFactor).
function ACFLazers.GetFocalBoost(amount)
    local C     = ACFLazers.Config
    local start = ACFLazers.GetFocusFraction(C.FocusBoostStart)
    local t     = math.Clamp((ACFLazers.GetFocusFraction(amount) - start) / math.max(1 - start, 0.0001), 0, 1)

    return Lerp(t, 1, C.FocalBoostMax)
end

--- The damage multiplier for a hit `distance` units from the muzzle, for a lazer of this caliber with this focal length and Focus amount. 1 = the normal max.
--- Centre = 1 (or the sharp-focus bonus), edge of the radius = FocalEdgeFraction, then a straight line down to FocalFarEndFraction on the far side and flat on the near side (see the comment in the config).
function ACFLazers.GetFocalFactor(focal, amount, distance, caliber)
    local C     = ACFLazers.Config
    local range = math.max(ACFLazers.GetFocalRange(caliber, amount), 0.0001)
    local near  = focal - range
    local far   = focal + range

    if distance >= near and distance <= far then
        -- inside the radius: centre (bonus) at the focal length, down to the edge value at either edge
        return Lerp(math.abs(distance - focal) / range, ACFLazers.GetFocalBoost(amount), C.FocalEdgeFraction)
    elseif distance > far then
        -- farther than the far edge: edge value down to the far-end value, straight line out to the lazer's effective range
        local t = math.Clamp((distance - far) / math.max(ACFLazers.GetEffectiveRange(caliber) - far, 0.0001), 0, 1)

        return Lerp(t, C.FocalEdgeFraction, C.FocalFarEndFraction)
    else
        -- closer than the near edge (so near > 0 here): flat at the edge value all the way to the muzzle
        return C.FocalEdgeFraction
    end
end

--- The lazer's "effective range" in units: EffectiveRangeSmall at CaliberMin ... EffectiveRangeBig at CaliberMax (a straight line between).
--- It is the distance where the damage has fallen to FalloffAtRange.
function ACFLazers.GetEffectiveRange(caliber)
    local C = ACFLazers.Config

    return Lerp(ACFLazers.GetSizeFraction(caliber), C.EffectiveRangeSmall, C.EffectiveRangeBig)
end

--- How far the beam really reaches: the distance where the falloff line hits 0 damage (a beam stops entirely there).
--- With FalloffAtRange f the line loses (1 - f) of the damage per effective range, so it reaches 0 at 1 / (1 - f) x the effective range (f = 3/4: 4 x). Never more than BeamRangeCap.
function ACFLazers.GetBeamRange(caliber)
    local C    = ACFLazers.Config
    local loss = math.max(1 - C.FalloffAtRange, 0.0001) -- the part of the damage lost by the effective range (0.25 with FalloffAtRange 3/4)

    return math.min(ACFLazers.GetEffectiveRange(caliber) / loss, C.BeamRangeCap)
end

--- The distance falloff multiplier: 1.0 at the muzzle, FalloffAtRange at the effective range, a straight line the whole way, never below 0.
function ACFLazers.GetFalloff(distance, caliber)
    local C    = ACFLazers.Config
    local loss = 1 - C.FalloffAtRange

    return math.max(0, 1 - loss * distance / math.max(ACFLazers.GetEffectiveRange(caliber), 0.0001))
end

--- The pass-through "line" (mm of armour): a plate is only burned through when its CURRENT armour is below this. At damage multiplier 1 it is
--- PenArmourFraction (1/3) x the caliber, and it follows the damage: damageMult is the same number the damage uses at the hit (the focal curve x the distance falloff,
--- ENT:CalculateDamageMult in init.lua). So a hit that does half damage has half the line, and a hit with no damage has no line. Never below 0.
function ACFLazers.GetPassLine(caliber, damageMult)
    return ACFLazers.Config.PenArmourFraction * caliber * math.max(tonumber(damageMult) or 0, 0)
end

--- The trace mask for a beam of this caliber (mm): ACF's own rule for its bullets [SEEN acf/ballistics/ballistics_sv.lua:146-150, Caliber there is in cm]. Below BeamMaskSmallBelowMM it is
--- MASK_SOLID and MASK_SHOT (no hit-boxes, grates see-through), at or above it MASK_SOLID (no hit-boxes, grates solid). MASK_SHOT alone is never used any more.
function ACFLazers.GetBeamMask(caliber)
    if (tonumber(caliber) or 0) < ACFLazers.Config.BeamMaskSmallBelowMM then
        return bit.band(MASK_SOLID, MASK_SHOT)
    end

    return MASK_SOLID
end

--- kJ per second a lazer of this caliber eats while firing. LazerDrawSmall at CaliberMin and LazerDrawBig at CaliberMax; in between it is a mix of a straight line and an
--- exponential curve, set by LazerDrawCurve (0 = all straight line, 1 = all exponential).
function ACFLazers.GetDrawRate(caliber)
    local C      = ACFLazers.Config
    local t      = ACFLazers.GetSizeFraction(caliber)
    local small  = C.LazerDrawSmall
    local big    = C.LazerDrawBig
    local linear = Lerp(t, small, big)
    local expo   = math.max(small, 1e-6) * (math.max(big, 1e-6) / math.max(small, 1e-6)) ^ t -- the same factor for every step in size
    local mix    = math.Clamp(tonumber(C.LazerDrawCurve) or 0, 0, 1)

    return Lerp(mix, linear, expo)
end

--- kJ the capacitor pool must hold before a lazer of this caliber starts (or restarts after a dud).
function ACFLazers.GetStartEnergy(caliber)
    return ACFLazers.GetDrawRate(caliber) * ACFLazers.Config.LazerStartSeconds
end

--- Prop-damage multiplier for a lazer of this caliber: SmallBoostMult up to SmallBoostFullMM, a straight line down to
--- SmallBoostEndMult at SmallBoostEndMM, and SmallBoostEndMult for everything bigger.
function ACFLazers.GetSmallDamageBoost(caliber)
    local C    = ACFLazers.Config
    local span = math.max(C.SmallBoostEndMM - C.SmallBoostFullMM, 0.0001)
    local t    = math.Clamp((caliber - C.SmallBoostFullMM) / span, 0, 1) -- 0 = full boost ... 1 = fully tapered off

    return Lerp(t, C.SmallBoostMult, C.SmallBoostEndMult)
end

-- =========================================================================
-- CAPACITOR HELPERS. Pure maths and lists: nothing here touches the game, so they are easy to test.
-- =========================================================================

--- Scale of the capacitor model for a diameter in units (1 = the model's own size).
function ACFLazers.GetCapScale(diameter)
    return diameter / ACFLazers.Config.CapModelDiameter
end

--- The capacitor's volume in cubic units: a cylinder of this diameter, as tall as the model is for its width.
function ACFLazers.GetCapVolume(diameter)
    local C      = ACFLazers.Config
    local radius = diameter / 2
    local height = diameter * C.CapModelHeight / C.CapModelDiameter

    return math.pi * radius * radius * height
end

--- Energy a capacitor of this diameter holds when full, in kJ.
function ACFLazers.GetCapCapacity(diameter)
    return ACFLazers.Config.CapEnergyPerVolume * ACFLazers.Config.CapEnergyScale * ACFLazers.GetCapVolume(diameter)
end

--- The fastest charge rate (kJ per second) a capacitor of this diameter may be set to: CapChargeRateMaxFraction (1/3) of its capacity.
--- The capacitor tool's slider (client) and VerifyData in the capacitor's init.lua (server) both read this, so they cannot disagree.
function ACFLazers.GetCapMaxChargeRate(diameter)
    return ACFLazers.GetCapCapacity(diameter) * ACFLazers.Config.CapChargeRateMaxFraction
end

--- Mass in kg of a capacitor of this diameter.
function ACFLazers.GetCapMass(diameter)
    return math.max(1, math.Round(ACFLazers.Config.CapMassPerVolume * ACFLazers.GetCapVolume(diameter)))
end

-- ===================== HEAT HELPERS (pure maths: nothing here touches the game) ===================== [CHANGED 2]

--- Fahrenheit <-> kelvin.
function ACFLazers.FToK(f) return (f - 32) * 5 / 9 + 273.15 end
function ACFLazers.KToF(k) return (k - 273.15) * 9 / 5 + 32 end

--- Room temperature in kelvin: ACF's own number if it has one (ACF.AmbientTemperature), else the HeatAmbientK knob.
function ACFLazers.GetHeatAmbientK()
    local ambient = ACF and tonumber(ACF.AmbientTemperature)

    if ambient and ambient > 0 then return ambient end -- (a NaN is not > 0, so it falls through to the knob too)

    return ACFLazers.Config.HeatAmbientK
end

--- How many kelvin above room temperature a limit typed in Fahrenheit is (never less than 1, so a silly limit cannot make every percentage infinite).
function ACFLazers.GetHeatRiseK(limitF)
    local rise = ACFLazers.FToK(tonumber(limitF) or 0) - ACFLazers.GetHeatAmbientK()

    if rise ~= rise then return 1 end

    return math.max(rise, 1)
end

--- The three "100%"s, in kelvin above room temperature: a HOT plate, a lazer's limit, a capacitor's critical heat.
function ACFLazers.GetHeatRiseHot()   return ACFLazers.GetHeatRiseK(ACFLazers.Config.HeatHotF) end
function ACFLazers.GetHeatRiseLazer() return ACFLazers.GetHeatRiseK(ACFLazers.Config.HeatLazerCapF) end
function ACFLazers.GetHeatRiseCap()   return math.max(ACFLazers.GetHeatRiseHot() * ACFLazers.Config.HeatCapCritFrac, 1) end

--- Heat capacity in kJ per kelvin of something this heavy (kg).
function ACFLazers.GetHeatCapacity(mass)
    local C = ACFLazers.Config

    mass = tonumber(mass) or 0

    if mass ~= mass then mass = 0 end

    return math.max(mass, C.HeatMinMassKg) * C.HeatSpecificHeat
end

--- The base cooling rate per second of an entity with this cooling multiplier (props 1): mult x HeatCoolSpeed / HeatCoolTau. [CHANGED 12]
function ACFLazers.GetHeatCoolRate(mult)
    local C = ACFLazers.Config

    return (tonumber(mult) or 1) * math.max(tonumber(C.HeatCoolSpeed) or 1, 0) / math.max(C.HeatCoolTau, 1e-6)
end

--- Natural cooling. theta = kelvin above room temperature now, dt = seconds, mult = the cooling multiplier of this kind of entity (props 1). Returns theta after dt.
--- The rule (see HeatCoolTau):  d(theta)/dt = -a x theta x (1 + HeatCoolHotBoost x theta / riseHot),  a = GetHeatCoolRate(mult) = mult x HeatCoolSpeed / HeatCoolTau.
--- It has an exact solution, so one call is right for any dt: a long gap costs the same as a short one and cooling in two halves gives the same answer as in one go.
function ACFLazers.HeatCool(theta, dt, mult)
    local C = ACFLazers.Config

    if not (theta and dt and theta > 0 and dt > 0) then return math.max(tonumber(theta) or 0, 0) end

    mult = tonumber(mult) or 1

    if mult <= 0 then return theta end

    local a = ACFLazers.GetHeatCoolRate(mult)

    if a <= 0 then return theta end -- (HeatCoolSpeed 0 = nothing cools by itself)

    local b = a * math.max(C.HeatCoolHotBoost, 0) / ACFLazers.GetHeatRiseHot()
    local e = math.exp(-a * dt)

    return a * theta * e / (a + b * theta * (1 - e))
end

--- Along a size: t = 0 at the smallest thing, 1 at the biggest.
local function HeatSizeLerp(t, small, big) return Lerp(math.Clamp(t, 0, 1), small, big) end

--- kJ of heat per kJ a lazer of this caliber spends / per kJ of its heat rate a beam puts into a prop / per kJ a capacitor of this diameter moves / per kJ a generator of this rating makes.
function ACFLazers.GetLazerHeatScalar(caliber) return HeatSizeLerp(ACFLazers.GetSizeFraction(caliber), ACFLazers.Config.HeatLazerSmall, ACFLazers.Config.HeatLazerBig) end
function ACFLazers.GetLazerHitHeatMult(caliber) return HeatSizeLerp(ACFLazers.GetSizeFraction(caliber), ACFLazers.Config.HeatHitSmall, ACFLazers.Config.HeatHitBig) end

function ACFLazers.GetCapHeatScalar(diameter)
    local C = ACFLazers.Config

    return HeatSizeLerp((diameter - C.CapDiameterMin) / math.max(C.CapDiameterMax - C.CapDiameterMin, 0.0001), C.HeatCapSmall, C.HeatCapBig)
end

function ACFLazers.GetGenHeatScalar(hp)
    local C = ACFLazers.Config

    return HeatSizeLerp((hp - C.GenHPMin) / math.max(C.GenHPMax - C.GenHPMin, 0.0001), C.HeatGenSmall, C.HeatGenBig)
end

--- Percent of max health lost per second at `over` (0 = right at the limit, 1 = twice the limit) for a base number (the damage knob = the loss at over 1): base x over^2. [CHANGED 9]
--- PLUS the TURBO term once the thing is past HeatTurboStartPct of its limit: HeatTurboPct x (how hot / HeatTurboStartPct) ^ HeatTurboPower, where "how hot" = 1 + over.
--- A base of 0 ("never hurts itself") gives 0 for both; at or under the limit it is 0. Used by lazers, capacitors and radiators alike, each with its own base and its own limit.
function ACFLazers.GetHeatDamagePct(over, base)
    local C = ACFLazers.Config

    over = tonumber(over) or 0

    if over ~= over or over <= 0 then return 0 end

    base = math.max(tonumber(base) or 0, 0)

    if base <= 0 then return 0 end

    local pct   = base * over * over
    local start = math.max((tonumber(C.HeatTurboStartPct) or 120) / 100, 1) -- never before the limit itself
    local hot   = 1 + over

    if hot > start then
        pct = pct + math.max(tonumber(C.HeatTurboPct) or 0, 0) * (hot / start) ^ math.max(tonumber(C.HeatTurboPower) or 0, 0)
    end

    return pct
end

--- Does an oriented box touch an axis-aligned box? (a separating axis test: the 3 + 3 face axes and the 9 edge-edge axes; touching exactly counts as touching.) Pure maths: every vector
--- is a plain {x, y, z} table. This is what decides whether a player stands in a hot lazer. [CHANGED 10]
---   ac = centre of the oriented box,  au = its three unit axes { {x,y,z}, {x,y,z}, {x,y,z} },  ae = its three half sizes along those axes
---   bc = centre of the axis-aligned box,  bh = its three half sizes along x, y, z
function ACFLazers.ObbTouchesAabb(ac, au, ae, bc, bh)
    local eps = 1e-9
    local R, AbsR, t = {}, {}, {}
    local d = { bc.x - ac.x, bc.y - ac.y, bc.z - ac.z }

    for i = 1, 3 do
        local axis = au[i]

        R[i]    = { axis.x, axis.y, axis.z } -- the oriented box's axis i, written in the world axes: R[i][j] = axis i . world axis j
        AbsR[i] = { math.abs(axis.x) + eps, math.abs(axis.y) + eps, math.abs(axis.z) + eps }
        t[i]    = d[1] * axis.x + d[2] * axis.y + d[3] * axis.z -- the centre-to-centre vector in the oriented box's frame
    end

    local bhh = { bh.x, bh.y, bh.z }
    local td  = d -- the same vector in the world frame

    -- the oriented box's own three axes
    for i = 1, 3 do
        local rb = bhh[1] * AbsR[i][1] + bhh[2] * AbsR[i][2] + bhh[3] * AbsR[i][3]

        if math.abs(t[i]) > ae[i] + rb then return false end
    end

    -- the world axes
    for j = 1, 3 do
        local ra = ae[1] * AbsR[1][j] + ae[2] * AbsR[2][j] + ae[3] * AbsR[3][j]

        if math.abs(td[j]) > ra + bhh[j] then return false end
    end

    -- the nine cross axes (axis i of the oriented box x world axis j)
    for i = 1, 3 do
        local i1, i2 = i % 3 + 1, (i + 1) % 3 + 1

        for j = 1, 3 do
            local j1, j2 = j % 3 + 1, (j + 1) % 3 + 1
            local ra     = ae[i1] * AbsR[i2][j] + ae[i2] * AbsR[i1][j]
            local rb     = bhh[j1] * AbsR[i][j2] + bhh[j2] * AbsR[i][j1]

            if math.abs(t[i2] * R[i1][j] - t[i1] * R[i2][j]) > ra + rb then return false end
        end
    end

    return true
end

--- HE filler (kg) of the explosion of a lazer that dies of heat while firing: its draw x HeatExplodeKJMult kJ, over ACF's kJ per kg of HE, x HeatExplosionMult.
function ACFLazers.GetLazerExplosionFiller(caliber)
    local C       = ACFLazers.Config
    local hePower = ACF and tonumber(ACF.HEPower) or C.HeatHEPowerFallback

    return ACFLazers.GetDrawRate(caliber) * C.HeatExplodeKJMult / math.max(hePower, 1e-6) * C.HeatExplosionMult
end

-- ===================== RADIATOR HELPERS (pure maths: nothing here touches the game) ===================== [CHANGED 5]

--- A width coming from the tool, a dupe or a console command, made safe: a whole number of units between RadWidthMin and RadWidthMax (anything that is not a number becomes RadWidthDefault).
function ACFLazers.ClampRadWidth(width)
    local C = ACFLazers.Config

    return math.Round(ACFLazers.ClampNumber(width, C.RadWidthDefault, C.RadWidthMin, C.RadWidthMax))
end

--- 0 at the narrowest radiator ... 1 at the widest. Mass, radius, sap rate and waste all use it.
function ACFLazers.GetRadSizeFraction(width)
    local C    = ACFLazers.Config
    local span = math.max(C.RadWidthMax - C.RadWidthMin, 0.0001)

    return math.Clamp(((tonumber(width) or C.RadWidthDefault) - C.RadWidthMin) / span, 0, 1)
end

--- Model scale for a width in units (1 = the model as it is).
function ACFLazers.GetRadScale(width)
    return width / math.max(ACFLazers.Config.RadModelWidth, 0.0001)
end

--- Along the size, as a power law between two ends (a straight line on log-log paper): `small` at t = 0 and `big` at t = 1, the same factor for every step.
local function RadGeometric(t, small, big)
    small = math.max(small, 1e-6)
    big   = math.max(big, 1e-6)

    return small * (big / small) ^ t
end

--- Mass in kg of a radiator this wide.
function ACFLazers.GetRadMass(width)
    local C = ACFLazers.Config

    return math.max(1, math.Round(RadGeometric(ACFLazers.GetRadSizeFraction(width), C.RadMassMin, C.RadMassMax)))
end

--- Radius in units: a straight line from RadRadiusSmall to RadRadiusBig along the width, as a WHOLE number (what the radiator reaches, what the sphere draws and what every text says
--- is the same number: a half would print differently in different places).
function ACFLazers.GetRadRadius(width)
    local C = ACFLazers.Config

    return math.Round(Lerp(ACFLazers.GetRadSizeFraction(width), C.RadRadiusSmall, C.RadRadiusBig))
end

--- kJ per second the radiator tries to take out (with a full tank). RadSapSmall at the narrowest, RadSapBig at the widest; in between a mix of a straight line and the power law (RadSapCurve).
function ACFLazers.GetRadSap(width)
    local C      = ACFLazers.Config
    local t      = ACFLazers.GetRadSizeFraction(width)
    local linear = Lerp(t, C.RadSapSmall, C.RadSapBig)
    local mix    = math.Clamp(tonumber(C.RadSapCurve) or 0, 0, 1)

    return Lerp(mix, linear, RadGeometric(t, C.RadSapSmall, C.RadSapBig))
end

--- Waste heat as a share of the kJ the radiator tries to remove.
function ACFLazers.GetRadWaste(width)
    local C = ACFLazers.Config

    return math.max(Lerp(ACFLazers.GetRadSizeFraction(width), C.RadWasteSmall, C.RadWasteBig), 0)
end

--- The radiator's efficiency (0..1) at a heat of `pct` (1 = 100% of HOT): full up to RadEffStartPct, a straight line down to RadEffFloorPct at 100%, and that floor above.
function ACFLazers.GetRadEfficiency(pct)
    local C     = ACFLazers.Config
    local start = (tonumber(C.RadEffStartPct) or 50) / 100
    local floor = math.Clamp((tonumber(C.RadEffFloorPct) or 40) / 100, 0, 1)

    pct = tonumber(pct) or 0

    if pct ~= pct or pct <= start then return 1 end
    if pct >= 1 then return floor end

    return Lerp((pct - start) / (1 - start), 1, floor)
end

--- Shares `total` among holders in proportion to their weights, but never more than a holder's limit; what a capped holder cannot take goes to the others, again by weight.
--- weights[i] > 0 and limits[i] > 0 for a holder to take part. Returns the list of takes (same order). The takes add up to min(total, sum of the limits).
function ACFLazers.WeightedFill(weights, limits, total)
    local count, takes, open = #limits, {}, {}

    for i = 1, count do
        takes[i] = 0

        if (limits[i] or 0) > 0 and (weights[i] or 0) > 0 then open[#open + 1] = i end
    end

    local left = tonumber(total) or 0

    if left ~= left then left = 0 end

    for _ = 1, count + 1 do
        if left <= 0 or #open == 0 then break end

        local sum = 0

        for _, i in ipairs(open) do sum = sum + weights[i] end

        local capped, still, used = false, {}, 0

        for _, i in ipairs(open) do
            if left * weights[i] / sum >= limits[i] then
                takes[i] = limits[i] -- this one gives all it has
                used     = used + limits[i]
                capped   = true
            else
                still[#still + 1] = i
            end
        end

        if not capped then
            for _, i in ipairs(open) do takes[i] = left * weights[i] / sum end

            break
        end

        left = left - used
        open = still
    end

    return takes
end

--- One step of a radiator pool. items[i] = { sap = kJ per second radiator i tries to take out (its sap rate x the strength its tank gives it), eff = its efficiency 0..1 }.
--- avail = kJ of heat the members hold. dt = seconds. Every radiator tries its full rate; what it really takes out is its rate x its efficiency. When the members hold less than
--- the radiators could take, all of them do proportionally less work (and so make proportionally less waste).
--- Returns the total kJ removed, and per item { work = kJ of effort (what the waste is a share of), removed = kJ it took out }.
function ACFLazers.RadPoolStep(items, avail, dt)
    local capacity = 0

    for _, item in ipairs(items) do
        capacity = capacity + math.max(item.sap, 0) * math.Clamp(item.eff, 0, 1) * dt
    end

    local k = 0

    if capacity > 0 then k = math.min(1, math.max(avail, 0) / capacity) end

    local out, total = {}, 0

    for i, item in ipairs(items) do
        local work    = math.max(item.sap, 0) * dt * k
        local removed = work * math.Clamp(item.eff, 0, 1)

        out[i] = { work = work, removed = removed }
        total  = total + removed
    end

    return total, out
end

--- The heat (kelvin above room temperature) at which a body of this heat capacity (kJ per kelvin) loses exactly `waste` kJ per second to natural cooling, with the cooling multiplier of
--- its kind. Solves  waste = capacity x a x theta x (1 + boost x theta / hot)  (the cooling law of ACFLazers.HeatCool).
function ACFLazers.GetCoolingSettleK(waste, capacity, mult)
    local C = ACFLazers.Config

    waste = math.max(tonumber(waste) or 0, 0)

    local a = math.max(ACFLazers.GetHeatCoolRate(mult), 1e-12)
    local p = math.max(capacity, 1e-9) * a
    local q = p * math.max(C.HeatCoolHotBoost, 0) / ACFLazers.GetHeatRiseHot()

    if q <= 1e-12 then return waste / p end

    return (-p + math.sqrt(p * p + 4 * q * waste)) / (2 * q)
end

--- What the tool shows for a width: the numbers of the radiator. Everything is worked out with the same functions the radiator uses.
--- `settle` = where its own heat levels off (percent of HOT as a fraction, 1 = 100%) when it works flat out for ever, `eff` = its efficiency there, `net` = the kJ/s it takes out then.
function ACFLazers.GetRadReadout(width)
    local C        = ACFLazers.Config
    local w        = ACFLazers.ClampRadWidth(width)
    local mass     = ACFLazers.GetRadMass(w)
    local capacity = ACFLazers.GetHeatCapacity(mass)
    local sap      = ACFLazers.GetRadSap(w)
    local waste    = ACFLazers.GetRadWaste(w)
    local settle   = ACFLazers.GetCoolingSettleK(sap * waste, capacity, C.HeatCoolMultRad) / ACFLazers.GetHeatRiseHot()
    local eff      = ACFLazers.GetRadEfficiency(settle)
    local show     = { width = w, scale = ACFLazers.GetRadScale(w), mass = mass, capacity = capacity, radius = ACFLazers.GetRadRadius(w), sap = sap, wasteFrac = waste, settle = settle, eff = eff, net = sap * eff }

    -- [CHANGED 11] the tank: litres, how fast a flush empties it, and the extra kJ/s a flush takes out of the hot parts while it lasts
    show.liters    = ACFLazers.GetRadCoolantCapacity(w)
    show.flushRate = ACFLazers.GetRadFlushRate(show.liters)
    show.flushKJ   = show.flushRate * math.max(C.RadFlushKJPerLiter, 0)

    return show
end

-- ===================== RADIATOR COOLANT HELPERS (pure maths: nothing here touches the game) ===================== [CHANGED 11]

--- Litres a FULL tank of a radiator this wide holds: RadCoolantBoxFrac of the volume of its bounding box. The box is RadModelWidth x RadModelLength x RadModelHeight units at scale 1
--- and grows with the cube of the scale; a cubic unit is RadCoolantLitersPerUnit3 litres (ACF reads a unit as an inch).
function ACFLazers.GetRadCoolantCapacity(width)
    local C      = ACFLazers.Config
    local scale  = ACFLazers.GetRadScale(ACFLazers.ClampNumber(width, C.RadWidthDefault, 0, math.huge))
    local volume = C.RadModelWidth * C.RadModelLength * C.RadModelHeight * scale * scale * scale

    return math.max(volume * C.RadCoolantBoxFrac * C.RadCoolantLitersPerUnit3, 0) -- (a knob below 0 gives no tank)
end

--- Litres per second a flush vents for a tank of this capacity: RadFlushFraction of a FULL tank every RadFlushSeconds. The speed is the same whatever the level (a half-full tank
--- empties in half the time), so it is a constant for the radiator.
function ACFLazers.GetRadFlushRate(capacity)
    local C = ACFLazers.Config

    return math.max(tonumber(capacity) or 0, 0) * math.max(C.RadFlushFraction, 0) / math.max(C.RadFlushSeconds, 1e-6)
end

--- How strong the radiator works (0..1 of its sap rate) with a tank that is `fill` full (0 = empty, 1 = full): a straight line from RadDryPct percent up to 100%.
function ACFLazers.GetRadCoolantMult(fill)
    local C   = ACFLazers.Config
    local dry = math.Clamp((tonumber(C.RadDryPct) or 0) / 100, 0, 1)

    return dry + (1 - dry) * ACFLazers.ClampNumber(fill, 0, 0, 1)
end

--- A coolant colour from the tool, a dupe or the config made safe: three whole numbers from 0 to 255. Anything that is not a number takes the matching channel of RadCoolantColor.
function ACFLazers.ClampRadColor(r, g, b)
    local d = ACFLazers.Config.RadCoolantColor

    if type(d) ~= "table" then d = { 90, 220, 150 } end

    return math.Round(ACFLazers.ClampNumber(r, tonumber(d[1]) or 90, 0, 255)),
           math.Round(ACFLazers.ClampNumber(g, tonumber(d[2]) or 220, 0, 255)),
           math.Round(ACFLazers.ClampNumber(b, tonumber(d[3]) or 150, 0, 255))
end

-- The sprites ACF's own smoke effects use: what a bad RadPuffMaterials falls back to.
local RAD_PUFF_DEFAULT = { "particle/smokesprites_0001", "particle/smokesprites_0002", "particle/smokesprites_0003", "particle/smokesprites_0004", "particle/smokesprites_0005",
                           "particle/smokesprites_0006", "particle/smokesprites_0007", "particle/smokesprites_0008", "particle/smokesprites_0009" }

--- The sprite of one puff: a pick from RadPuffMaterials (`r` is a random number from 0 up to 1, so the pick can be tested). A text instead of a list is that one sprite; a knob that is not
--- a list, an empty list, or an entry that is not a text falls back to ACF's own smoke sprites.
function ACFLazers.PickRadPuffMaterial(r)
    local list = ACFLazers.Config.RadPuffMaterials

    if isstring(list) then list = { list } end
    if not istable(list) or #list == 0 then list = RAD_PUFF_DEFAULT end

    local entry = list[math.Clamp(1 + math.floor((tonumber(r) or 0) * #list), 1, #list)]

    if isstring(entry) and entry ~= "" then return entry end

    return RAD_PUFF_DEFAULT[1]
end

--- The pitch (100 = normal) of the steam hiss of a radiator this wide: a straight line from RadFlushPitchSmall (narrowest) to RadFlushPitchBig (widest), kept in the range a sound can have.
function ACFLazers.GetRadFlushPitch(width)
    local C = ACFLazers.Config

    return math.Clamp(Lerp(ACFLazers.GetRadSizeFraction(width), tonumber(C.RadFlushPitchSmall) or 100, tonumber(C.RadFlushPitchBig) or 100), 1, 255)
end

--- The steam colour as ONE whole number for the network (the client gets a single value): red * 65536 + green * 256 + blue. The inputs are made safe first.
function ACFLazers.PackRadColor(r, g, b)
    r, g, b = ACFLazers.ClampRadColor(r, g, b)

    return r * 65536 + g * 256 + b
end

--- The reverse of PackRadColor: red, green, blue (0..255 each). Anything that is not a number comes out as the default colour.
function ACFLazers.UnpackRadColor(packed)
    local n = tonumber(packed)

    if not n or n ~= n or n < 0 or n > 16777215 then return ACFLazers.ClampRadColor(nil, nil, nil) end

    n = math.floor(n)

    return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

--- How many puffs of steam a radiator of this scale makes in a frame of `dt` seconds, and the fraction of a puff that carries over to the next frame (give the carry back next time).
--- RadPuffsPerSecond puffs a second at scale 1, in proportion to the scale; never more than RadPuffMaxPerFrame in one frame (the puffs a slow frame cannot make are not made up for).
function ACFLazers.GetRadPuffs(scale, dt, carry)
    local C     = ACFLazers.Config
    local rate  = math.max(tonumber(C.RadPuffsPerSecond) or 0, 0) * math.max(tonumber(scale) or 0, 0)
    local total = ACFLazers.ClampNumber(carry, 0, 0, 1) + rate * ACFLazers.ClampNumber(dt, 0, 0, 0.25) -- (the carry is a fraction of a puff: anything else is forgotten)

    if total ~= total or total < 0 then total = 0 end

    local whole = math.floor(total)

    return math.min(whole, math.max(math.floor(tonumber(C.RadPuffMaxPerFrame) or 0), 0)), total - whole
end

-- ===================== GENERATOR HUB HELPERS (pure maths: nothing here touches the game) =====================

--- A rated power coming from the tool, a dupe or a console command, made safe: a whole number of hp between GenHPMin and GenHPMax (anything that is not a number becomes GenHPDefault).
function ACFLazers.ClampGenHP(hp)
    local C = ACFLazers.Config

    return math.Round(ACFLazers.ClampNumber(hp, C.GenHPDefault, C.GenHPMin, C.GenHPMax))
end

--- Model scale for a rated power. Passes through every knot of GenScaleKnots exactly; between two knots it is a power law (a straight line on log-log paper).
function ACFLazers.GetGenScale(hp)
    local knots = ACFLazers.Config.GenScaleKnots
    local count = #knots

    hp = math.Clamp(tonumber(hp) or knots[1][1], knots[1][1], knots[count][1])

    for i = 1, count - 1 do
        local a, b = knots[i], knots[i + 1]

        if hp <= b[1] then
            local t = (math.log(hp) - math.log(a[1])) / (math.log(b[1]) - math.log(a[1]))

            return math.exp(math.log(a[2]) + t * (math.log(b[2]) - math.log(a[2])))
        end
    end

    return knots[count][2]
end

--- Mass in kg of a generator with this rated power.
function ACFLazers.GetGenMass(hp)
    local C = ACFLazers.Config

    return math.max(1, math.Round(C.GenMassAtOne * ACFLazers.GetGenScale(hp) ^ C.GenMassExponent))
end

--- kW -> hp the way the generator counts it: ACF's own conversion (ACF.KwToHp) times GenEngineHPMult.
function ACFLazers.GetGenHP(kW)
    local C = ACFLazers.Config

    return kW * ((ACF and ACF.KwToHp) or C.GenKwToHp) * C.GenEngineHPMult
end

--- Torque (Nm) the generator takes from ONE engine this tick. draw = the Draw input as a fraction (0..1), rpm = the engine's flywheel rpm right now,
--- peakKW / peakRPM = the engine's PeakPower / PeakPowerRPM (ACF works them out for every engine from its torque curve). See the notes at GenLoadStrength.
function ACFLazers.GetGenLoadTorque(draw, rpm, peakKW, peakRPM)
    local C = ACFLazers.Config

    if not (draw and rpm and peakKW and peakRPM) then return 0 end
    if draw <= 0 or rpm <= 0 or peakKW <= 0 or peakRPM <= 0 then return 0 end

    local reference = peakKW * C.GenKwRpmConstant / peakRPM -- the torque the engine makes at its peak power

    return draw * C.GenLoadStrength * reference * (rpm / peakRPM) ^ C.GenLoadExponent
end

--- kJ stored when `kW` of engine power is taken for `seconds`.
function ACFLazers.GetGenEnergy(kW, seconds)
    return ACFLazers.GetGenHP(kW) * ACFLazers.Config.GenKJPerHP * seconds
end

--- Energy multiplier of a generator for its health. health = ACF health as a fraction of max health (0..1). 1 at full health, GenDamagedEfficiency at none.
function ACFLazers.GetGenEfficiency(health)
    local C = ACFLazers.Config

    health = tonumber(health) or 1

    -- NaN is the one number that is not equal to itself; math.Clamp lets it through, so catch it here (counts as undamaged).
    if health ~= health then health = 1 end

    return Lerp(math.Clamp(health, 0, 1), C.GenDamagedEfficiency, 1)
end

--- Everything the generator tool shows for a rated power (the slider): the energy per second the hub makes while it takes its whole rating at full health and at no health,
--- and how long that takes to fill the reference capacitor (GenToolCapSize). Plain numbers, so the tool's panel, the toolgun screen and the tests all read the same thing.
function ACFLazers.GetGenReadout(hp)
    local C = ACFLazers.Config

    hp = ACFLazers.ClampGenHP(hp)

    local effHurt  = ACFLazers.GetGenEfficiency(0)
    local rate     = hp * C.GenKJPerHP * ACFLazers.GetGenEfficiency(1)
    local rateHurt = hp * C.GenKJPerHP * effHurt
    local capacity = ACFLazers.GetCapCapacity(C.GenToolCapSize)

    return {
        hp                 = hp,
        scale              = ACFLazers.GetGenScale(hp),
        mass               = ACFLazers.GetGenMass(hp),
        kjPerHP            = C.GenKJPerHP,
        rate               = rate,                                   -- kJ/s at full health
        rateDamaged        = rateHurt,                               -- kJ/s with no health left
        efficiencyDamaged  = effHurt,
        capSize            = C.GenToolCapSize,
        capacity           = capacity,                               -- kJ the reference capacitor holds
        fillSeconds        = capacity / math.max(rate, 1e-6),        -- at full health
        fillSecondsDamaged = capacity / math.max(rateHurt, 1e-6),
    }
end

--- Chance (0..1) that a capacitor explodes when it is damaged but not destroyed.
--- charge = stored energy as a fraction of capacity (0..1); health = ACF health as a fraction of max health (0..1).
function ACFLazers.GetCapExplodeChance(charge, health)
    local C = ACFLazers.Config

    if charge < C.CapExplodeMinCharge then return 0 end

    local ramp = math.max(C.CapExplodeRamp, 0.0001)
    local t    = math.Clamp((charge - health) / ramp, 0, 1) -- 0 while the charge is under the health, 1 once it is `ramp` above it

    return Lerp(t, C.CapExplodeChanceBase, C.CapExplodeChanceMax)
end

--- kJ an exploding capacitor releases. roll = a random number 0..1 (0 = the lowest share, 1 = the highest). Never less than CapReleaseMinKJ, so never 0.
function ACFLazers.GetCapRelease(charge, roll)
    local C = ACFLazers.Config

    return math.max(charge * Lerp(roll, C.CapReleaseMinFraction, C.CapReleaseMaxFraction), C.CapReleaseMinKJ)
end

--- Splits `amount` between several sources that each can give at most limits[i]. Everyone gives the same share; a source that cannot give a full share
--- gives all it has, and what it was short is shared out among the others (again equally, again with the same rule).
--- Returns  takes (a list, same order as limits)  and  total (how much was really taken: the smaller of `amount` and the sum of all limits).
--- Used for a lazer drawing from several capacitors AND for a dumping capacitor filling several others (there the limits are "how much each can accept").
function ACFLazers.WaterFill(limits, amount)
    local count     = #limits
    local takes     = {}
    local order     = {}
    local wanted    = math.max(amount, 0)
    local remaining = wanted

    for i = 1, count do
        takes[i] = 0
        order[i] = i
    end

    -- the smallest limits first: they are the ones that may not manage a full share
    table.sort(order, function(a, b) return limits[a] < limits[b] end)

    for k = 1, count do
        local i     = order[k]
        local share = remaining / (count - k + 1)
        local take  = math.min(math.max(limits[i], 0), share)

        takes[i]  = take
        remaining = remaining - take
    end

    return takes, wanted - remaining
end

--- Every capacitor connected to the ones in `starts` (a set: key = capacitor), through capacitor-to-capacitor links, as a list. The starting ones are included.
--- Capacitors that no longer exist are skipped. Each capacitor keeps its neighbours in its CapLinks set.
function ACFLazers.GetCapGroup(starts)
    local seen, list = {}, {}

    for cap in pairs(starts) do
        if IsValid(cap) and not seen[cap] then
            seen[cap] = true
            list[#list + 1] = cap
        end
    end

    local head = 1

    while head <= #list do
        local cap = list[head]

        head = head + 1

        for other in pairs(cap.CapLinks or {}) do
            if IsValid(other) and not seen[other] then
                seen[other] = true
                list[#list + 1] = other
            end
        end
    end

    return list
end

--- How far off its true aim this lazer's beam may drift right now, in DEGREES (the cone's size).
--- healthFraction: 1 = full health ... 0 = dead. 0 degrees until health falls under WobbleStartHealth, then a straight line up to the full size for this caliber.
function ACFLazers.GetWobbleCone(caliber, healthFraction)
    local C        = ACFLazers.Config
    local start    = math.max(C.WobbleStartHealth, 0.0001)
    local severity = math.Clamp((start - healthFraction) / start, 0, 1) -- 0 = healthy ... 1 = dead
    local maxMOA   = Lerp(ACFLazers.GetSizeFraction(caliber), C.WobbleMaxMOASmall, C.WobbleMaxMOABig)

    -- 60 MOA = 1 degree; and never past the hard cap, whatever the knobs say
    return math.min(severity * maxMOA / 60, C.WobbleMaxDegrees)
end

--- A smooth, never-jumping, never-quite-repeating wander. Returns two numbers u, v: where inside the cone the aim is right now,
--- as a share of the cone (the point (u, v) is always inside a circle of radius 1: 0,0 = straight ahead, 1,0 = the cone's edge).
--- It is a pure function of the time and the lazer's own seed (a number that is just different per lazer, so two lazers never wobble in step):
--- each axis is three slow sine waves of different speeds added together. Nothing has to be stored or stepped from tick to tick.
--- THE SPEED ITSELF WANDERS. Instead of reading the waves at the real time, we read them at a "stretched clock" that runs fast
--- sometimes (darting) and slow other times (maneuvering). A clock's speed is the slope of its reading, so we pick a smooth speed first
--- (between WobbleSpeedSlow and WobbleSpeedFast, itself a slow wave) and use the exact running total of that speed as the clock (the total of a sine
--- is a cosine, so it is a plain formula and still needs no stored state). The clock never jumps and never runs backwards, so the aim never jumps either.
function ACFLazers.GetWobblePoint(seed, time)
    local C  = ACFLazers.Config
    local sw = 2 * math.pi / math.max(C.WobbleSpeedChangePeriod, 0.5) -- how quickly the speed itself changes, as radians per second
    local p1, p2 = seed * 7.1, seed * 1.9                              -- this lazer's own start of the two speed waves
    local w2 = sw * 1.37                                               -- the second speed wave is a bit faster, so the pattern never repeats

    -- m = the speed wave, between -1 (slowest) and +1 (fastest); bigM = its running total since time 0 (the integral of m)
    local m    = 0.7 * math.sin(sw * time + p1) + 0.3 * math.sin(w2 * time + p2)
    local bigM = -0.7 * math.cos(sw * time + p1) / sw - 0.3 * math.cos(w2 * time + p2) / w2

    local mid  = (C.WobbleSpeedFast + C.WobbleSpeedSlow) / 2
    local half = (C.WobbleSpeedFast - C.WobbleSpeedSlow) / 2

    -- the stretched clock: its speed (slope) is mid + half * m, which always stays between WobbleSpeedSlow and WobbleSpeedFast
    local t = (mid * time + half * bigM) * 2 * math.pi / math.max(C.WobblePeriod, 0.1)

    -- Different speeds (1, 1.73, 2.91 ... ) so the three waves never line up again; any seed works as a starting phase.
    local u = 0.5 * math.sin(t * 1.00 + seed)       + 0.3 * math.sin(t * 1.73 + seed * 2.3) + 0.2 * math.sin(t * 2.91 + seed * 3.7)
    local v = 0.5 * math.sin(t * 1.27 + seed * 4.1) + 0.3 * math.sin(t * 2.11 + seed * 5.3) + 0.2 * math.sin(t * 3.37 + seed * 6.9)

    -- each axis alone stays within -1..1, but together they can poke out of the circle (a square's corner): pull those back in
    local len = math.sqrt(u * u + v * v)

    if len > 1 then
        u, v = u / len, v / len
    end

    return u, v
end

--- The stand-in "AP shell" for a caliber. Returns: diameter in cm, mass in kg, speed in in/s.
--- (ACF's debris code works in cm, kg and in/s.)
function ACFLazers.GetFakeShell(caliber)
    local C  = ACFLazers.Config
    local cm = caliber * 0.1

    return cm, cm ^ 3 * C.FakeShellMassPerCm3, C.FakeShellSpeed
end

-- NEW: what kind of surface is this? The server uses it to decide whether to play the rumble, and the
-- hit effect uses it to decide between sparks-only and dust. The MAT_* names are the same ones ACF's own
-- effects use ([SEEN] acf/core/utilities/effects/effects_cl.lua:4-19, effects/acf_penetration.lua:11-17).
local EarthMaterials = {
    [MAT_CONCRETE] = true,
    [MAT_TILE]     = true,
    [MAT_DIRT]     = true,
    [MAT_GRASS]    = true,
    [MAT_SAND]     = true,
    [MAT_SNOW]     = true,
}

--- "earth" = rock / asphalt / dirt / sand / grass / snow.  "hard" = everything else (metal, props, plastic ...).
function ACFLazers.GetSurfaceClass(matType)
    return EarthMaterials[matType] and "earth" or "hard"
end

-- The colour of a beam. size (caliber) picks the spot along the palette; colorSet (0/1, or false/true) picks the palette.
--   override = OPTIONAL Color. If given, it replaces the palette entirely. cl_init.lua passes the lazer's custom colour when its UseCustomColor is on.
-- The colour is always fully opaque (alpha 255): the opacity setting is gone.
-- A lazer on the palettes passes no override.
function ACFLazers.GetBeamColor(caliber, colorSet, override)
    local C = ACFLazers.Config
    local red, green, blue

    if override then
        red, green, blue = override.r, override.g, override.b
    else
        local palette = C.BeamPalettes[(colorSet == true or colorSet == 1) and 1 or 0]
        local count   = #palette
        local spot    = ACFLazers.GetSizeFraction(caliber) * (count - 1)  -- 0 = first stop ... count-1 = last stop
        local index   = math.min(math.floor(spot) + 1, count - 1)         -- the stop just before us
        local mix     = spot - (index - 1)                                -- how far we are towards the next stop (0..1)
        local from, to = palette[index], palette[index + 1]

        red   = Lerp(mix, from[1], to[1])
        green = Lerp(mix, from[2], to[2])
        blue  = Lerp(mix, from[3], to[3])

        -- Blending two bright colours can give a dull one halfway (red + green = muddy olive). Scaling so the strongest channel is full
        -- keeps every blend as bright as the stops themselves (that olive becomes a clean yellow).
        local strongest = math.max(red, green, blue)

        if strongest > 0 then
            local boost = 255 / strongest

            red, green, blue = red * boost, green * boost, blue * boost
        end
    end

    return Color(math.Round(red), math.Round(green), math.Round(blue), 255)
end

-- How long a fire lasts, in seconds, for a lazer of this caliber: BurnTimeMin at startCaliber up to BurnTimeMax at CaliberMax
-- (a straight line between). startCaliber is optional and defaults to CaliberMin (that is the wooden-prop scale).
function ACFLazers.GetBurnSeconds(caliber, startCaliber)
    local C = ACFLazers.Config

    startCaliber = startCaliber or C.CaliberMin

    local span = math.max(C.CaliberMax - startCaliber, 0.0001)
    local t    = math.Clamp((caliber - startCaliber) / span, 0, 1)

    return Lerp(t, C.BurnTimeMin, C.BurnTimeMax)
end

-- Which surfaces catch fire. Wood only for now; add other MAT_* names to the list (MAT_FOLIAGE? MAT_PLASTIC?) if you want more.
local FlammableMaterials = {
    [MAT_WOOD] = true,
}

--- Explosive props (barrels, gas cans, propane tanks ...) are recognised by their MODEL NAME: if the lowercase model path contains
--- any of these pieces of text, the prop counts as explosive and burns like wood. [GUESS] my list of the usual Half-Life 2 explosive models; add your own.
ACFLazers.ExplosiveModelPatterns = ACFLazers.ExplosiveModelPatterns or {}
table.Empty(ACFLazers.ExplosiveModelPatterns)
table.Add(ACFLazers.ExplosiveModelPatterns, {
    "explosive",   -- oildrum001_explosive (props_c17 and props_phx), explosive_butane_can, ...
    "gascan",      -- props_junk/gascan001a
    "propane",     -- props_junk/propane_tank001a, PropaneCanister001a, firetrap_propanecanister01a
    "butane",
})

--- Is this prop explosive? Server side. The answer is remembered on the entity (the model never changes, and GetKeyValues builds a table every call).
--- Second check: a prop that has an "ExplodeDamage" key value above 0 (what the engine uses for breakable explosive props) [GUESS that GetKeyValues shows it].
function ACFLazers.IsExplosiveProp(ent)
    if not IsValid(ent) then return false end

    local cached = ent.ACFLazers_Explosive

    if cached ~= nil then return cached end

    local result = false
    local model  = string.lower(ent:GetModel() or "")

    for _, piece in ipairs(ACFLazers.ExplosiveModelPatterns) do
        if string.find(model, piece, 1, true) then -- true = plain text search, not a pattern
            result = true
            break
        end
    end

    if not result then
        local ok, kv = pcall(ent.GetKeyValues, ent)

        if ok and istable(kv) and (tonumber(kv.ExplodeDamage) or tonumber(kv.explodedamage) or 0) > 0 then
            result = true
        end
    end

    ent.ACFLazers_Explosive = result

    return result
end

--- Does a hit on this surface (and this prop) start a fire? Wood by surface material; explosive props by their model, whatever they are made of.
function ACFLazers.IsFlammable(matType, ent)
    if FlammableMaterials[matType] == true then return true end

    return ent ~= nil and ACFLazers.IsExplosiveProp(ent)
end
