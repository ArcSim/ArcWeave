-- Arc Weave - weave abilities and pet commands into your swing rhythm.
--
-- Two engines that used to be their own addons live here side by side:
--   AW_Swing.lua  (was Arc Next Swing) - next-melee cooldowns projected onto
--                 Blizzard's swing timer: "when is Raptor Strike back, and on
--                 which swing?"
--   AW_Pet.lua    (was Arc Pet Attack) - picked abilities also send the pet,
--                 and/or arm a next-weapon-attack ability, on click and keybind.
--
-- THIS FILE RUNS FIRST and exists for one reason: every file of an addon is
-- handed the SAME shared table, and both engines define OnReady, PaintMinimap,
-- GetDB and other identically-named hooks. Each engine points its own `NS`
-- local at one of the sub-tables below, so the two can never overwrite each
-- other and neither engine needed rewriting to move in here.
--
--   AW.Swing   the swing engine's namespace
--   AW.Pet     the pet / queue engine's namespace
--   AW.AT      the shared theme (set by AW_Theme.lua)
--
-- SavedVariables:
--   ArcWeaveDB       account-wide - swing markers, tracked spells, panel scale
--   ArcWeaveCharDB   per character - picked abilities (they are per character)
-- Both adopt an old ArcNextSwingDB / ArcPetAttackDB profile on first load, and
-- only ever into a table that is still empty.

local ADDON, AW = ...

AW.Swing = AW.Swing or {}
AW.Pet = AW.Pet or {}

AW.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata
    and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or nil
