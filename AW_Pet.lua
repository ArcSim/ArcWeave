-- ArcPetAttack - picked action buttons ALSO send your pet to attack, on
-- mouse clicks and on keybinds. The spell on the button still casts normally.
--
-- HOW IT WORKS (every piece verified against the Forever 1.60.1 client source):
--  * Sending the pet is PROTECTED (PetAttack), so it can only ride a secure
--    button. Each picked Blizzard action button gets a child
--    SecureActionButtonTemplate "overlay" of type macro:
--        /petattack [pet,@target,harm,nodead]
--        /click <Button> <mouse> 1     (down)
--        /click <Button> <mouse> 0     (up)
--    The down+up pair mirrors a real key press. SecureActionButton_OnClick
--    fires a scripted /click on DOWN when "cast on key down" is on and on UP
--    when it is off, so exactly one of the two casts in either setting and the
--    other is a no-op. A plain "/click X" (up only) does NOTHING with key-down
--    on - the trap this dodges. /click on action buttons passes the 12.x
--    ScriptedInput guard (only aura buttons forbid it).
--  * QUEUED NEXT-ATTACK ABILITY (optional, off by default): one more line on
--    the same macro, "/cast [harm,nodead] !<Ability>", so a picked button also
--    arms a next-weapon-attack ability (Raptor Strike, Heroic Strike, Maul,
--    Cleave). It rides Arc's own hardware click, so it works in combat.
--      - The "!" is NOT optional. Casting a next-melee ability that is already
--        queued CANCELS the queue, so a plain /cast would toggle it off on the
--        next press and button spam would flip it on and off. "!" forces it on.
--        /cast is SecureCmdOptionParse -> C_Spell.DoesSpellExist ->
--        CastSpellByName (SlashCommands.lua); the "!" is stripped C-side by the
--        SpellIdentifier resolver, the same handler live retail runs.
--      - The line goes LAST on purpose. A next-melee ability is off the GCD and
--        can be queued DURING one, so ordering costs the intended case nothing;
--        but if a GCD ability is ever picked by mistake the button's own spell
--        has already fired and the stray /cast is simply refused by the global,
--        instead of eating it and leaving the button dead.
--      - The macro runs ONCE per press, not twice: the overlay registers both
--        AnyUp and AnyDown, but SecureActionButton_OnClick's clickAction is
--        (down and useOnKeyDown) or (not down and not useOnKeyDown), so exactly
--        one fires, and no "typerelease" attribute means the press-and-hold
--        release path resolves to a nil action type and does nothing.
--  * Mouse: the overlay sits on top of the button and takes the click (drag,
--    drop and the tooltip are forwarded). Keybinds: the button's keys (its
--    bindingAction plus any "CLICK name:LeftButton" binding) are re-pointed
--    at the overlay with override bindings.
--  * Vehicles / possess / override bars / pet battles: Blizzard reroutes the
--    ACTIONBUTTON keys to the vehicle bar in Lua, and an override would bypass
--    that. So the overrides live on a secure STATE DRIVER handler that drops
--    them under [overridebar][vehicleui][possessbar][petbattle] and restores
--    them afterwards - in combat too (restricted SetBindingClick/ClearBindings;
--    the same conditionals Bartender4 drives on this engine).
--  * Anything that edits secure frames or bindings runs OUT of combat; a
--    request made in combat is queued for PLAYER_REGEN_ENABLED.

-- NAMESPACE ISOLATION - see the note at the top of AW_Swing.lua. Every `NS.x`
-- in this engine is really `shared.Pet.x`, so it cannot collide with the swing
-- engine's identically-named hooks.
local ADDON, AW = ...
local NS = AW.Pet

local PET_ICON = "Interface\\Icons\\Ability_GhoulFrenzy"   -- Blizzard's pet Attack art
NS.PET_ICON = PET_ICON

-- Blizzard's action bars in Edit Mode order. Button globals are
-- "<prefix><1..12>" (Blizzard ActionBar.lua: actionBarName.."Button"..i).
local BARS = {
    { prefix = "ActionButton",              label = "Action Bar 1" },
    { prefix = "MultiBarBottomLeftButton",  label = "Action Bar 2" },
    { prefix = "MultiBarBottomRightButton", label = "Action Bar 3" },
    { prefix = "MultiBarRightButton",       label = "Action Bar 4" },
    { prefix = "MultiBarLeftButton",        label = "Action Bar 5" },
    { prefix = "MultiBar5Button",           label = "Action Bar 6" },
    { prefix = "MultiBar6Button",           label = "Action Bar 7" },
    { prefix = "MultiBar7Button",           label = "Action Bar 8" },
}
NS.BARS = BARS

local DRIVER = "[overridebar][vehicleui][possessbar][petbattle] off; on"
-- queue defaults OFF and queueSpell starts unset: with either one missing the
-- /cast line is never emitted and the macro is byte-identical to the original.
local DEFAULTS = { enabled = true, mouse = true, marker = true, queue = false }

local DB
local overlays = {}        -- [buttonName] = secure overlay
local pending = false      -- a secure update was requested during combat
local driverPending = false
local inApply = false      -- re-entrancy guard: binding edits echo UPDATE_BINDINGS
local bindCheckQueued = false
local lastApply = 0
local lastN = 0

-- ── read-only helpers (display) ─────────────────────────────────────────────

function NS.ButtonLabel(name)
    for _, bar in ipairs(BARS) do
        local idx = name:match("^" .. bar.prefix .. "(%d+)$")
        if idx then return ("%s, button %s"):format(bar.label, idx) end
    end
    return name
end

-- what a button holds right now: texture, display name (plain reads only)
function NS.ActionInfo(name)
    local b = _G[name]
    local slot = b and b.action
    if not slot or not HasAction(slot) then return nil, nil end
    local tex = GetActionTexture(slot)
    local kind, id = GetActionInfo(slot)
    local text
    if kind == "spell" and id and C_Spell and C_Spell.GetSpellName then
        text = C_Spell.GetSpellName(id)
    elseif kind == "item" and id and C_Item and C_Item.GetItemNameByID then
        text = C_Item.GetItemNameByID(id)
    elseif kind == "macro" then
        text = GetActionText(slot)
    end
    return tex, text or GetActionText(slot) or "Action"
end

-- the spell a bar button would cast, as the NAME the macro line needs. Only a
-- real spell qualifies - an item or an empty slot has nothing to queue. A
-- macro slot resolves through its spell (GetActionInfo already hands back the
-- resolved spell on this engine; GetMacroSpell covers the rest).
function NS.ActionSpell(name)
    local b = _G[name]
    local slot = b and b.action
    if not slot or not HasAction(slot) then return nil end
    local kind, id = GetActionInfo(slot)
    local spellID
    if kind == "spell" then
        spellID = id
    elseif kind == "macro" and id and GetMacroSpell then
        spellID = GetMacroSpell(id)
    end
    if not spellID then return nil end
    local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if not spellName or spellName == "" then return nil end
    return spellName, GetActionTexture(slot)
end

-- art for the chosen ability, for the panel row (nil while nothing is chosen)
function NS.QueueIcon()
    local spell = DB and DB.queueSpell
    if not spell then return nil end
    return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spell) or nil
end

-- ── action identity ─────────────────────────────────────────────────────────
-- Picks follow the ABILITY, not the slot: drag Mongoose Bite to another button
-- and the job moves with it, and a second copy of it on another bar does the
-- job too. Spells key by NAME so ranks of the same spell stay one ability.

local function ActionKeyFor(name)
    local b = _G[name]
    local slot = b and b.action
    if not slot or not HasAction(slot) then return nil end
    local kind, id = GetActionInfo(slot)
    if kind == "macro" then
        local text = GetActionText(slot)
        if text and text ~= "" then return "macro:" .. text, text end
        return nil
    elseif kind == "item" and id then
        local text = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
        return "item:" .. id, text or ("Item " .. id)
    elseif kind == "spell" and id then
        local text = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
        if text and text ~= "" then return "spell:" .. text, text end
    end
    return nil
end
NS.ActionKeyFor = ActionKeyFor

-- buttonName -> action key, rebuilt at the top of every pass that reads it so
-- MacroFor, ApplyOverlay and the key collector can never disagree mid-apply
local keyMap = {}
local function RebuildKeyMap()
    wipe(keyMap)
    for _, bar in ipairs(BARS) do
        for i = 1, 12 do
            local name = bar.prefix .. i
            keyMap[name] = (ActionKeyFor(name))
        end
    end
end
NS.RebuildKeyMap = RebuildKeyMap

-- ── secure overlays ─────────────────────────────────────────────────────────

-- picks and queuePicks are INDEPENDENT lists: a button may send the pet, queue
-- the ability, or both. Keeping them apart is the point - a trap wants to queue
-- Raptor Strike WITHOUT sending the pet in to break the trap.
local function PetOn(name)
    local k = keyMap[name]
    return (k and DB and DB.enabled and DB.picks[k]) and true or false
end

local function QueueOn(name)
    local k = keyMap[name]
    return (k and DB and DB.queue and DB.queueSpell and DB.queuePicks[k]) and true or false
end

-- a button needs an overlay if EITHER job is live on it
local function ActiveOn(name) return PetOn(name) or QueueOn(name) end

local function MacroFor(name, mouse)
    local macro = PetOn(name) and "/petattack [pet,@target,harm,nodead]\n" or ""
    macro = macro .. ("/click %s %s 1\n/click %s %s 0"):format(name, mouse, name, mouse)
    -- the queued next-attack ability, LAST and with the mandatory "!" (see the
    -- header). [harm,nodead] mirrors the petattack line so a press with nothing
    -- hostile targeted does not throw a red error.
    if QueueOn(name) then
        macro = macro .. ("\n/cast [harm,nodead] !%s"):format(DB.queueSpell)
    end
    return macro
end

local function BarsLocked()
    return LOCK_ACTIONBAR == "1" or (GetCVarBool and GetCVarBool("lockActionBars"))
end

-- created lazily, OUT OF COMBAT only (callers guarantee it)
local function EnsureOverlay(name)
    local ov = overlays[name]
    if ov then return ov end
    local b = _G[name]
    if not b then return nil end
    ov = CreateFrame("Button", "ArcPetAttack_" .. name, b, "SecureActionButtonTemplate")
    ov:SetAllPoints(b)
    ov:SetFrameLevel(b:GetFrameLevel() + 12)
    ov:RegisterForClicks("AnyUp", "AnyDown")
    ov:RegisterForDrag("LeftButton", "RightButton")
    ov:SetAttribute("type", "macro")
    -- macrotext is NOT written here: the queued ability can change after the
    -- overlay exists, so ApplyOverlay re-states it on every apply instead.

    -- corner marker: Blizzard's pet Attack icon
    ov.markerEdge = ov:CreateTexture(nil, "OVERLAY", nil, 5)
    ov.markerEdge:SetColorTexture(0, 0, 0, 0.9)
    ov.marker = ov:CreateTexture(nil, "OVERLAY", nil, 6)
    ov.marker:SetTexture(PET_ICON)
    ov.marker:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ov.marker:SetSize(13, 13)
    ov.marker:SetPoint("BOTTOMLEFT", 2, 2)
    ov.markerEdge:SetPoint("TOPLEFT", ov.marker, "TOPLEFT", -1, 1)
    ov.markerEdge:SetPoint("BOTTOMRIGHT", ov.marker, "BOTTOMRIGHT", 1, -1)

    -- queue marker, opposite corner so the two jobs never overlap: the queued
    -- ability's own art, so the button says WHAT it arms. Texture is set in
    -- ApplyOverlay because the chosen ability can change.
    ov.qmarkerEdge = ov:CreateTexture(nil, "OVERLAY", nil, 5)
    ov.qmarkerEdge:SetColorTexture(0, 0, 0, 0.9)
    ov.qmarker = ov:CreateTexture(nil, "OVERLAY", nil, 6)
    ov.qmarker:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ov.qmarker:SetSize(13, 13)
    ov.qmarker:SetPoint("BOTTOMRIGHT", -2, 2)
    ov.qmarkerEdge:SetPoint("TOPLEFT", ov.qmarker, "TOPLEFT", -1, 1)
    ov.qmarkerEdge:SetPoint("BOTTOMRIGHT", ov.qmarker, "BOTTOMRIGHT", 1, -1)

    -- no press flash on purpose (Arc: the blue overlay on click is unwanted)

    -- tooltip + highlight, read-only forwarding. Blizzard's own OnEnter is
    -- never run from addon code (it writes fields on the button - taint).
    ov:SetScript("OnEnter", function(self)
        local bb = _G[name]
        if bb and bb.LockHighlight then bb:LockHighlight() end
        local slot = bb and bb.action
        if slot and HasAction(slot) then
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            GameTooltip:SetAction(slot)
            GameTooltip:AddLine("|cff3fc9f2Arc Pet Attack|r - also sends your pet", 0.85, 0.89, 0.92)
            GameTooltip:Show()
        end
    end)
    ov:SetScript("OnLeave", function()
        local bb = _G[name]
        if bb and bb.UnlockHighlight then bb:UnlockHighlight() end
        GameTooltip:Hide()
    end)
    -- drag and drop keep editing the bar underneath (out of combat)
    ov:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        local bb = _G[name]
        local slot = bb and bb.action
        if not slot then return end
        if BarsLocked() and not IsModifiedClick("PICKUPACTION") then return end
        PickupAction(slot)
    end)
    ov:SetScript("OnReceiveDrag", function()
        if InCombatLockdown() then return end
        local bb = _G[name]
        local slot = bb and bb.action
        if slot then PlaceAction(slot) end
    end)
    overlays[name] = ov
    return ov
end

local function ApplyOverlay(name)
    local ov = EnsureOverlay(name)
    if not ov then return end
    local on = ActiveOn(name)
    -- rewritten every time (callers guarantee out of combat): this is the one
    -- place a changed queued ability reaches a button that is already picked
    ov:SetAttribute("macrotext", MacroFor(name, "LeftButton"))
    ov:SetAttribute("macrotext2", MacroFor(name, "RightButton"))
    ov:SetShown(on)
    ov:EnableMouse(on and DB.mouse and true or false)
    -- each marker tracks its OWN job, so a queue-only button never wears the
    -- pet icon and a pet-only button never wears the ability icon
    local pet = DB.marker and PetOn(name)
    ov.marker:SetShown(pet and true or false)
    ov.markerEdge:SetShown(pet and true or false)
    local q = DB.marker and QueueOn(name)
    if q then ov.qmarker:SetTexture(NS.QueueIcon() or PET_ICON) end
    ov.qmarker:SetShown(q and true or false)
    ov.qmarkerEdge:SetShown(q and true or false)
end

-- ── keybinds: a secure state-driver handler owns every override ─────────────

local binder = CreateFrame("Frame", "ArcPetAttackBinder", UIParent, "SecureHandlerStateTemplate")
-- only an explicit "off" (a vehicle-type bar is up) holds the keys back: an
-- unset state never silently disables every redirect. PRIORITY overrides so
-- no other override layer on the client can outrank a picked key.
binder:SetAttribute("apa-apply", [[
    local state = ...
    self:ClearBindings()
    if state == "off" or not self:GetAttribute("apa-enabled") then return end
    local n = self:GetAttribute("apa-n") or 0
    for i = 1, n do
        local key = self:GetAttribute("apa-key" .. i)
        local btn = self:GetAttribute("apa-btn" .. i)
        if key and btn then self:SetBindingClick(true, key, btn, "LeftButton") end
    end
]])
binder:SetAttribute("_onstate-apa", [[ self:RunAttribute("apa-apply", newstate) ]])

-- the binding command a Blizzard action button answers to (its own field,
-- set by Blizzard's UpdateHotkeys; the derivation mirrors that code)
local function CommandFor(b)
    return b.bindingAction or ((b.buttonType or "ACTIONBUTTON") .. b:GetID())
end

-- every { key, overlayName } the picks need. GetBindingKey reads the BASE
-- binding set (overrides are separate - GetBindingAction needs checkOverride
-- to see them), so this is stable whether or not our redirects are active.
local function CollectKeys()
    local list = {}
    -- NOT gated on DB.enabled any more: the pet toggle must not strand a
    -- queue-only button. Per-button liveness is the ov:IsShown() test below,
    -- which ApplyOverlay drives from ActiveOn.
    if not DB then return list end
    -- the UNION: a queue-only button needs its keybind redirected too
    for _, name in ipairs(NS.ActiveList()) do
        local b, ov = _G[name], overlays[name]
        if b and ov and ov:IsShown() then
            for _, command in ipairs({ CommandFor(b), "CLICK " .. name .. ":LeftButton" }) do
                for k = 1, select("#", GetBindingKey(command)) do
                    local key = select(k, GetBindingKey(command))
                    if key and key ~= "" then
                        list[#list + 1] = { key = key, btn = ov:GetName(), from = name }
                    end
                end
            end
        end
    end
    return list
end

local function Signature(list)
    local parts = {}
    for i, e in ipairs(list) do parts[i] = e.key .. ">" .. e.btn end
    return table.concat(parts, ";") .. "|" .. tostring(DB and DB.enabled)
        .. "|" .. tostring(DB and DB.queue) .. "|" .. tostring(DB and DB.queueSpell)
end

local function Expected(e) return "CLICK " .. e.btn .. ":LeftButton" end

-- OUT OF COMBAT only. Clear first, then install DIRECTLY with
-- SetOverrideBindingClick (the plain path Bartender4 proves on this engine);
-- the secure snippet only re-does this for vehicle changes DURING combat,
-- from the same key list stored as attributes. Then VERIFY each key with the
-- game's own override lookup: the panel's status reports the truth.
local function ApplyBindings()
    ClearOverrideBindings(binder)
    local list = CollectKeys()
    for i, e in ipairs(list) do
        binder:SetAttribute("apa-key" .. i, e.key)
        binder:SetAttribute("apa-btn" .. i, e.btn)
    end
    for i = #list + 1, lastN do
        binder:SetAttribute("apa-key" .. i, nil)
        binder:SetAttribute("apa-btn" .. i, nil)
    end
    lastN = #list
    binder:SetAttribute("apa-n", #list)
    -- "live" is now simply "any button still wants a key", since an empty list
    -- is what a fully-off addon produces
    local live = (#list > 0)
    binder:SetAttribute("apa-enabled", live)
    if live and binder:GetAttribute("state-apa") ~= "off" then
        for _, e in ipairs(list) do
            SetOverrideBindingClick(binder, true, e.key, e.btn, "LeftButton")
        end
    end

    local verified = 0
    for _, e in ipairs(list) do
        e.now = GetBindingAction(e.key, true)
        e.ok = (e.now == Expected(e))
        if e.ok then verified = verified + 1 end
    end
    NS.bindReport = { list = list, verified = verified, state = binder:GetAttribute("state-apa"),
        at = GetTime() }
    NS.appliedSig = Signature(list)
    NS.boundKeys = verified
    NS.applyCount = (NS.applyCount or 0) + 1
end

-- are the redirects that SHOULD be active actually active right now?
-- (held back on purpose while a vehicle-type bar is up, or when turned off)
local function Healthy(list)
    if not DB or binder:GetAttribute("state-apa") == "off" then return true end
    for _, e in ipairs(list) do
        if GetBindingAction(e.key, true) ~= Expected(e) then return false end
    end
    return true
end

-- ── migration: slot-keyed picks (<= 0.1.0) become ability-keyed ────────────
-- NON-DESTRUCTIVE BY DESIGN. A legacy entry is only converted once its button
-- actually exists, because at login the bars may not be populated yet and
-- converting too early would read an empty slot and silently drop the pick.
-- Anything unresolved is simply left for the next pass.
local function IsLegacyKey(k)
    for _, bar in ipairs(BARS) do
        if k:match("^" .. bar.prefix .. "%d+$") then return true end
    end
    return false
end

local function MigrateStore(store)
    if not store then return end
    local legacy = {}
    for k in pairs(store) do
        if IsLegacyKey(k) then legacy[#legacy + 1] = k end
    end
    for _, name in ipairs(legacy) do
        if _G[name] then                      -- the bar is up: decide now
            local key, label = ActionKeyFor(name)
            store[name] = nil
            if key then store[key] = label or key end
        end
    end
end

local function MigratePicks()
    if not DB then return end
    MigrateStore(DB.picks)
    MigrateStore(DB.queuePicks)
end

-- the ONE apply: overlays + bindings, queued when combat forbids it
local function ApplyAll()
    if not DB or inApply then return end
    if InCombatLockdown() then pending = true return end
    inApply = true
    pending = false
    RebuildKeyMap()
    MigratePicks()
    for _, bar in ipairs(BARS) do
        for i = 1, 12 do
            local name = bar.prefix .. i
            local key = keyMap[name]
            -- raw membership in EITHER list: ApplyOverlay does the toggle
            -- gating itself, so a picked-but-disabled button just hides
            if key and (DB.picks[key] or DB.queuePicks[key]) then
                ApplyOverlay(name)
            elseif overlays[name] then
                overlays[name]:EnableMouse(false)
                overlays[name]:Hide()
            end
        end
    end
    ApplyBindings()
    lastApply = GetTime()
    inApply = false
    if NS.OnApplied then NS.OnApplied() end
end
NS.ApplyAll = ApplyAll

-- SELF-HEAL. In-game proof (Forever 69913): redirects installed
-- at PLAYER_ENTERING_WORLD were gone moments later with the base keys
-- unchanged - the client's own binding load clears override bindings. So
-- whenever it could have happened, ask the game what each key does and
-- reinstall if needed. Capped: three failed heals in a row stop the attempts
-- so a refusing client can never loop us.
local healFails = 0
local function CheckAndHeal(reason)
    if not DB or InCombatLockdown() or inApply then return end
    RebuildKeyMap()
    local list = CollectKeys()
    if Signature(list) ~= NS.appliedSig then
        healFails = 0
        ApplyAll()
        return
    end
    if Healthy(list) then
        healFails = 0
        return
    end
    if healFails >= 3 then
        NS.healStuck = true
        return
    end
    healFails = healFails + 1
    NS.heals = (NS.heals or 0) + 1
    ApplyAll()
    if Healthy(CollectKeys()) then
        healFails = 0
        NS.healStuck = nil
    end
end
NS.CheckAndHeal = CheckAndHeal

-- ── mutators (the panel, picker and slash commands all come through here) ──

function NS.GetDB() return DB end
function NS.IsPending() return pending end
-- The pickers still speak BUTTON names (you click a button on your bars); the
-- store speaks ability keys. These resolve one to the other. The stored value
-- is the ability's display name, so a list row still reads correctly while the
-- ability is off your bars entirely.
local function SetKeyed(store, name, on)
    if not DB then return end
    local key, label = ActionKeyFor(name)
    if not key then return end
    store[key] = on and (label or key) or nil
    ApplyAll()
end

function NS.IsPicked(name)
    if not DB then return false end
    local key = ActionKeyFor(name)
    return (key ~= nil and DB.picks[key] ~= nil)
end

function NS.SetPicked(name, on) SetKeyed(DB and DB.picks, name, on) end
function NS.TogglePick(name) NS.SetPicked(name, not NS.IsPicked(name)) end

function NS.ClearPicks()
    if not DB then return end
    wipe(DB.picks)
    ApplyAll()
end

-- the parallel list: which abilities queue the chosen ability
function NS.IsQueuePicked(name)
    if not DB then return false end
    local key = ActionKeyFor(name)
    return (key ~= nil and DB.queuePicks[key] ~= nil)
end

function NS.SetQueuePicked(name, on) SetKeyed(DB and DB.queuePicks, name, on) end
function NS.ToggleQueuePick(name) NS.SetQueuePicked(name, not NS.IsQueuePicked(name)) end

function NS.ClearQueuePicks()
    if not DB then return end
    wipe(DB.queuePicks)
    ApplyAll()
end

-- Remove buttons in the panel act on the stored ability directly
function NS.RemoveKey(which, key)
    if not DB or not key then return end
    local store = (which == "queue") and DB.queuePicks or DB.picks
    store[key] = nil
    ApplyAll()
end

-- where an ability currently sits, for the panel row ("" when it is nowhere)
function NS.WhereIs(key)
    local out = {}
    if not key then return out end
    for _, bar in ipairs(BARS) do
        for i = 1, 12 do
            local name = bar.prefix .. i
            if ActionKeyFor(name) == key then out[#out + 1] = name end
        end
    end
    return out
end

-- art for a stored ability, live from whatever holds it, else from the key.
-- `where` may be passed in by a caller that already scanned, so a panel row
-- costs ONE bar sweep instead of two.
function NS.KeyIcon(key, where)
    if not key then return nil end
    where = where or NS.WhereIs(key)
    if where[1] then
        local b = _G[where[1]]
        local slot = b and b.action
        if slot then return GetActionTexture(slot) end
    end
    local spell = key:match("^spell:(.+)$")
    if spell and C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spell)
    end
    local itemID = tonumber(key:match("^item:(%d+)$") or "")
    if itemID and C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
    return nil
end

function NS.GetQueueSpell() return DB and DB.queueSpell or nil end

-- COMBAT-FIRST: ApplyAll rewrites the secure macros, so a change made in
-- combat queues itself to PLAYER_REGEN_ENABLED exactly like a pick does.
function NS.SetQueueSpell(spell)
    if not DB then return end
    DB.queueSpell = (spell ~= "" and spell) or nil
    ApplyAll()
end

function NS.SetOption(key, v)
    if not DB then return end
    DB[key] = v and true or false
    ApplyAll()
    if NS.PaintMinimap then NS.PaintMinimap() end
end

-- picked ABILITIES, alphabetical (slots no longer give them an order)
local function EntriesOf(store)
    local out = {}
    if not store then return out end
    for key, label in pairs(store) do
        out[#out + 1] = { key = key, label = (type(label) == "string" and label) or key }
    end
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower() end)
    return out
end

function NS.PickEntries() return EntriesOf(DB and DB.picks) end
function NS.QueueEntries() return EntriesOf(DB and DB.queuePicks) end

-- every BUTTON carrying either job right now, in bar order and never
-- duplicated. Resolved live, so it follows the abilities around the bars.
function NS.ActiveList()
    local out = {}
    if not DB then return out end
    for _, bar in ipairs(BARS) do
        for i = 1, 12 do
            local name = bar.prefix .. i
            local key = ActionKeyFor(name)
            if key and (DB.picks[key] or DB.queuePicks[key]) then out[#out + 1] = name end
        end
    end
    return out
end

-- ── events ──────────────────────────────────────────────────────────────────

-- the bars changed under us: abilities may have moved, so the overlays have to
-- move with them. Debounced because a single drag fires several of these.
local applyQueued = false
local function QueueApply()
    if applyQueued then return end
    applyQueued = true
    C_Timer.After(0.2, function()
        applyQueued = false
        if InCombatLockdown() then pending = true return end
        ApplyAll()
    end)
end

local refreshQueued = false
local function QueuePanelRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.1, function()
        refreshQueued = false
        if NS.RefreshPanel then NS.RefreshPanel() end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- MIGRATION from Arc Pet Attack, same rule as the swing side: only
        -- ever into a FRESH table, so a real ArcWeave profile is never
        -- overwritten. Picks arrive in whatever key form they were saved in;
        -- MigratePicks converts any legacy slot keys on the first apply.
        ArcWeaveCharDB = ArcWeaveCharDB or {}
        if next(ArcWeaveCharDB) == nil and type(ArcPetAttackDB) == "table"
            and next(ArcPetAttackDB) ~= nil then
            for k, v in pairs(ArcPetAttackDB) do ArcWeaveCharDB[k] = v end
            ArcWeaveCharDB.loads = nil
        end
        DB = ArcWeaveCharDB
        for k, v in pairs(DEFAULTS) do
            if DB[k] == nil then DB[k] = v end
        end
        DB.picks = DB.picks or {}
        DB.queuePicks = DB.queuePicks or {}
        -- SV-read health counter (Forever incident, 2026-09-18): bumps once
        -- per login/reload; stuck at 1 in the WTF file across reloads = the
        -- client did not read this per-character file back
        DB.loads = (DB.loads or 0) + 1
        if InCombatLockdown() then
            driverPending = true
        else
            RegisterStateDriver(binder, "apa", DRIVER)
        end
        ev:RegisterEvent("PLAYER_ENTERING_WORLD")
        ev:RegisterEvent("UPDATE_BINDINGS")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")
        ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        ev:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        ev:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
        if NS.OnReady then NS.OnReady() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        ApplyAll()
        -- the client's binding load lands AFTER this event and wipes
        -- overrides: re-check once it has settled
        C_Timer.After(1.5, function() CheckAndHeal("after loading") end)
        C_Timer.After(5, function() CheckAndHeal("after loading") end)
    elseif event == "UPDATE_BINDINGS" then
        -- coalesced; CheckAndHeal re-applies when the base key list changed
        -- OR when a redirect that should be active is missing. Our own
        -- installs verify healthy, so their echo does nothing (no loop).
        if inApply or bindCheckQueued then return end
        bindCheckQueued = true
        C_Timer.After(0.3, function()
            bindCheckQueued = false
            if InCombatLockdown() then pending = true return end
            CheckAndHeal("bindings changed")
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if driverPending then
            driverPending = false
            RegisterStateDriver(binder, "apa", DRIVER)
        end
        if pending then ApplyAll() end
        CheckAndHeal("combat ended")
        QueuePanelRefresh()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- picking edits secure frames: never leave the picker open in combat
        if NS.SetSetup then NS.SetSetup(false) end
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED"
        or event == "UPDATE_BONUS_ACTIONBAR" then
        QueueApply()
        QueuePanelRefresh()
    end
end)

-- ── slash ───────────────────────────────────────────────────────────────────

SLASH_ARCWEAVEPET1 = "/apa"
SLASH_ARCWEAVEPET2 = "/arcpetattack"
SlashCmdList.ARCWEAVEPET = function(input)
    if not DB then return end
    local cmd = ((input or ""):match("^%s*(%S*)") or ""):lower()
    if cmd == "pick" then
        if NS.SetSetup then NS.SetSetup(true, "buttons") end
    elseif cmd == "ability" or cmd == "spell" then
        if NS.SetSetup then NS.SetSetup(true, "spell") end
    elseif cmd == "queue" then
        if NS.SetSetup then NS.SetSetup(true, "queue") end
    elseif cmd == "toggle" then
        NS.SetOption("enabled", not DB.enabled)
        if NS.RefreshPanel then NS.RefreshPanel() end
    elseif NS.TogglePanel then
        NS.TogglePanel()
    end
end
