-- =========================================================================
-- THE GAUSS RIFLE'S WEAPON CLASS  (23)
-- Goes to:  lua/acf/entities/weapons/lazers_gauss.lua      (NEW FILE. ACF loads every file of that folder in every addon, server and client, with no AddCSLuaFile needed)
--
-- ACF's ammo crates are built around a "weapon class": the crate asks it for the caliber range and the size of a round, and the ammo type asks it for the length of the projectile. The gauss rifle is
-- not an ACF gun (it is our own entity, acf_gauss), but its ammo box IS an ACF ammo crate, so the rifle needs a class of its own for the crate to work from.
--
--   * The class lives in its OWN list ("LazerWeapons", config GaussRegistry), not in ACF's weapon list. ACF's weapon menu is built from ACF's list, so the rifle never shows up there (a gun spawned from
--     that menu would not be a gauss rifle). ACF.AddWeaponrySource tells ACF's crate code (and the ammo types' blacklists) that the list exists.
--   * Caliber range and size: the config's Gauss knobs (GaussCaliberMin .. GaussCaliberMax mm, base GaussCaliberBase). Round = how long a round may be: MaxLength 100 cm at the base caliber, growing with it,
--     so a round is never longer than 10 calibers; PropLength is a nominal 1 cm (the DART has no propellant at all: lazers_dart.lua zeroes it).
--   * A crate made for this class can only hold the DART (the one ammo type of the rifle: lazers_dart.lua): the hook at the bottom changes anything else to it before the crate is built or updated.
-- =========================================================================

local ACF     = ACF
local Classes = ACF.Classes

local REGISTRY = (ACFLazers and ACFLazers.GaussRegistry) or "LazerWeapons"
local ID       = (ACFLazers and ACFLazers.GaussClassID) or "LazerGauss"
local DART     = (ACFLazers and ACFLazers.GaussAmmoID) or "LazerDart"

-- Our own list of weapon classes, built the way ACF builds its own (acf/core/classes/weapons/registration.lua). Kept across reloads: the stored entries are reused.
local Namespace = Classes[REGISTRY] or {}

Classes[REGISTRY] = Namespace

local Entries = Classes.GetOrCreateEntries(Namespace)

function Namespace.Register(GroupID, Data)
    return Classes.AddGroup(GroupID, Entries, Data)
end

function Namespace.RegisterItem(ItemID, GroupID, Data)
    local Class = Classes.AddGroupItem(ItemID, GroupID, Entries, Data)

    if Class then Class.Destiny = REGISTRY end

    return Class
end

Classes.AddGroupedFunctions(Namespace, Entries)

ACF.AddWeaponrySource(REGISTRY) -- ACF's crate code finds the class through this (ACF.FindWeaponrySource), and the ammo types' blacklists cover it

local Config = ACFLazers or {}

local function Number(name, default)
    if Config.GaussNumber then return Config.GaussNumber(name) end

    return default
end

Namespace.Register(ID, {
    Name        = "Gauss Rifle",
    Description = "The gauss rifle of the LaZers addon. It fires DART rounds from ammo boxes of darts.",
    Model       = (Config.GaussString and Config.GaussString("GaussModel")) or "models/lasers/gauss.mdl",
    IsScalable  = true,
    Mass        = 1000,
    DefaultAmmo = DART,
    Caliber     = {
        Base = Number("GaussCaliberBase", 100),
        Min  = Number("GaussCaliberMin", 30),
        Max  = Number("GaussCaliberMax", 300),
    },
    Round       = {
        MaxLength  = 100,
        PropLength = 1,
    },
})

-- A crate of this class holds DARTs and nothing else. ACF runs this hook at the end of its own data check, for a new crate and for an update, BEFORE it looks the ammo type up (so what it sets is
-- what the crate is built from). The type is forced, and the DART's own data check is run on the data too, so a crate that was asked for something else (a dupe, a console command) comes out the
-- same as one made by the tool: the caliber inside the rifle's range, the DART's length, no propellant.
hook.Add("ACF_OnVerifyData", "ACFLazers_GaussCrateAmmo", function(Name, Data, Class)
    if Name ~= "acf_ammo" or not istable(Data) or not istable(Class) then return end
    if Class.ID ~= ID then return end

    Data.AmmoType = DART

    local Dart = Classes.AmmoTypes and Classes.AmmoTypes.Get(DART)

    if Dart and Dart.VerifyData then Dart:VerifyData(Data, Class) end
end)
