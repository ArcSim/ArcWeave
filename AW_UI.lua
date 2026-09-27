-- Arc Weave - one options window over both engines.
-- Built ENTIRELY from AW_Theme.lua (a verbatim copy of ArcDisplay's AD_Theme,
-- the Arc source of truth). No hand-drawn widgets: if a control looks wrong,
-- fix the theme source, then re-copy. Every edit goes through an engine
-- mutator - this file never writes an engine's DB directly.
--
-- The two engines keep their own namespaces (see AW_Init.lua), so this file
-- defines each one's UI callbacks on ITS table: SW.OnReady and PET.OnReady are
-- different fields pointing at the same shared implementation.

local ADDON, AW = ...
local AT = AW.AT
local COL, LAY = AT.COL, AT.LAY
local SW, PET = AW.Swing, AW.Pet

local ROW_MAX = 12
-- tab names live in GROUPS, further down, next to the builders they select

local panel, banner, dbg, mmBtn
local pages = {}
local pickers = {}
-- mode: "pet" picks which abilities send the pet, "queue" picks which abilities
-- arm the queue, "spell" picks the one ability that gets queued. All three run
-- off the same click-the-bars overlays.
-- tab = the top group, sub[group] = where you were inside it
local ui = { tab = "Next Melee Weave", sub = {}, setup = false, visible = 0, mode = "pet" }

local function SDB() return SW.GetDB and SW.GetDB() or nil end
local function PDB() return PET.GetDB and PET.GetDB() or nil end
local function Spells()
    local d = SDB()
    return (d and d.spells) or {}
end

local function Version() return AW.VERSION and ("v" .. AW.VERSION) or nil end

local function ErrorMsg(text)
    if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1, 0.3, 0.3) end
end

-- the theme rule: colors come from the palette, never a hardcoded hex
local FAINT_HEX = ("%02x%02x%02x"):format(math.floor(COL.faint[1] * 255 + 0.5),
    math.floor(COL.faint[2] * 255 + 0.5), math.floor(COL.faint[3] * 255 + 0.5))

local function Icon(tex)
    return ("|T%s:16:16:0:0:64:64:5:59:5:59|t  "):format(tostring(tex or 134400))
end

-- "|Ticon|t  Name  (Action Bar 2, button 5)" for a live bar button
local function PickText(name)
    local tex, text = PET.ActionInfo(name)
    return Icon(tex) .. (text or "Empty button") .. "  |cff" .. FAINT_HEX .. "("
        .. PET.ButtonLabel(name) .. ")|r"
end

-- a picked ABILITY row: name plus where it currently sits on the bars
local function EntryText(entry)
    local where = PET.WhereIs(entry.key)
    local tail
    if #where == 0 then tail = "not on your bars"
    elseif #where == 1 then tail = PET.ButtonLabel(where[1])
    else tail = ("%d buttons"):format(#where) end
    return Icon(PET.KeyIcon(entry.key, where)) .. entry.label
        .. "  |cff" .. FAINT_HEX .. "(" .. tail .. ")|r"
end

local function QueueText()
    local spell = PET.GetQueueSpell()
    if not spell then return nil end
    return Icon(PET.QueueIcon()) .. spell
end

--[[ PICKER - click-to-pick overlays on the real bars (insecure frames) ======]]

local function PaintPicker(pk, name)
    if ui.mode == "spell" then
        -- hunting one specific ability here, so the bar art has to stay
        -- readable: no fill and no cover icon, only the edge marks it
        local spell = PET.ActionSpell(name)
        pk.icon:Hide()
        if spell ~= nil and spell == PET.GetQueueSpell() then
            pk:SetBackdropColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.25)
            pk:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        else
            pk:SetBackdropColor(0, 0, 0, 0)
            pk:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
        end
        return
    end
    pk.icon:Show()
    local on, art
    if ui.mode == "queue" then
        on, art = PET.IsQueuePicked(name), (PET.QueueIcon() or PET.PET_ICON)
    else
        on, art = PET.IsPicked(name), PET.PET_ICON
    end
    pk.icon:SetTexture(art)
    if on then
        pk:SetBackdropColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.30)
        pk:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        pk.icon:SetDesaturated(false)
        pk.icon:SetAlpha(1)
    else
        pk:SetBackdropColor(0, 0, 0, 0.45)
        pk:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
        pk.icon:SetDesaturated(true)
        pk.icon:SetAlpha(0.30)
    end
end

local function UpdateBanner()
    if not banner then return end
    local mode = ui.mode
    local spell = PET.GetQueueSpell() or "your ability"
    if mode == "spell" then
        banner.head:SetText("PICK AN ABILITY")
        banner.txt:SetText("Click the ability that should be queued for your next weapon attack, like Raptor Strike or Heroic Strike. Only buttons holding a spell can be clicked.")
    elseif mode == "queue" then
        banner.head:SetText("PICK QUEUEING ABILITIES")
        banner.txt:SetText(("Click the abilities that should also queue %s. Cyan = picked, click again to unpick. Picks follow the ability, so moving it to another button keeps it working."):format(spell))
    else
        banner.head:SetText("PICK PET ABILITIES")
        banner.txt:SetText("Click the abilities that should also send your pet. Cyan = picked, click again to unpick. Picks follow the ability, so moving it to another button keeps it working.")
    end
    if ui.visible == 0 then
        banner.count:SetText(mode == "spell"
            and "No action buttons with a spell on them are visible - show your bars in Edit Mode first."
            or "No action buttons with an ability on them are visible - show your bars in Edit Mode first.")
        banner.count:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        return
    end
    if mode == "spell" then
        banner.count:SetText(QueueText() or "No ability chosen yet")
        local c = PET.GetQueueSpell() and COL.arc or COL.dim
        banner.count:SetTextColor(c[1], c[2], c[3])
    else
        local n = (mode == "queue") and #PET.QueueEntries() or #PET.PickEntries()
        banner.count:SetText(("%d abilit%s picked"):format(n, n == 1 and "y" or "ies"))
        banner.count:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    end
end

local function EnsurePicker(name)
    local pk = pickers[name]
    if pk then return pk end
    local b = _G[name]
    if not b then return nil end
    pk = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    pk:SetFrameStrata("DIALOG")
    pk:SetAllPoints(b)
    AT.Skin(pk, { 0, 0, 0, 0.45 }, COL.line2)
    pk.icon = pk:CreateTexture(nil, "OVERLAY")
    pk.icon:SetTexture(PET.PET_ICON)
    pk.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pk.icon:SetPoint("CENTER")
    pk.icon:SetSize(18, 18)
    pk:SetScript("OnSizeChanged", function(self, w)
        if w and w > 4 then self.icon:SetSize(w * 0.55, w * 0.55) end
    end)
    pk:SetScript("OnClick", function(self)
        if ui.mode == "spell" then
            local spell = PET.ActionSpell(name)
            if not spell then return end
            PET.SetQueueSpell(spell)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON, "Master")
            GameTooltip:Hide()
            AW.SetSetup(false)   -- one ability, so picking it is the whole job
            return
        end
        if ui.mode == "queue" then
            PET.ToggleQueuePick(name)
            PlaySound(PET.IsQueuePicked(name) and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
        else
            PET.TogglePick(name)
            PlaySound(PET.IsPicked(name) and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
        end
        PaintPicker(self, name)
        UpdateBanner()
        if self:IsMouseOver() then self:GetScript("OnEnter")(self) end
    end)
    pk:SetScript("OnEnter", function(self)
        local picked
        if ui.mode == "spell" then picked = (PET.ActionSpell(name) == PET.GetQueueSpell())
        elseif ui.mode == "queue" then picked = PET.IsQueuePicked(name)
        else picked = PET.IsPicked(name) end
        if not picked then
            self:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(PickText(name))
        local line
        if ui.mode == "spell" then
            line = picked and "Queued now - click to choose it again"
                or "Click to queue this for your next weapon attack"
        elseif ui.mode == "queue" then
            local s = PET.GetQueueSpell() or "your ability"
            line = picked and ("Queues %s - click to unpick"):format(s)
                or ("Click to also queue %s"):format(s)
        else
            line = picked and "Sends your pet - click to unpick"
                or "Click to also send your pet"
        end
        GameTooltip:AddLine(line, COL.dim[1], COL.dim[2], COL.dim[3])
        GameTooltip:Show()
    end)
    pk:SetScript("OnLeave", function(self)
        PaintPicker(self, name)
        GameTooltip:Hide()
    end)
    pk:Hide()
    pickers[name] = pk
    return pk
end

local function EnsureBanner()
    if banner then return banner end
    banner = AT.CreateWindow("ArcWeavePicker", {
        title = "|cff3fc9f2Arc|r|cffd5e2f2 Weave|r",
        w = 380, h = 150, minW = 340, minH = 140, resizable = false,
    })
    banner:ClearAllPoints()
    banner:SetPoint("TOP", UIParent, "TOP", 0, -110)
    -- head and body are re-texted per mode by UpdateBanner
    local head = banner:CreateFontString(nil, "OVERLAY")
    head:SetFont(STANDARD_TEXT_FONT, 10, "")
    head:SetPoint("TOPLEFT", 14, -42)
    head:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    banner.head = head
    local txt = banner:CreateFontString(nil, "OVERLAY")
    txt:SetFont(STANDARD_TEXT_FONT, 11, "")
    txt:SetPoint("TOPLEFT", 14, -58)
    txt:SetPoint("TOPRIGHT", -14, -58)
    txt:SetJustifyH("LEFT")
    txt:SetWordWrap(true)
    txt:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    banner.txt = txt
    banner.count = banner:CreateFontString(nil, "OVERLAY")
    banner.count:SetFont(STANDARD_TEXT_FONT, 12, "")
    banner.count:SetPoint("BOTTOMLEFT", 14, 18)
    banner.count:SetPoint("BOTTOMRIGHT", -110, 18)
    banner.count:SetJustifyH("LEFT")
    banner.count:SetWordWrap(true)
    local done = AT.MakeSmallButton(banner, "Done", 84)
    done:SetPoint("BOTTOMRIGHT", -12, 12)
    done:SetScript("OnClick", function() AW.SetSetup(false) end)
    banner:HookScript("OnHide", function() if ui.setup then AW.SetSetup(false) end end)
    return banner
end

function AW.InSetup() return ui.setup end

function AW.SetSetup(on, mode)
    on = on and true or false
    mode = (on and mode) or "pet"
    if on and InCombatLockdown() then
        ErrorMsg(mode == "spell"
            and "Arc Weave: you can't pick an ability during combat."
            or "Arc Weave: you can't pick abilities during combat.")
        return
    end
    ui.setup = on
    ui.mode = mode
    local visible = 0
    for _, bar in ipairs(PET.BARS) do
        for i = 1, 12 do
            local name = bar.prefix .. i
            local b = _G[name]
            -- spell mode needs a castable SPELL (that is what /cast takes);
            -- the pick modes need any action at all, since picks are stored by
            -- ability and an empty slot has no ability to store
            local eligible
            if mode == "spell" then eligible = (PET.ActionSpell(name) ~= nil)
            else eligible = (PET.ActionKeyFor(name) ~= nil) end
            if on and b and b:IsVisible() and eligible then
                local pk = EnsurePicker(name)
                if pk then
                    PaintPicker(pk, name)
                    pk:Show()
                    visible = visible + 1
                end
            elseif pickers[name] then
                pickers[name]:Hide()
            end
        end
    end
    ui.visible = visible
    if on then
        EnsureBanner()
        UpdateBanner()
        banner:Show()
    elseif banner and banner:IsShown() then
        banner:Hide()
    end
    AW.RefreshPanel()
end
-- the pet engine closes the picker itself when combat starts
PET.SetSetup = AW.SetSetup

--[[ SHARED ROWS ============================================================]]

-- legend line: the marker's real tick color as a slim bar + dim description
local function LegendRow(pg, color, text)
    local row = AT.AddRow(pg, LAY.descH)
    local bar = row:CreateTexture(nil, "ARTWORK")
    bar:SetTexture(AT.WHITE)
    bar:SetSize(3, 12)
    bar:SetPoint("LEFT", 12, 0)
    local c = color or COL.faint
    bar:SetVertexColor(c[1], c[2], c[3], 1)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    fs:SetPoint("LEFT", 24, 0)
    fs:SetPoint("RIGHT", -10, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    fs:SetText(text)
    return row
end

-- one tracked spell: icon + name as the row label, Remove on the shared column
local function SpellRow(pg, i)
    local row = AT.AddRow(pg, LAY.rowH, function() return Spells()[i] ~= nil end)
    local lbl = AT.RowLabel(row, "")
    local rm = AT.MakeSmallButton(row, "Remove", 70)
    rm:SetPoint("LEFT", lbl, "RIGHT", 14, 0)
    rm:SetScript("OnClick", function()
        AT.CloseDropdown()
        if Spells()[i] then SW.RemoveAt(i) end
        AT.LayoutPage(pg)
    end)
    -- this ability's queued bar colour, only while that option is on
    local sw = AT.MakeSwatch(row)
    sw:SetPoint("LEFT", rm, "RIGHT", 10, 0)
    AT.Tooltip(sw, "Queued bar color",
        "The main-hand swing bar fills in this color while this ability is queued.")
    sw:SetScript("OnClick", function()
        AT.CloseDropdown()
        local entry = Spells()[i]
        if not entry or not ColorPickerFrame.SetupColorPickerAndShow then return end
        local c = SW.GetAbilityQueueColor(entry)
        ColorPickerFrame:SetupColorPickerAndShow({
            r = c[1], g = c[2], b = c[3], hasOpacity = false,
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                SW.SetAbilityQueueColor(entry, { r, g, b })
                sw:SetColor({ r, g, b })
            end,
            cancelFunc = function()
                SW.SetAbilityQueueColor(entry, c)
                sw:SetColor(c)
            end,
        })
    end)
    row._colLabel, row._colCtrl = lbl, rm
    row._sync = function()
        local entry = Spells()[i]
        if not entry then return end
        sw:SetShown(SW.GetQueueBarTint())
        sw:SetColor(SW.GetAbilityQueueColor(entry))
        local sid = SW.Resolve(entry)
        local tex = sid and C_Spell and C_Spell.GetSpellTexture
            and C_Spell.GetSpellTexture(sid) or nil
        local name = sid and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
        lbl:SetText(Icon(tex) .. (name or tostring(entry))
            .. (sid and "" or ("  |cff" .. FAINT_HEX .. "(not known yet)|r")))
    end
    return row
end

-- one picked ability: icon + name + where it sits, Remove on the shared column
local function PickRow(pg, i, listFn, which)
    local row = AT.AddRow(pg, LAY.rowH, function() return listFn()[i] ~= nil end)
    local lbl = AT.RowLabel(row, "")
    local rm = AT.MakeSmallButton(row, "Remove", 70)
    rm:SetPoint("LEFT", lbl, "RIGHT", 14, 0)
    rm:SetScript("OnClick", function()
        AT.CloseDropdown()
        local entry = listFn()[i]
        if entry then PET.RemoveKey(which, entry.key) end
        AT.LayoutPage(pg)
    end)
    row._colLabel, row._colCtrl = lbl, rm
    row._sync = function()
        local entry = listFn()[i]
        if entry then lbl:SetText(EntryText(entry)) end
    end
    return row
end

local function PickListBlock(pg, listFn, which, clearAll, clearLabel)
    for i = 1, ROW_MAX do PickRow(pg, i, listFn, which) end
    local more = AT.AddRow(pg, LAY.descH, function() return #listFn() > ROW_MAX end)
    local mfs = more:CreateFontString(nil, "OVERLAY")
    mfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    mfs:SetPoint("LEFT", 10, 0)
    mfs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    more._sync = function()
        mfs:SetText(("+%d more picked"):format(math.max(0, #listFn() - ROW_MAX)))
    end
    -- quiet weight, and on the control column like every other action, so it
    -- sits visibly inside this section instead of floating between two
    AT.RowButton(pg, clearLabel, function()
        clearAll()
        AT.LayoutPage(pg)
    end, function() return #listFn() > 0 end, 190, nil, true)
end

--[[ TABS ===================================================================]]

local function BuildSwing(pg)
    AT.Section(pg, "Swing timer")
    AT.RowToggle(pg, "Show ticks on the swing timer",
        function() local d = SDB() return d ~= nil and d.enabled == true end,
        function(v) SW.SetEnabled(v) end, nil,
        "Draw the cooldown ticks for your tracked abilities on Blizzard's mainhand swing bar.")
    -- the same three choices, in the same words, as Arc Auras' swing bars
    local place = AT.RowDropdown(pg, panel, "Ready or queued marker",
        function() return SW.GetTickPlace() end,
        function(v) SW.SetTickPlace(v) end,
        function()
            return {
                { text = "Stays where it came back", value = "stay" },
                { text = "Jumps to where the swing lands", value = "jump" },
                { text = "Queued rides the swing", value = "follow" },
            }
        end)
    place:EnableMouse(true)
    AT.Tooltip(place, "Ready or queued marker",
        "Stays: the tick stays where the ability came back and only changes color. Jumps: it moves to the end of the bar, where the attack lands. Queued rides: once you queue it, the tick and icon ride the swing bar's moving fill to where the attack lands; a ready one stays where it came back.")
    local function offHandOn() local d = SDB() return d ~= nil and d.offHand == true end
    AT.RowToggle(pg, "Show ticks on the off-hand swing timer", offHandOn,
        function(v) SW.SetOffHand(v) end, nil,
        "Draw the same ticks and icons on Blizzard's off-hand swing bar when you dual-wield. Sizes come from the Markers tab.")
    AT.RowToggle(pg, "Off-hand icons above the bar",
        function() local d = SDB() return d ~= nil and d.ohIconsAbove == true end,
        function(v) SW.SetOffHandIconsAbove(v) end,
        function() return offHandOn() and SW.GetShowIcon() end,
        "Off: the off-hand icons hang below that bar, because Blizzard stacks it right under the main-hand bar and icons above it would cover that bar. On: they sit above it, for when you have moved the bars apart in Edit Mode.")
    AT.RowToggle(pg, "Color the swing bar while an ability is queued",
        function() return SW.GetQueueBarTint() end,
        function(v) SW.SetQueueBarTint(v) end, nil,
        "While a next-melee ability such as Raptor Strike is queued, the main-hand swing bar fills in that ability's color. Set a color per ability on the Tracked tab; the default below covers the rest. It goes back to normal as soon as the queued attack lands or you cancel it.")
    AT.RowColor(pg, "Default queued color",
        function() return SW.GetQueueBarColor() end,
        function(c) SW.SetQueueBarColor(c) end,
        function() return SW.GetQueueBarTint() end)
    AT.RowDesc(pg, "Needs Blizzard's swing timer turned on. Everything here is drawn on that bar.")
end

-- one sizing slider. Range and step come from the engine's SIZE table, so the
-- panel can never drift from what the engine will accept.
local function SizeRow(pg, label, key, isPct, visibleFn)
    local r = SW.SizeRange[key]
    return AT.RowSlider(pg, label,
        function() return SW.GetMarkerSize(key) end,
        function(v) SW.SetMarkerSize(key, v) end,
        r.min, r.max, r.step, isPct, visibleFn)
end

local function BuildMarkers(pg)
    local function iconOn() return SW.GetShowIcon() end

    AT.Section(pg, "Size")
    SizeRow(pg, "Tick width", "tickWidth")
    SizeRow(pg, "Tick height", "tickHeight", true)
    AT.RowToggle(pg, "Show the spell icon",
        function() return SW.GetShowIcon() end,
        function(v) SW.SetShowIcon(v) end, nil,
        "Draw each tracked ability's icon above its tick. Off leaves a bare tick on the bar.")
    SizeRow(pg, "Icon size", "iconSize", false, iconOn)
    SizeRow(pg, "Gap above the tick", "iconGap", false, iconOn)
    SizeRow(pg, "Gap between icons", "iconStack", false, iconOn)
    SizeRow(pg, "Swings-ahead text", "badgeSize", false, iconOn)
    AT.RowDesc(pg, "Tick height is a percentage of the swing bar: over 100% overhangs it.")
    AT.RowDesc(pg, "Sample ticks appear on your swing bar while this tab is open, wearing your own icons. A real swing takes over as soon as you attack.")

    AT.Section(pg, "What the markers mean")
    local M = SW.MarkerColors or {}
    LegendRow(pg, M.gold,  "Gold - comes off cooldown at that point of this swing")
    LegendRow(pg, M.amber, "Amber +N - comes off cooldown there, N swings ahead")
    LegendRow(pg, M.green, "Green - ready, it lands on this swing")
    LegendRow(pg, M.arc,   "Blue - queued, this swing IS this attack")
    LegendRow(pg, M.red,   "Red - further out than a few swings")
end

local function BuildAbilities(pg)
    AT.Section(pg, "Tracked abilities")
    AT.RowDesc(pg, "Nothing tracked yet - add an ability below.", nil,
        function() return #Spells() == 0 end)
    for i = 1, ROW_MAX do SpellRow(pg, i) end
    local more = AT.AddRow(pg, LAY.descH, function() return #Spells() > ROW_MAX end)
    local mfs = more:CreateFontString(nil, "OVERLAY")
    mfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    mfs:SetPoint("LEFT", 10, 0)
    mfs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    more._sync = function()
        mfs:SetText(("+%d more tracked"):format(math.max(0, #Spells() - ROW_MAX)))
    end
    AT.RowButton(pg, "Clear all", function()
        for i = #Spells(), 1, -1 do SW.RemoveAt(i) end
        AT.LayoutPage(pg)
    end, function() return #Spells() > 0 end, 140, nil, true)
    AT.RowDesc(pg, "These are the abilities the swing timer draws ticks for, and the list the Queue tab picks from.")

    AT.Section(pg, "Add an ability")
    local pending = ""
    local inRow = AT.RowInput(pg, "Spell name or ID",
        function() return pending end,
        function(v) pending = v or "" end, nil,
        "A spell NAME follows your known rank automatically, so learning a new rank needs nothing. An ID pins that exact rank.",
        "e.g. Raptor Strike", true)
    local box = inRow._colCtrl
    -- read the box itself and clear it BEFORE dropping focus: the theme's
    -- focus-lost commit writes the box text back into `pending`
    local function DoAdd()
        local txt = (box:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if txt == "" then return end
        SW.AddSpell(txt)
        box:SetText("")
        pending = ""
        if box:HasFocus() then box:ClearFocus() end
        AT.LayoutPage(pg)
    end
    local add = AT.MakeSmallButton(inRow, "Add", 56)
    add:SetPoint("LEFT", box, "RIGHT", 6, 0)
    add:SetScript("OnClick", function() AT.CloseDropdown() DoAdd() end)
    box:HookScript("OnEnterPressed", DoAdd)
end

local function BuildQueue(pg)
    local queueOn = function() local d = PDB() return d ~= nil and d.queue == true end
    local hasSpell = function() return queueOn() and PET.GetQueueSpell() ~= nil end

    AT.Section(pg, "Queue a next-attack ability")
    AT.RowToggle(pg, "Queue an ability with picked abilities", queueOn,
        function(v) PET.SetOption("queue", v) end, nil,
        "Pressing a picked ability also queues your chosen ability for your next weapon attack, like Raptor Strike or Heroic Strike. The ability's own spell still casts normally.")

    -- ONE CONTROL (Arc, 2026-09-23: "you have Pick from bars and then Queue
    -- this, like double"). There used to be a current-ability row with its own
    -- Pick button, PLUS a list of every tracked ability each with its own
    -- "Queue this", PLUS a Clear button - three ways to set one value, with
    -- the current ability printed twice. A dropdown IS the question: it shows
    -- what is queued now, and every way of changing it lives inside it.
    local PICK = "\1pick"
    AT.RowDropdown(pg, panel, "Ability to queue",
        function() return PET.GetQueueSpell() or "" end,
        function(v)
            if v == PICK then
                AW.SetSetup(true, "spell")     -- hands off to the bar picker
            else
                PET.SetQueueSpell(v ~= "" and v or nil)
            end
            AT.LayoutPage(pg)
        end,
        function()
            local out = { { text = "|cff7f8c9eNone|r", value = "" } }
            local seen, cur = {}, PET.GetQueueSpell()
            for _, entry in ipairs(Spells()) do
                local sid = SW.Resolve(entry)
                local name = sid and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                if name and not seen[name] then
                    seen[name] = true
                    local tex = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
                    out[#out + 1] = { text = Icon(tex) .. name, value = name }
                end
            end
            -- an ability picked off the bars is not in the tracked list, so it
            -- would have no entry to match and the box would read blank
            if cur and cur ~= "" and not seen[cur] then
                out[#out + 1] = { text = Icon(PET.QueueIcon()) .. cur, value = cur }
            end
            out[#out + 1] = { text = "Pick from my bars...", value = PICK }
            return out
        end,
        queueOn)
    AT.RowDesc(pg, "Your tracked abilities are listed first. Pick from my bars lets you choose anything else on your action bars.",
        nil, queueOn)
    AT.Section(pg, "Which abilities queue it", { visibleFn = hasSpell })
    AT.RowButton(pg, "Pick on my bars", function()
        AW.SetSetup(true, "queue")
    end, hasSpell, 140, "Choose which abilities arm the queue")
    AT.RowDesc(pg, "These are separate from your pet abilities, so an ability can queue without sending the pet.",
        nil, function() return hasSpell() and #PET.QueueEntries() == 0 end)
    PickListBlock(pg, PET.QueueEntries, "queue", PET.ClearQueuePicks,
        "Clear all queueing abilities")
    -- was its own "Notes" section: a header holding one paragraph is not a
    -- section, it is a caption on the section above it
    AT.RowDesc(pg, "Next-attack abilities are off the global cooldown, so this never delays the ability's own spell. Choose a normal ability by mistake and the queue is simply refused - the ability itself still works.",
        nil, hasSpell)
end

local function BuildPetSetup(pg)
    AT.Section(pg, "Pet attack")
    AT.RowToggle(pg, "Send my pet with picked abilities",
        function() local d = PDB() return d ~= nil and d.enabled == true end,
        function(v) PET.SetOption("enabled", v) end, nil,
        "Picked abilities also send your pet at your hostile target when you click them or press their keybind. Your spell still casts normally. Off: every button behaves normally.")
    AT.RowToggle(pg, "Also when clicking with the mouse",
        function() local d = PDB() return d ~= nil and d.mouse == true end,
        function(v) PET.SetOption("mouse", v) end, nil,
        "On: clicking a picked ability with the mouse also sends the pet and queues your ability. Off: only its keybind does, and the mouse works the button exactly like before.")
    AT.RowToggle(pg, "Show Arc markers on picked abilities",
        function() local d = PDB() return d ~= nil and d.marker == true end,
        function(v) PET.SetOption("marker", v) end, nil,
        "Small corner icons showing what each button does: the pet Attack icon bottom-left on abilities that send your pet, and the queued ability's own icon bottom-right on abilities that queue it.")

    AT.Section(pg, "Status")
    local st = AT.AddRow(pg, LAY.descH)
    local sfs = st:CreateFontString(nil, "OVERLAY")
    sfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    sfs:SetPoint("LEFT", 10, 0)
    sfs:SetPoint("RIGHT", -10, 0)
    sfs:SetJustifyH("LEFT")
    st._sync = function()
        local d = PDB()
        local pets, queues = #PET.PickEntries(), #PET.QueueEntries()
        -- each job reports only if it is BOTH switched on and actually picked
        local petLive = (d ~= nil and d.enabled and pets > 0) and true or false
        local queueLive = (d ~= nil and d.queue and PET.GetQueueSpell() and queues > 0)
            and true or false
        if PET.IsPending() then
            sfs:SetText("Changes apply when combat ends.")
            sfs:SetTextColor(1, 0.82, 0.2)
        elseif not (petLive or queueLive) then
            sfs:SetText("Nothing active - every button behaves normally.")
            sfs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        else
            -- VERIFIED counts: what the game's own override lookup confirms
            local r = PET.bindReport
            local total = r and #r.list or 0
            local ok = r and r.verified or 0
            if total > 0 and ok < total then
                sfs:SetText(("%d of %d keybinds redirected - try /reload"):format(ok, total))
                sfs:SetTextColor(1, 0.82, 0.2)
            else
                local parts = {}
                if petLive then
                    parts[#parts + 1] = ("%d abilit%s send the pet")
                        :format(pets, pets == 1 and "y" or "ies")
                end
                if queueLive then
                    parts[#parts + 1] = ("%d queue%s %s")
                        :format(queues, queues == 1 and "s" or "", PET.GetQueueSpell())
                end
                sfs:SetText(("%s, %d keybind%s redirected"):format(
                    table.concat(parts, ", "), ok, ok == 1 and "" or "s"))
                sfs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
            end
        end
    end
    AT.RowDesc(pg, "Your pet is sent at your current hostile target before the spell. In vehicles and pet battles the keybinds go back to normal automatically.")
end

local function BuildPetAbilities(pg)
    AT.Section(pg, "Abilities that send my pet")
    AT.RowButton(pg, "Pick on my bars", function()
        AW.SetSetup(true, "pet")
    end, nil, 140, "Choose which abilities send your pet")
    AT.RowDesc(pg, "Nothing picked yet - use Pick on my bars, then click the abilities that should send your pet.",
        nil, function() return #PET.PickEntries() == 0 end)
    PickListBlock(pg, PET.PickEntries, "pet", PET.ClearPicks, "Clear all pet abilities")
    AT.RowDesc(pg, "Picks follow the ability, so moving it to another button keeps it working. Put the same ability on two bars and both copies do the job.",
        nil, function() return #PET.PickEntries() > 0 end)
end

-- Arc Weave absorbed both of these. Left enabled they run their own overlays
-- and markers alongside ours: two pet overlays fighting for the same button,
-- two sets of ticks on the same swing bar.
local OLD_ADDONS = { ArcNextSwing = "Arc Next Swing", ArcPetAttack = "Arc Pet Attack" }

local function ConflictText()
    local on = {}
    for folder, label in pairs(OLD_ADDONS) do
        local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(folder)
        if loaded then on[#on + 1] = label end
    end
    if #on == 0 then return nil end
    return ("Still enabled: %s. Arc Weave replaces %s - turn %s off in the AddOns list and reload, or you will get two sets of markers and two overlays on the same button. Your settings have already been copied across."):format(
        table.concat(on, " and "), #on == 1 and "it" or "them", #on == 1 and "it" or "them")
end

local function BuildAddon(pg)
    AT.Section(pg, "Old addons", { visibleFn = function() return ConflictText() ~= nil end })
    local warn = AT.AddRow(pg, LAY.descH, function() return ConflictText() ~= nil end)
    local wfs = warn:CreateFontString(nil, "OVERLAY")
    wfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    wfs:SetPoint("TOPLEFT", 10, -2)
    wfs:SetJustifyH("LEFT")
    wfs:SetJustifyV("TOP")
    wfs:SetWordWrap(true)
    wfs:SetTextColor(1, 0.82, 0.2)
    warn._minH = LAY.descH
    warn._sync = function()
        local w = pg:GetWidth() or 0
        if w < 60 then return end
        wfs:SetText(ConflictText() or "")
        wfs:SetWidth(w - 36)
        local want = math.max(warn._minH, math.floor((wfs:GetStringHeight() or 12) + 8))
        if warn._h ~= want then warn._h = want warn:SetHeight(want) end
    end

    AT.Section(pg, "Panel")
    -- isPct means a 0..1 value RENDERED as a percent: the theme multiplies for
    -- display and divides typed input back, so this works in scale units, not
    -- in percent. SetUIScale clamps to its own 0.7..2 range as well.
    AT.RowSlider(pg, "Panel size",
        function() return AT.uiScale or 1 end,
        function(v)
            AT.SetUIScale(v)
            local d = SDB()
            if d then d.panelScale = AT.uiScale end
        end,
        0.7, 2.0, 0.05, true)
    AT.RowDesc(pg, "Arc Weave already sizes this window to the same share of the screen on any resolution. This nudges it up or down from there if you want it bigger or smaller.")

    AT.Section(pg, "Addon")
    AT.RowToggle(pg, "Minimap button",
        function() local d = SDB() return not (d and d.minimapHidden) end,
        function(v)
            local d = SDB()
            if not d then return end
            d.minimapHidden = (not v) or nil
            if mmBtn then mmBtn:SetShown(v and true or false) end
        end, nil,
        "Left-click opens this panel, right-click turns the swing ticks on or off, drag moves it around the minimap.")
    AT.RowDesc(pg, "Slash commands: /arcweave opens this panel. /ans and /apa still work for the swing and pet sides.")

    AT.Section(pg, "Troubleshooting")
    AT.RowButton(pg, "Debug window", function() AW.ToggleDebug() end,
        nil, 140, "Show what the swing engine sees", true)
    AT.RowDesc(pg, "Useful when a tick is missing or lands in the wrong place.")
end

-- TWO LEVELS. The addon does two separate jobs, so they are the top row and
-- everything that belongs to a job lives under it. The theme already draws
-- this: a second AT.TabRow at fontSize 11 (what Arc UI Forever uses for
-- Load Conditions / Anchoring / Visibility).
local GROUPS = {
    { name = "Next Melee Weave", subs = { "Swing Timer", "Markers", "Tracked", "Queue" } },
    { name = "Pet Weave",        subs = { "Setup", "Abilities" } },
    { name = "Addon",            subs = { "Addon" } },
}

local BUILDERS = {
    ["Swing Timer"] = BuildSwing, ["Markers"] = BuildMarkers,
    ["Tracked"] = BuildAbilities, ["Queue"] = BuildQueue,
    ["Setup"] = BuildPetSetup,    ["Abilities"] = BuildPetAbilities,
    ["Addon"] = BuildAddon,
}

local GROUP_NAMES = {}
for i, g in ipairs(GROUPS) do GROUP_NAMES[i] = g.name end

local function GroupOf(name)
    for _, g in ipairs(GROUPS) do if g.name == name then return g end end
    return GROUPS[1]
end

--[[ PANEL ==================================================================]]

local SelectSub

local function SelectTab(name)
    if not panel then return end
    local g = GroupOf(name)
    ui.tab = g.name
    -- remember where you were inside a group, so switching back to Pet Weave
    -- and coming home does not dump you on the first sub-tab every time
    ui.sub[g.name] = ui.sub[g.name] or g.subs[1]
    panel._mainH = panel._strip:Set(GROUP_NAMES, g.name, SelectTab, 12)
    SelectSub(ui.sub[g.name])
end

-- a single-leaf group (Addon) hides the sub strip entirely rather than drawing
-- a lone chip that does nothing
function SelectSub(leaf)
    if not panel then return end
    local g = GroupOf(ui.tab)
    ui.sub[g.name] = leaf
    local mainH = panel._mainH or 24
    local subH = 0
    if #g.subs > 1 then
        panel._sub:Show()
        panel._sub:ClearAllPoints()
        panel._sub:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(38 + mainH + 4))
        panel._sub:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -(38 + mainH + 4))
        subH = (panel._subStrip:Set(g.subs, leaf, SelectSub, 11) or 22) + 4
        panel._sub:SetHeight(subH)
    else
        panel._sub:Hide()
    end
    for n, pg in pairs(pages) do
        pg:ClearAllPoints()
        pg:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(38 + mainH + 6 + subH))
        pg:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 40)
        pg:SetShown(n == leaf)
    end
    -- the engine draws sample ticks only while the Markers sub-tab is up
    if SW.SetMarkerPreview then SW.SetMarkerPreview(leaf == "Markers") end
    if pages[leaf] then AT.LayoutPage(pages[leaf]) end
end

local function BuildPanel()
    local win = AT.CreateWindow("ArcWeavePanel", {
        title = "|cff3fc9f2Arc|r|cffd5e2f2 Weave|r",
        version = Version(),
        w = 500, h = 600, minW = 460, minH = 500,
    })
    panel = win

    local strip = AT.TabRow(win)
    strip:SetPoint("TOPLEFT", 10, -38)
    strip:SetPoint("TOPRIGHT", -10, -38)
    strip:SetHeight(24)
    strip:SetFrameLevel(win:GetFrameLevel() + 6)
    win._strip = strip

    -- the sub strip sits in its own container so SelectSub can re-anchor and
    -- hide it without disturbing the main row above it
    local sub = CreateFrame("Frame", nil, win)
    sub:SetHeight(22)
    sub:SetFrameLevel(win:GetFrameLevel() + 6)
    local subStrip = AT.TabRow(sub)
    subStrip._openFill = COL.panel
    subStrip:SetPoint("TOPLEFT", 8, 0)
    subStrip:SetPoint("BOTTOMRIGHT", -8, 2)
    win._sub, win._subStrip = sub, subStrip

    for _, g in ipairs(GROUPS) do
        for _, leaf in ipairs(g.subs) do
            pages[leaf] = AT.NewPage(win)
            BUILDERS[leaf](pages[leaf])
        end
    end

    AT.AddDiscordFooter(win, "ArcWeaveDiscordCopy")

    -- CreateWindow owns OnShow/OnDragStop via SetScript: consumers HOOK
    win:HookScript("OnShow", function()
        if PET.CheckAndHeal then PET.CheckAndHeal("panel opened") end
        SelectTab(ui.tab)
    end)
    win:HookScript("OnHide", function()
        if SW.SetMarkerPreview then SW.SetMarkerPreview(false) end
    end)
    win:HookScript("OnDragStop", function(self)
        local d = SDB()
        if d then d.panelL, d.panelT = self:GetLeft(), self:GetTop() end
    end)
    function win:RefreshActive() SelectTab(ui.tab) end

    local d = SDB()
    if d and d.panelL and d.panelT then
        win:ClearAllPoints()
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", d.panelL, d.panelT)
    end
    return win
end

function AW.RefreshPanel()
    local leaf = ui.sub[ui.tab]
    if panel and panel:IsShown() and leaf and pages[leaf] then AT.LayoutPage(pages[leaf]) end
    if ui.setup then
        for name, pk in pairs(pickers) do
            if pk:IsShown() then PaintPicker(pk, name) end
        end
        UpdateBanner()
    end
end

function AW.TogglePanel()
    if not panel then BuildPanel() end
    panel:SetShown(not panel:IsShown())
end

--[[ DEBUG WINDOW ===========================================================]]

local function BuildDebug()
    dbg = AT.CreateWindow("ArcWeaveDebug", {
        title = "|cff3fc9f2Arc|r|cffd5e2f2 Weave debug|r",
        w = 560, h = 460, minW = 420, minH = 320,
    })
    local body = CreateFrame("Frame", nil, dbg)
    body:SetPoint("TOPLEFT", 10, -40)
    body:SetPoint("BOTTOMRIGHT", -10, 40)
    local fs = body:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    fs:SetPoint("TOPLEFT")
    fs:SetPoint("TOPRIGHT")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    dbg.text = fs
    dbg:HookScript("OnShow", function() AW.RefreshDebug(true) end)
    return dbg
end

function AW.RefreshDebug(force)
    if not dbg or not dbg:IsShown() then return end
    if not (force or dbg:IsShown()) then return end
    local snap = SW.Snapshot and SW.Snapshot()
    dbg.text:SetText(type(snap) == "table" and table.concat(snap, "\n")
        or tostring(snap or "no snapshot"))
end

function AW.ToggleDebug()
    if not dbg then BuildDebug() end
    dbg:SetShown(not dbg:IsShown())
end

--[[ MINIMAP ================================================================]]

local function BuildMinimapButton()
    local d = SDB()
    if not d or mmBtn or not Minimap then return end
    local btn = CreateFrame("Button", "ArcWeaveMinimapButton", Minimap)
    mmBtn = btn
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    -- the bare sword-and-claws glyph (no box), centred on the disc like ArcTrack's
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture("Interface\\AddOns\\ArcWeave\\Media\\AW_Minimap")
    icon:SetPoint("CENTER", bg, "CENTER")
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local function PaintState()
        local cur = SDB()
        local on = cur and cur.enabled
        icon:SetDesaturated(not on)
        icon:SetVertexColor(1, 1, 1, on and 1 or 0.55)
    end

    local function Position()
        local cur = SDB()
        local angle = math.rad((cur and cur.minimapAngle) or 125)
        local r = (Minimap:GetWidth() / 2) + 5
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(angle), r * math.sin(angle))
    end
    btn:SetScript("OnDragStart", function()
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local es = Minimap:GetEffectiveScale()
            local cur = SDB()
            if cur then
                cur.minimapAngle = math.deg(math.atan2(cy / es - my, cx / es - mx))
            end
            Position()
        end)
    end)
    btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            local cur = SDB()
            if cur then SW.SetEnabled(not cur.enabled) end
            AW.RefreshPanel()
        else
            AW.TogglePanel()
        end
    end)
    btn:SetScript("OnEnter", function()
        local s, p = SDB(), PDB()
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff3fc9f2Arc|r Weave")
        if s and s.enabled then
            GameTooltip:AddLine("Swing ticks: ON", 0.30, 0.95, 0.35)
        else
            GameTooltip:AddLine("Swing ticks: OFF", 0.90, 0.25, 0.25)
        end
        local n = #Spells()
        GameTooltip:AddLine(("%d abilit%s tracked"):format(n, n == 1 and "y" or "ies"),
            COL.ink[1], COL.ink[2], COL.ink[3])
        local pets = #PET.PickEntries()
        GameTooltip:AddLine(("%d abilit%s send the pet"):format(pets, pets == 1 and "y" or "ies"),
            COL.ink[1], COL.ink[2], COL.ink[3])
        local spell = PET.GetQueueSpell()
        if p and p.queue and spell then
            local q = #PET.QueueEntries()
            GameTooltip:AddLine(("%d abilit%s queue %s"):format(q, q == 1 and "y" or "ies", spell),
                COL.ink[1], COL.ink[2], COL.ink[3])
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: options", COL.dim[1], COL.dim[2], COL.dim[3])
        GameTooltip:AddLine("Right-click: swing ticks on/off", COL.dim[1], COL.dim[2], COL.dim[3])
        GameTooltip:AddLine("Drag: move this button", COL.dim[1], COL.dim[2], COL.dim[3])
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    Position()
    PaintState()
    btn:SetShown(not d.minimapHidden)

    -- both engines repaint through their own namespace; one implementation
    SW.PaintMinimap = PaintState
    PET.PaintMinimap = PaintState
    SW.mmBtn = btn
end

--[[ ENGINE HOOKS ===========================================================]]

-- Each engine calls these on ITS OWN table, so both names must exist. The
-- swing engine logs in first (its file loads first), and whichever arrives
-- first builds the button; the second call is a no-op.
local function OnReady()
    local d = SDB()
    if d and d.panelScale then AT.SetUIScale(d.panelScale) end
    BuildMinimapButton()
end

SW.OnReady = OnReady
PET.OnReady = OnReady
SW.RefreshPanel = AW.RefreshPanel
PET.RefreshPanel = AW.RefreshPanel
SW.TogglePanel = AW.TogglePanel
PET.TogglePanel = AW.TogglePanel
SW.RefreshDebug = AW.RefreshDebug
SW.ToggleDebug = AW.ToggleDebug

function PET.OnApplied()
    AW.RefreshPanel()
end

--[[ SLASH ==================================================================]]

SLASH_ARCWEAVE1 = "/arcweave"
SLASH_ARCWEAVE2 = "/aw"
SlashCmdList.ARCWEAVE = function(input)
    local cmd = ((input or ""):match("^%s*(%S*)") or ""):lower()
    if cmd == "pet" then
        AW.SetSetup(true, "pet")
    elseif cmd == "queue" then
        AW.SetSetup(true, "queue")
    elseif cmd == "ability" or cmd == "spell" then
        AW.SetSetup(true, "spell")
    elseif cmd == "debug" then
        AW.ToggleDebug()
    else
        AW.TogglePanel()
    end
end
