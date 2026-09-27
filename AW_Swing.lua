-- ArcNextSwing - projects next-melee cooldowns onto Blizzard's swing timer
-- (WoW Forever): "when is Raptor Strike back, and on which swing?"
--
-- SECRET-SAFE BY CONSTRUCTION. In-game proof (debug snapshot 2026-09-17):
-- on Forever a cooldown's startTime/duration are SECRET in every combat -
-- and so is UnitAttackSpeed - not only in restricted content. So Lua NEVER
-- reads the remaining cooldown. The pieces:
--   * swing clock (PLAIN): Blizzard's SwingTimerMainHandFrame stores
--     swingDuration/swingEndTime; reading its fields never taints. Our own
--     PLAYER_SWING stamps cover the event-order race between the frames.
--   * cooldown: a duration object from GetSpellCooldownDuration(sid, true)
--   * per swing cycle k, a transparent RULER StatusBar spans the swing bar
--     with min/max = [k*D - e, (k+1)*D - e] (plain: D = swing length, e =
--     elapsed in this swing) and value = remaining (secret; SetValue is a
--     safe sink). Its fill edge lands exactly at the ready moment's phase
--     inside swing k, and the tick anchors to that edge (anchor-to-fill-edge
--     - Blizzard's own swing pip and UltimateCastbars' kick tick do this).
--   * WHICH cycle is the real one is decided by the engine: each marker's
--     alpha = EvaluateRemainingDuration(window curve) - 1 inside its window,
--     0 outside. No compare ever touches a secret.
--   e + remaining is constant through a swing, so everything set at a
--   refresh stays correct until the next swing or cooldown change.
--   * READY vs ON COOLDOWN comes from a hidden shadow Cooldown fed the
--     GCD-immune duration: its IsShown() is a PLAIN boolean (the ArcDisplay
--     shadow law), and its OnCooldownDone fires at the exact ready moment -
--     GetTime() there is a plain stamp of WHERE in the swing it came back.
--
-- Marker language:
--   GOLD tick mid-bar  = comes off cooldown at that point of THIS swing
--   AMBER tick "+N"    = comes off cooldown at that point, N swings ahead
--   GREEN              = ready - it lands on this swing
--   CYAN               = queued - this swing IS this attack
--   RED at right end   = further out than MAX_AHEAD swings
-- Ready/queued placement (DB.jumpToEnd):
--   default - the tick STAYS where it came off cooldown in this swing and
--             only recolors (ready since before this swing = left edge)
--   on      - the marker jumps to the bar's right end, where the attack lands
--
-- Zero idle: no OnUpdate, no tickers - events, the shadow's OnCooldownDone,
-- and one generation-guarded swing-landed timer.
--
-- OFF HAND (opt-in, DB.offHand): the SAME engine runs a second LANE on
-- Blizzard's off-hand bar - its own overlay, markers, shadows, swing clock
-- and timer, so nothing it does can reach the main hand. Its icons hang
-- BELOW its bar by default: Blizzard stacks that bar right under the main
-- hand's, so icons above it would sit on top of the main-hand bar.

-- NAMESPACE ISOLATION. Every file in an addon is handed the SAME shared
-- table, and this engine and the pet engine both define OnReady, PaintMinimap,
-- GetDB and friends - they would overwrite each other. Pointing the file's own
-- `NS` local at a SUB-TABLE isolates all of it in one line: every `NS.x` below
-- is really `shared.Swing.x`, with not one other line of this engine touched.
-- The UI defines its callbacks (OnReady, PaintMinimap, RefreshDebug) there too.
local ADDON, AW = ...
local NS = AW.Swing

local COL = {
    gold  = { 1.00, 0.82, 0.20 },
    amber = { 1.00, 0.55, 0.15 },
    green = { 0.30, 0.95, 0.35 },
    arc   = { 0.247, 0.788, 0.949 },
    red   = { 0.90, 0.25, 0.25 },
}

-- swings ahead still worth projecting (Raptor Strike: 6s CD vs ~3s swing
-- lands 1-2 swings out; 4 covers ~12s on a 3s weapon)
local MAX_AHEAD = 4
local EPS = 0.001        -- curve ramp width (1 ms)
local BIG = 1e6          -- open-ended window bound
local WHITE = "Interface\\Buttons\\WHITE8x8"

-- Marker sizing. Every `d` is Arc's tuned look (set 2026-09-21: 25px icons
-- lifted 6px off the tick, stacked flush), so a fresh install draws it
-- without a slider ever being touched. tickHeight is a MULTIPLE of the swing
-- bar's height, so the tick still tracks a resized bar at the default 1.0.
local SIZE = {
    tickWidth  = { d = 2,   min = 1,   max = 12,  step = 1 },
    tickHeight = { d = 1.0, min = 0.4, max = 3.0, step = 0.1 },
    iconSize   = { d = 25,  min = 8,   max = 48,  step = 1 },
    iconGap    = { d = 6,   min = 0,   max = 40,  step = 1 },   -- tick -> icon
    iconStack  = { d = 0,   min = 0,   max = 30,  step = 1 },   -- icon -> icon
    badgeSize  = { d = 10,  min = 8,   max = 24,  step = 1 },
}

local DB
local marks = {}              -- flat list of every marker, for re-sizing
local tracked = {}            -- { entry=..., sid=..., icon=... } resolved list

-- one read path for a size: an absent key means "never touched", which must
-- render as the default look and never as zero
local function Opt(k)
    local s = SIZE[k]
    local v = DB and DB[k]
    if type(v) ~= "number" then return s.d end
    if v < s.min then return s.min elseif v > s.max then return s.max end
    return v
end

local function ShowIcon()
    return not (DB and DB.hideIcon)
end

local MAINHAND = (Enum and Enum.PlayerSwingType and Enum.PlayerSwingType.MainHand) or 0
local OFFHAND = (Enum and Enum.PlayerSwingType and Enum.PlayerSwingType.OffHand) or 1

-- ONE LANE PER SWING BAR: our overlay on that Blizzard bar (host), its
-- per-tracked-spell marker sets (slots), its PLAYER_SWING stamps (swing),
-- the generation that invalidates its swing-landed timer (gen), its preview
-- and its last drawn pass (diag). `opt` names the DB switch a lane needs on
-- top of the master one - the main hand has none.
local MH = { name = "main hand", frame = "SwingTimerMainHandFrame", swingType = MAINHAND,
             slots = {}, swing = {}, gen = 0, previewMarks = {} }
local OH = { name = "off hand", frame = "SwingTimerOffHandFrame", swingType = OFFHAND,
             opt = "offHand", slots = {}, swing = {}, gen = 0, previewMarks = {} }
local lanes = { MH, OH }

local function LaneOn(L)
    if not DB or DB.enabled == false then return false end
    return L.opt == nil or DB[L.opt] == true
end

-- the off hand's icons hang BELOW its bar unless moved above. Blizzard
-- stacks main hand / off hand / ranged top to bottom, so in the default
-- layout icons above would cover the main-hand bar; below only ever meets
-- the ranged bar
local function IconsBelow(L)
    return L == OH and not (DB and DB.ohIconsAbove)
end

-- default tracked spells per class, seeded once (names, never IDs - on
-- ranked realms a name always resolves to the rank the player knows)
local CLASS_SEEDS = {
    HUNTER = { "Raptor Strike" },
}

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- ── resolve + plain state reads ─────────────────────────────────────────────
local function ResolveEntry(entry)
    local sid = tonumber(entry)
    if not sid and C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
        sid = C_Spell.GetSpellIDForSpellIdentifier(entry)
    end
    return sid
end

local function RebuildTracked()
    tracked = {}
    local list = DB and DB.spells
    if not list then return end
    for _, entry in ipairs(list) do
        local sid = ResolveEntry(entry)
        if sid then
            tracked[#tracked + 1] = {
                entry = entry,
                sid = sid,
                icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid) or 134400,
            }
        end
    end
end

-- IsCurrentSpell read plain in-game; guarded anyway - a secret boolean
-- would throw on a test
local function IsQueued(sid)
    if not (C_Spell and C_Spell.IsCurrentSpell) then return false end
    local q = C_Spell.IsCurrentSpell(sid)
    if IsSecret(q) then return false end
    return q == true
end

-- ── queued bar colour (opt-in, DB.queueBarTint) ─────────────────────────────
-- While a next-melee ability is queued, the main-hand bar's FILL takes the
-- chosen colour. Blizzard sets that fill's atlas once (InitializeBarPresentation)
-- and never re-tints it, so ours holds; it is desaturated first so the colour
-- lands clean instead of mixing with the gold art. Only widget methods on the
-- texture, no field writes on Blizzard's frame. Undone only if WE tinted it,
-- so an option left off never touches the bar. Event-driven: queue changes
-- (CURRENT_SPELL_CAST_CHANGED), main-hand swings and spell changes.
local barTinted = false

local function IsColor(c) return type(c) == "table" and type(c[1]) == "number" end

-- the DEFAULT colour, for abilities without their own (nil = cyan)
local function QueueBarColor()
    local c = DB and DB.queueBarColor
    if IsColor(c) then return c end
    return COL.arc
end

-- per tracked ability, keyed by the entry exactly as the Tracked list stores
-- it (a name or an ID), so it survives the list being reordered
local function AbilityQueueColor(entry)
    local map = DB and DB.queueBarColors
    local c = map and map[tostring(entry)]
    if IsColor(c) then return c end
    return QueueBarColor()
end

-- the colour of whatever is queued right now, nil when nothing is
local function QueuedColor()
    for _, rec in ipairs(tracked) do
        if IsQueued(rec.sid) then return AbilityQueueColor(rec.entry) end
    end
    -- the Pet Weave queue ability counts even when it is not a tracked tick
    local pet = AW.Pet and AW.Pet.GetQueueSpell and AW.Pet.GetQueueSpell()
    local sid = pet and ResolveEntry(pet)
    if sid and IsQueued(sid) then return QueueBarColor() end
    return nil
end

local function PaintQueueBar()
    local f = _G[MH.frame]
    local bar = f and f.StatusBar
    local tex = bar and bar:GetStatusBarTexture()
    if not tex then return end
    local c = DB and DB.queueBarTint == true and QueuedColor()
    if c then
        tex:SetDesaturated(true)
        tex:SetVertexColor(c[1], c[2], c[3])
        barTinted = true
    elseif barTinted then
        tex:SetDesaturated(false)
        tex:SetVertexColor(1, 1, 1)
        barTinted = false
    end
end

-- BLIZZARD'S FRAME IS THE AUTHORITY for a lane's swing clock; our
-- PLAYER_SWING stamps win when they are newer (both frames get the event and
-- their order is undefined, so Blizzard's fields can lag one swing inside our
-- handler). Returns start, duration, end, source - all plain.
local function SwingState(L)
    local bStart, bDur, bEnd
    local f = _G[L.frame]
    if f then
        local endT, dur = f.swingEndTime, f.swingDuration
        if type(endT) == "number" and type(dur) == "number"
            and not IsSecret(endT) and not IsSecret(dur) and dur > 0 then
            bStart, bDur, bEnd = endT - dur, dur, endT
        end
    end
    local sw = L.swing
    local oStart = sw.start
    if bStart and (not oStart or bStart >= oStart - 0.001) then
        return bStart, bDur, bEnd, "blizzard frame"
    end
    if oStart then return oStart, sw.dur, sw.endT, "PLAYER_SWING" end
    return nil
end

local function LiveSwing(L)
    local _, _, endT = SwingState(L)
    return endT ~= nil and GetTime() < endT
end

-- any lane mid-swing: the gate for event-driven repaints
local function AnyLive()
    return LiveSwing(MH) or LiveSwing(OH)
end

-- ── marker widgets ──────────────────────────────────────────────────────────
local RefreshMarks          -- forward: assigned below, called at runtime

local refreshQueued = false
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        if RefreshMarks then RefreshMarks() end
    end)
end

-- EVERY size knob in one place, applied to a live marker. Called once at
-- creation and again whenever a slider moves or Blizzard's bar resizes, so a
-- marker that already exists can never keep a stale size. Writes only - the
-- tick's own geometry is never read back (its anchor chain runs through a
-- secret-driven fill edge; drawing it is fine, measuring it is not).
local function ApplyMarkSizing(m, i)
    local iconSz = Opt("iconSize")
    local tickH = Opt("tickHeight")
    m.tick:SetWidth(Opt("tickWidth"))
    -- height rides on the SAME two-point anchor the tick always used: at 1.0
    -- both offsets are zero and it spans the bar exactly as before, above
    -- that it overhangs the bar, below it insets
    local over = 0
    if tickH ~= 1 then
        local bh = m.hostFrame
        bh = bh and bh:GetHeight() or 0
        if bh > 0 then over = bh * (tickH - 1) / 2 end
    end
    m.tick:SetPoint("TOP", m.anchor, "TOPRIGHT", 0, over)
    m.tick:SetPoint("BOTTOM", m.anchor, "BOTTOMRIGHT", 0, -over)
    local show = ShowIcon()
    m.icon:SetSize(iconSz, iconSz)
    m.icon:SetShown(show)
    m.iconEdge:SetSize(iconSz + 2, iconSz + 2)   -- a 1px rim, not a spacing
    m.iconEdge:SetShown(show)
    -- iconGap lifts the icon off the tick; iconStack is the extra breathing
    -- room between tracked spells whose icons land on the same spot
    local gap = Opt("iconGap")
    local step = iconSz + Opt("iconStack")
    -- which side is a live option on the off hand, and a stale TOP point
    -- left beside a new BOTTOM one would stretch the icon: clear on a flip
    local below = IconsBelow(m.lane)
    if m.iconBelow ~= below then
        m.icon:ClearAllPoints()
        m.iconBelow = below
    end
    if below then
        m.icon:SetPoint("TOP", m.tick, "BOTTOM", 0, -(gap + (i - 1) * step))
    else
        m.icon:SetPoint("BOTTOM", m.tick, "TOP", 0, gap + (i - 1) * step)
    end
    -- SetFont RETURNS false on a size the client refuses instead of raising
    -- (no pcall in any Arc addon): fall back to the default rather than
    -- leaving the badge fontless
    if not m.badge:SetFont(STANDARD_TEXT_FONT, Opt("badgeSize"), "OUTLINE") then
        m.badge:SetFont(STANDARD_TEXT_FONT, SIZE.badgeSize.d, "OUTLINE")
    end
end

local function ApplyAllMarkSizing()
    for _, m in ipairs(marks) do ApplyMarkSizing(m, m.slotIndex) end
end

local function EnsureHost(L)
    if L.host then return L.host end
    local blizz = _G[L.frame]
    local bar = blizz and blizz.StatusBar
    if not bar then return nil end
    local host = CreateFrame("Frame", nil, bar)
    host:SetAllPoints()
    host:SetFrameLevel(bar:GetFrameLevel() + 5)
    -- a tick height other than 1.0 is measured off the bar, so it has to be
    -- recomputed when Blizzard's bar changes size (event-driven, no ticker)
    host:SetScript("OnSizeChanged", ApplyAllMarkSizing)
    L.host = host
    return host
end

-- one marker. Ruler markers own a transparent StatusBar whose fill edge
-- carries the tick; end markers pin the tick to the bar's right end. That
-- anchor TARGET is fixed here as m.anchor and never changes; ApplyMarkSizing
-- owns the points themselves (it re-offsets them for tick height). Nothing
-- in the chain is ever read back - a secret-driven edge makes its geometry
-- secret, and drawing that is fine while measuring it is not. `lane` is the
-- bar the marker belongs to (a preview marker's too): it picks the icon side.
-- `rideOn` (optional): a texture whose RIGHT edge the tick is pinned to
-- instead - Blizzard's own swing fill, so a queued tick rides the moving edge
-- to where the swing lands with nothing read back (the Arc Auras "Queued
-- rides the swing" mode).
local function NewMark(i, isRuler, parent, lane, rideOn)
    local m = CreateFrame("Frame", nil, parent)
    m:SetAllPoints(parent)
    m:Hide()
    m.slotIndex = i
    m.hostFrame = parent
    m.lane = lane
    m.tick = m:CreateTexture(nil, "OVERLAY", nil, 3)
    if rideOn then
        m.anchor = rideOn
    elseif isRuler then
        m.bar = CreateFrame("StatusBar", nil, m)
        m.bar:SetAllPoints(m)
        m.bar:SetStatusBarTexture(WHITE)
        m.bar:SetStatusBarColor(0, 0, 0, 0)
        m.anchor = m.bar:GetStatusBarTexture()
    else
        m.anchor = m
    end
    m.icon = m:CreateTexture(nil, "OVERLAY", nil, 5)
    m.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    m.iconEdge = m:CreateTexture(nil, "OVERLAY", nil, 4)
    m.iconEdge:SetColorTexture(0, 0, 0, 0.9)
    m.iconEdge:SetPoint("CENTER", m.icon, "CENTER", 0, 0)
    m.badge = m:CreateFontString(nil, "OVERLAY")
    m.badge:SetPoint("LEFT", m.icon, "RIGHT", 1, 0)
    marks[#marks + 1] = m
    -- sizes (and the tick's own anchor points) all come from here
    ApplyMarkSizing(m, i)
    return m
end

local function Paint(m, rec, color, badge)
    m.tick:SetColorTexture(color[1], color[2], color[3], 0.95)
    m.icon:SetTexture(rec.icon)
    m.icon:SetVertexColor(color[1], color[2], color[3])
    if badge then
        m.badge:SetText(badge)
        m.badge:SetTextColor(color[1], color[2], color[3])
        m.badge:Show()
    else
        m.badge:Hide()
    end
end

-- ── marker preview ──────────────────────────────────────────────────────────
-- Blizzard's swing bar only exists mid-swing, so marker sizes could only be
-- judged at a target dummy. While the panel sits on its Markers tab, draw
-- sample ticks WHERE THE REAL BAR IS, through the SAME NewMark +
-- ApplyMarkSizing path, so what is tuned is what ships.
-- The preview owns NO bar art: over a visible swing bar it is ticks and
-- nothing else, and it only plates the area when that bar is hidden.
-- A real swing takes over entirely: it steps aside rather than double-draw.
-- Each lane previews on its own bar (the off hand only while switched on).

local previewOn = false

-- one sample per marker language: where it sits, its color, its badge
local PREVIEW_SAMPLES = {
    { at = 0.30, color = "gold" },
    { at = 0.58, color = "amber", badge = "+1" },
    { at = 0.84, color = "green" },
}

local function EnsurePreviewBar(L)
    if L.previewBar then return L.previewBar end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:Hide()
    -- NO bar art of our own. When Blizzard's bar is on screen the preview
    -- draws ticks and NOTHING else - a second filled bar painted over the
    -- real one is exactly the thing this is meant to show you. The plate is
    -- only a stand-in for WHERE the bar goes while it is hidden.
    f.plate = f:CreateTexture(nil, "BACKGROUND")
    f.plate:SetAllPoints()
    f.plate:SetColorTexture(0, 0, 0, 0.45)
    f.tag = f:CreateFontString(nil, "OVERLAY")
    f.tag:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    -- main hand: BELOW the bar (icons stack upward, so a label above collides
    -- with them the moment the icon size is turned up). Off hand: BESIDE it,
    -- the one side its icons never use. UpdatePreview moves the main-hand tag
    -- beside its bar as well while the off-hand preview sits right under it.
    if L == MH then
        f.tag:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -4)
        f.tag:SetText("Arc Next Swing preview")
    else
        f.tag:SetPoint("LEFT", f, "RIGHT", 8, 0)
        f.tag:SetText("off hand")
    end
    f.tag:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    L.previewBar = f
    return f
end

-- sit exactly where the real bar sits (it keeps its size and anchors while
-- hidden), and fall back to screen center when Blizzard's frame has none yet
local function PlacePreviewBar(L, f)
    local blizz = _G[L.frame]
    local bar = blizz and blizz.StatusBar
    local w = bar and bar:GetWidth() or 0
    local h = bar and bar:GetHeight() or 0
    if not (w > 20) or not (h > 4) then w, h = 220, 16 end
    f:SetSize(w, h)
    -- MATCH THE REAL BAR'S SCALE. Blizzard's swing timer is an Edit Mode
    -- managed frame and can be scaled; the preview hangs off UIParent, so
    -- without this a 20px icon renders bigger here than it ever will there
    -- and the preview lies about every size on this tab.
    local sc = 1
    if bar then
        local es = bar:GetEffectiveScale()
        local ps = f:GetParent() and f:GetParent():GetEffectiveScale()
        if es and ps and ps > 0 then sc = es / ps end
    end
    f:SetScale(sc)
    f:ClearAllPoints()
    if bar and bar:GetLeft() then
        f:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    elseif L ~= MH and MH.previewBar then
        -- an off-hand bar Blizzard has never placed: stand in right under
        -- the main hand, where its stack puts it (12px bar to bar)
        f:SetPoint("TOPLEFT", MH.previewBar, "BOTTOMLEFT", 0, -12)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -140)
    end
    -- the plate only stands in for a bar that is not on screen
    f.plate:SetShown(not (bar and bar:IsVisible()))
end

-- one lane's preview; returns whether it is showing
local function UpdateLanePreview(L)
    -- a real swing always wins: never two sets of ticks on one bar
    if not previewOn or (L.opt and not (DB and DB[L.opt])) or LiveSwing(L) then
        if L.previewBar then L.previewBar:Hide() end
        return false
    end
    local f = EnsurePreviewBar(L)
    PlacePreviewBar(L, f)
    for i, sample in ipairs(PREVIEW_SAMPLES) do
        local m = L.previewMarks[i]
        if not m then
            -- slot 1 for EVERY sample: the stagger is per TRACKED SPELL, so
            -- faking three slots threw the icons far above the bar as soon as
            -- the icon size went up. One tracked spell = one row, like reality.
            m = NewMark(1, true, f, L)
            L.previewMarks[i] = m
        end
        -- the player's OWN icons, so the preview is their setup, not a mock
        local rec = tracked[i] or tracked[1] or { icon = 134400 }
        m.bar:SetMinMaxValues(0, 1)
        m.bar:SetValue(sample.at)
        Paint(m, rec, COL[sample.color], sample.badge)
        m:SetAlpha(1)
        m:Show()
    end
    f:Show()
    return true
end

local function UpdatePreview()
    UpdateLanePreview(MH)
    local oh = UpdateLanePreview(OH)
    -- under its own bar the main-hand tag would run into the off-hand
    -- preview right below it, so it moves beside the bar while that is up
    local f = MH.previewBar
    if f then
        f.tag:ClearAllPoints()
        if oh then
            f.tag:SetPoint("LEFT", f, "RIGHT", 8, 0)
        else
            f.tag:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -4)
        end
    end
end

-- the panel calls this as its tabs change
function NS.SetMarkerPreview(on)
    previewOn = on and true or false
    UpdatePreview()
end

local function NewCurve()
    local c = C_CurveUtil.CreateCurve()
    if c.SetType and Enum and Enum.LuaCurveType then
        c:SetType(Enum.LuaCurveType.Linear)
    end
    return c
end

-- 1 inside [lo, hi), 0 outside: EPS-wide ramps on a linear curve (the
-- UltimateCastbars-proven construction); values past the end points clamp
local function SetWindow(curve, lo, hi)
    curve:ClearPoints()
    curve:AddPoint(lo - EPS, 0)
    curve:AddPoint(lo, 1)
    curve:AddPoint(hi - EPS, 1)
    curve:AddPoint(hi, 0)
end

-- the proven ArcDisplay shadow: shown, 1x1, off-screen, alpha 0
local function MakeShadow()
    local w = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
    w:SetSize(1, 1)
    w:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -100, -100)
    w:SetAlpha(0)
    w:EnableMouse(false)
    w:SetHideCountdownNumbers(true)
    w:SetDrawEdge(false)
    w:SetDrawBling(false)
    w:Show()
    return w
end

-- a lane's marker set for tracked spell i, built on that lane's overlay
local function EnsureSlot(L, i)
    local S = L.slots[i]
    if S then return S end
    local host = L.host
    S = { rulers = {}, curves = {}, fedAt = 0 }
    for k = 0, MAX_AHEAD do
        S.rulers[k] = NewMark(i, true, host, L)
        S.curves[k] = NewCurve()
    end
    S.endGo = NewMark(i, false, host, L)    -- ready/queued at the right end (jumpToEnd)
    S.endFar = NewMark(i, false, host, L)   -- red (too far out)
    S.spot = NewMark(i, true, host, L)      -- ready/queued IN PLACE (plain 0..1 ruler)
    -- queued, riding Blizzard's fill edge (DB.queueFollow). host's parent IS
    -- that StatusBar (EnsureHost), so its fill texture always exists here.
    S.ride = NewMark(i, false, host, L, host:GetParent():GetStatusBarTexture())
    S.farCurve = NewCurve()
    S.shadow = MakeShadow()
    -- the exact ready moment: stamp WHERE it came back (plain GetTime) and
    -- repaint. Ignored right after a feed so a zero-span feed can never
    -- loop a refresh per frame.
    S.shadow:SetScript("OnCooldownDone", function()
        local t = GetTime()
        if t - S.fedAt > 0.05 then
            S.readyAt = t
            QueueRefresh()
        end
    end)
    L.slots[i] = S
    return S
end

local function HideSlot(S)
    for k = 0, MAX_AHEAD do S.rulers[k]:Hide() end
    S.endGo:Hide()
    S.endFar:Hide()
    S.spot:Hide()
    S.ride:Hide()
end

local function HideLane(L)
    for _, S in pairs(L.slots) do HideSlot(S) end
end

local function HideMarks()
    for _, L in ipairs(lanes) do HideLane(L) end
end

-- ── the projection ──────────────────────────────────────────────────────────
local function RefreshSpell(L, i, rec, sStart, sDur, now)
    local S = EnsureSlot(L, i)
    local e = now - sStart

    -- REAL-cooldown state from the shadow: fed the GCD-immune duration
    -- object, its IsShown() is a PLAIN boolean (the ArcDisplay shadow law),
    -- so a GCD from another ability never reads as "on cooldown". Without
    -- the duration API, fall back to the NeverSecret flags.
    local dur = C_Spell.GetSpellCooldownDuration
        and C_Spell.GetSpellCooldownDuration(rec.sid, true)
    local onCD
    if dur then
        S.fedAt = now
        S.shadow:SetCooldownFromDurationObject(dur, true)
        onCD = S.shadow:IsShown() == true
    else
        local info = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(rec.sid)
        onCD = info ~= nil and info.isActive == true and info.isOnGCD ~= true
    end

    -- the ready MOMENT as a plain GetTime() stamp: the shadow's
    -- OnCooldownDone stamps it exactly; otherwise the first refresh that sees
    -- ready after a cooldown does. Never watched on cooldown since load =
    -- ready since before this swing.
    if onCD then
        S.lastCDSeen = now
    elseif not S.lastCDSeen then
        S.readyAt = S.readyAt or 0
    elseif not S.readyAt or S.readyAt < S.lastCDSeen then
        S.readyAt = now
    end

    local queued = IsQueued(rec.sid)
    if queued or not onCD then
        HideSlot(S)
        local color = queued and COL.arc or COL.green
        local label = queued and "QUEUED" or "READY"
        -- riding: queued only; a ready one keeps its place
        if queued and DB.queueFollow then
            Paint(S.ride, rec, color, nil)
            S.ride:SetAlpha(1)
            S.ride:Show()
            return label .. " - riding the swing's fill edge"
        end
        if DB.jumpToEnd then
            Paint(S.endGo, rec, color, nil)
            S.endGo:SetAlpha(1)
            S.endGo:Show()
            return label .. " - marker at the end of the bar (where the attack lands)"
        end
        -- DEFAULT: the tick stays where it came off cooldown in THIS swing
        -- and queuing only recolors it (plain math on a plain stamp). Ready
        -- since before this swing started = the swing's left edge. Kept HALF
        -- a tick inside the bar so even a wide tick never half-clips.
        local p = 0
        if S.readyAt and S.readyAt > sStart then p = (S.readyAt - sStart) / sDur end
        local w = L.host:GetWidth()
        local half = Opt("tickWidth") / 2
        local px = (w and w > half * 2) and (half / w) or 0
        if p < px then p = px elseif p > 1 - px then p = 1 - px end
        S.spot.bar:SetMinMaxValues(0, 1)
        S.spot.bar:SetValue(p)
        Paint(S.spot, rec, color, nil)
        S.spot:SetAlpha(1)
        S.spot:Show()
        return ("%s - tick stays in place at %.0f%% of this swing"):format(label, p * 100)
    end

    if not dur then
        HideSlot(S)
        return "on cooldown, but no duration object to project"
    end

    -- SECRET in combat: it only ever reaches SetValue (a safe sink). The
    -- shadow already proved a real cooldown is running, so R > 0 here.
    local R = dur:GetRemainingDuration()

    for k = 0, MAX_AHEAD do
        local m = S.rulers[k]
        local lo, hi = k * sDur - e, (k + 1) * sDur - e
        m.bar:SetMinMaxValues(lo, hi)
        m.bar:SetValue(R)
        Paint(m, rec, k == 0 and COL.gold or COL.amber, k > 0 and ("+" .. k) or nil)
        SetWindow(S.curves[k], lo, hi)
        m:SetAlpha(dur:EvaluateRemainingDuration(S.curves[k]))
        m:Show()
    end
    S.endGo:Hide()
    S.spot:Hide()
    -- a queued one that just fired: its rider would keep following the fill
    S.ride:Hide()

    Paint(S.endFar, rec, COL.red, nil)
    SetWindow(S.farCurve, (MAX_AHEAD + 1) * sDur - e, BIG)
    S.endFar:SetAlpha(dur:EvaluateRemainingDuration(S.farCurve))
    S.endFar:Show()

    return "on cooldown - tick placed by the engine (value is secret)"
end

local function RefreshLane(L)
    local host = L.host
    if not host then return end
    local sStart, sDur, sEnd, source = SwingState(L)
    local now = GetTime()
    local live = sEnd ~= nil and now < sEnd
    if not LaneOn(L) or not live or not host:IsVisible() or not C_CurveUtil then
        HideLane(L)
        L.diag = nil
        return
    end
    local diag = { source = source, swingDur = sDur, elapsed = now - sStart, spells = {} }
    for i, rec in ipairs(tracked) do
        local state = RefreshSpell(L, i, rec, sStart, sDur, now)
        diag.spells[#diag.spells + 1] = { name = rec.entry, sid = rec.sid, state = state }
    end
    for i, S in pairs(L.slots) do
        if i > #tracked then HideSlot(S) end
    end
    L.diag = diag
end

-- `only` = the lane whose swing just began (a new swing moves no other
-- lane's markers); nil = every lane (cooldown, queue and spell changes)
RefreshMarks = function(only)
    -- the preview first: a lane's live swing is what makes it step aside
    UpdatePreview()
    for _, L in ipairs(lanes) do
        if only == nil or only == L then RefreshLane(L) end
    end
    if NS.RefreshDebug then NS.RefreshDebug() end
end

-- ── events ──────────────────────────────────────────────────────────────────
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_SWING" then
        local L = (a2 == MAINHAND and MH) or (a2 == OFFHAND and OH) or nil
        -- a switched-off off hand costs nothing: no stamp, no overlay
        -- a landed swing spends the queued ability: the bar colour follows
        if a2 == MAINHAND then PaintQueueBar() end
        if not L or (L.opt and not (DB and DB[L.opt])) then return end
        if type(a1) ~= "number" or IsSecret(a1) or a1 <= 0 then return end
        local sw = L.swing
        sw.start = GetTime()
        sw.dur = a1
        sw.endT = sw.start + a1
        L.gen = L.gen + 1
        local myGen = L.gen
        if EnsureHost(L) then RefreshMarks(L) end
        -- swing landed and no new PLAYER_SWING (combat drop): clear marks
        C_Timer.After(a1 + 0.05, function()
            if L.gen == myGen and not LiveSwing(L) then HideLane(L) UpdatePreview() end
        end)
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "CURRENT_SPELL_CAST_CHANGED" then
        if event == "CURRENT_SPELL_CAST_CHANGED" then PaintQueueBar() end
        if AnyLive() then QueueRefresh() end
    elseif event == "SPELLS_CHANGED" then
        RebuildTracked()
        PaintQueueBar()
        if AnyLive() then QueueRefresh() end
    elseif event == "PLAYER_LOGIN" then
        -- MIGRATION: adopt an Arc Next Swing profile wholesale the first time,
        -- so the merge costs nobody their tracked spells or marker tuning. Only
        -- ever into a FRESH table - a ArcWeave DB with anything in it wins.
        ArcWeaveDB = ArcWeaveDB or {}
        if next(ArcWeaveDB) == nil and type(ArcNextSwingDB) == "table"
            and next(ArcNextSwingDB) ~= nil then
            for k, v in pairs(ArcNextSwingDB) do ArcWeaveDB[k] = v end
            ArcWeaveDB.loads = nil
        end
        DB = ArcWeaveDB
        -- SavedVariables health probe: +1 per UI load, read at PLAYER_LOGIN
        -- (after the client has loaded the saved file - no load-order
        -- confound). Falling back to 1 after several reloads means that
        -- load did NOT read the file.
        DB.loads = (DB.loads or 0) + 1
        if DB.enabled == nil then DB.enabled = true end
        if not DB.spells then
            local _, classFile = UnitClass("player")
            local seed = CLASS_SEEDS[classFile]
            DB.spells = {}
            if seed then for _, s in ipairs(seed) do DB.spells[#DB.spells + 1] = s end end
        end
        RebuildTracked()
        ev:RegisterEvent("PLAYER_SWING")
        ev:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        ev:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
        ev:RegisterEvent("SPELLS_CHANGED")
        -- the UI file (loaded after this one) builds its minimap button here,
        -- so it never races this handler for the DB
        if NS.OnReady then NS.OnReady() end
    end
end)

-- ── slash + shared mutators ─────────────────────────────────────────────────
-- NO CHAT PRINTS (Arc's standing rule - the old print() here broke it). Slash
-- feedback goes to the error frame, which is where the pet side already put it.
local function Msg(txt)
    if UIErrorsFrame then
        UIErrorsFrame:AddMessage("Arc Weave: " .. txt, 0.25, 0.79, 0.95)
    end
end

local function EntryLabel(entry)
    local sid = ResolveEntry(entry)
    local name = sid and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
    return (name or tostring(entry)) .. (sid and (" (" .. sid .. ")") or " (unresolved)")
end

-- ONE path for every edit, whether it came from a slash command or a click.
local function SetEnabled(v)
    if not DB then return end
    DB.enabled = v and true or false
    if not DB.enabled then HideMarks() end
    -- one place repaints the minimap icon, whoever flipped the switch
    if NS.PaintMinimap then NS.PaintMinimap() end
end

local function AddSpell(text)
    if not DB or not text or text == "" then return false end
    DB.spells[#DB.spells + 1] = tonumber(text) or text
    RebuildTracked()
    return true
end

local function RemoveAt(i)
    if not DB or not DB.spells or not DB.spells[i] then return false end
    local entry = table.remove(DB.spells, i)
    if DB.queueBarColors then DB.queueBarColors[tostring(entry)] = nil end
    RebuildTracked()
    HideMarks()
    return true
end

-- ready/queued placement: false (default) = the tick stays where it came
-- off cooldown; true = it jumps to the end of the bar
local function SetJumpToEnd(v)
    if not DB then return end
    DB.jumpToEnd = v and true or nil
    if AnyLive() then QueueRefresh() end
end

-- the one "Ready or queued marker" choice (same three as Arc Auras), over the
-- two saved switches so every older profile reads back unchanged:
--   stay   - the tick stays where it came back (both nil, the default)
--   jump   - it jumps to the end of the bar (jumpToEnd)
--   follow - a QUEUED tick rides the swing's fill edge; a ready one stays
local function GetTickPlace()
    if DB and DB.queueFollow then return "follow" end
    if DB and DB.jumpToEnd then return "jump" end
    return "stay"
end

local function SetTickPlace(mode)
    if not DB then return end
    DB.jumpToEnd = (mode == "jump") or nil
    DB.queueFollow = (mode == "follow") or nil
    if AnyLive() then QueueRefresh() end
end

-- the off-hand bar gets the main hand's exact ticks (default off). Switching
-- it on builds the overlay at once, so a swing already in flight draws
-- without waiting for the next one.
local function SetOffHand(v)
    if not DB then return end
    DB.offHand = v and true or nil
    if DB.offHand then EnsureHost(OH) else HideLane(OH) OH.diag = nil end
    UpdatePreview()
    if LiveSwing(OH) then QueueRefresh() end
end

-- off-hand icons above its bar (like the main hand) instead of below: for
-- bars moved apart in Edit Mode. Only anchors change, so no repaint needed.
local function SetOffHandIconsAbove(v)
    if not DB then return end
    DB.ohIconsAbove = v and true or nil
    ApplyAllMarkSizing()
    UpdatePreview()
end

-- marker sizing: clamp to the slider's own range, drop the key entirely when
-- it lands back on the default (the saved file stays as small as the day it
-- was created), then push it straight onto the live markers
local function SetMarkerSize(key, v)
    local s = SIZE[key]
    if not DB or not s then return end
    v = tonumber(v)
    if not v then return end
    if v < s.min then v = s.min elseif v > s.max then v = s.max end
    -- a fractional slider lands on 0.9999... rather than 1: snap anything
    -- within half a step of the default BACK to it, so "put it back where it
    -- was" really does clear the key instead of saving a look-alike
    if math.abs(v - s.d) < s.step / 2 then v = s.d end
    DB[key] = (v ~= s.d) and v or nil
    ApplyAllMarkSizing()
    UpdatePreview()
    if AnyLive() then QueueRefresh() end
end

-- queued bar colour: the switch (default off) and its colour (nil = cyan)
local function SetQueueBarTint(v)
    if not DB then return end
    DB.queueBarTint = v and true or nil
    PaintQueueBar()
end

local function SetQueueBarColor(c)
    if not DB or type(c) ~= "table" then return end
    DB.queueBarColor = { c[1], c[2], c[3] }
    PaintQueueBar()
end

local function SetAbilityQueueColor(entry, c)
    if not DB or entry == nil or type(c) ~= "table" then return end
    DB.queueBarColors = DB.queueBarColors or {}
    DB.queueBarColors[tostring(entry)] = { c[1], c[2], c[3] }
    PaintQueueBar()
end

local function SetShowIcon(v)
    if not DB then return end
    DB.hideIcon = (not v) or nil
    ApplyAllMarkSizing()
    UpdatePreview()
    if AnyLive() then QueueRefresh() end
end

-- ── diagnostics ─────────────────────────────────────────────────────────────
-- A fresh, copyable snapshot of every input the markers read. Works standing
-- still (not only mid-swing). Secrets are NEVER printed or compared - only
-- reported as secret; a duration's numbers are shown only when the object
-- itself reports no secret values (HasSecretValues is NeverSecret).
local function Show(v)
    if v == nil then return "nil" end
    if IsSecret(v) then return "<secret>" end
    if type(v) == "number" then return string.format("%.3f", v) end
    return tostring(v)
end

function NS.Snapshot()
    local L = {}
    local function add(s) L[#L + 1] = s end
    add("== ArcNextSwing snapshot (secret-safe engine) ==")
    add(("time %s | build %s"):format(Show(GetTime()), tostring((select(2, GetBuildInfo())))))
    add(("enabled: %s | tracked entries: %d | resolved: %d"):format(
        tostring(DB and DB.enabled), DB and DB.spells and #DB.spells or -1, #tracked))
    local place = GetTickPlace()
    add(("ready/queued tick: %s"):format((place == "follow" and "queued rides the swing's fill")
        or (place == "jump" and "jumps to the end of the bar") or "stays in place (default)"))
    add(("off-hand ticks: %s"):format((DB and DB.offHand)
        and (DB.ohIconsAbove and "on, icons above the bar" or "on, icons below the bar")
        or "off (default)"))
    add(("marker size: tick %dpx wide x %.0f%% of the bar | icon %s | badge %dpt"):format(
        Opt("tickWidth"), Opt("tickHeight") * 100,
        ShowIcon() and (Opt("iconSize") .. "px") or "hidden", Opt("badgeSize")))
    add(("  icon gap %dpx above the tick | %dpx between stacked icons"):format(
        Opt("iconGap"), Opt("iconStack")))
    -- the SETTING against what the widgets actually measure. Every marker,
    -- preview or real, is sized by the one ApplyMarkSizing call, so a gap
    -- between these two lines means the setting never reached the widget;
    -- matching numbers with a wrong-looking bar means it is being drawn over.
    local nBar, nOff, nPrev, wBar, wPrev = 0, 0, 0, nil, nil
    for _, m in ipairs(marks) do
        -- `x or y` TRUTH-TESTS x, and these widths go secret the moment the
        -- ruler is fed a secret remaining time: compare against nil instead
        -- (a secret vs nil is a plain false, a truth test is not allowed)
        if m.hostFrame == MH.host then
            nBar = nBar + 1
            if wBar == nil then wBar = m.icon:GetWidth() end
        elseif m.hostFrame == OH.host then
            nOff = nOff + 1
        else
            nPrev = nPrev + 1
            if wPrev == nil then wPrev = m.icon:GetWidth() end
        end
    end
    add(("markers built: %d on the main-hand bar, %d on the off-hand bar, %d in the preview"):format(
        nBar, nOff, nPrev))
    add(("  icon width - setting %s | measured on bar %s | measured in preview %s"):format(
        Show(Opt("iconSize")), Show(wBar), Show(wPrev)))
    add("  (a secret width is EXPECTED on the bar - feeding the ruler a secret")
    add("   remaining time taints the anchor chain down to the icon)")
    local swingBar = SwingTimerMainHandFrame and SwingTimerMainHandFrame.StatusBar
    add(("  effective scale - swing bar %s | preview %s | UIParent %s"):format(
        Show(swingBar and swingBar:GetEffectiveScale()),
        Show(MH.previewBar and MH.previewBar:GetEffectiveScale()),
        Show(UIParent:GetEffectiveScale())))
    if nBar == 0 then
        add("  NOTE: no swing-bar markers exist yet - they are built on the")
        add("        first swing after a reload, so size changes made before")
        add("        that are applied when they are created, not retroactively")
    end
    add(("saved-variables load count: %s (must climb by 1 per reload)"):format(
        tostring(DB and DB.loads)))
    add(("curve API: %s | duration API: %s"):format(
        tostring(C_CurveUtil ~= nil and C_CurveUtil.CreateCurve ~= nil),
        tostring(C_Spell.GetSpellCooldownDuration ~= nil)))

    local now = GetTime()
    for _, lane in ipairs(lanes) do
        local f = _G[lane.frame]
        add(("%s - blizzard swing frame: %s"):format(lane.name, f and "present" or "MISSING"))
        if f then
            add(("  shown=%s  swingDuration=%s  swingEndTime=%s"):format(
                tostring(f:IsShown()), Show(f.swingDuration), Show(f.swingEndTime)))
        end
        local host = lane.host
        add(("  our host overlay: %s%s"):format(host and "created" or "not created",
            host and (" visible=" .. tostring(host:IsVisible())
                .. " width=" .. Show(host:GetWidth())) or ""))
        local lStart, lDur, lEnd, lSource = SwingState(lane)
        if lEnd then
            add(("  swing (%s): dur=%s elapsed=%s remaining=%s live=%s"):format(
                tostring(lSource), Show(lDur), Show(now - lStart), Show(lEnd - now),
                tostring(now < lEnd)))
        else
            add("  swing: NONE in flight (markers only draw during a swing)")
        end
    end
    local mhSpeed, ohSpeed
    if UnitAttackSpeed then mhSpeed, ohSpeed = UnitAttackSpeed("player") end
    add(("UnitAttackSpeed main hand %s | off hand %s (not used - secret in combat)"):format(
        Show(mhSpeed), Show(ohSpeed)))
    -- the per-spell projection below reads the main-hand swing
    local sStart, sDur = SwingState(MH)
    add(("combat: %s | target: %s"):format(tostring(UnitAffectingCombat("player")),
        tostring(UnitExists("target"))))

    if DB and DB.spells then
        for i, entry in ipairs(DB.spells) do
            local sid = ResolveEntry(entry)
            add(("[%d] %s -> sid %s"):format(i, tostring(entry), tostring(sid)))
            if not sid then
                add("     UNRESOLVED (name not known yet on this character)")
            else
                add(("     name=%s  queued=%s"):format(
                    tostring(C_Spell.GetSpellName and C_Spell.GetSpellName(sid)),
                    tostring(IsQueued(sid))))
                local info = C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(sid)
                if info then
                    add(("     startTime=%s duration=%s isActive=%s isOnGCD=%s"):format(
                        Show(info.startTime), Show(info.duration),
                        tostring(info.isActive), tostring(info.isOnGCD)))
                end
                local dur = C_Spell.GetSpellCooldownDuration
                    and C_Spell.GetSpellCooldownDuration(sid, true)
                if not dur then
                    add("     duration object: NONE")
                else
                    local hs = dur.HasSecretValues and dur:HasSecretValues()
                    add(("     duration object: present, HasSecretValues=%s"):format(tostring(hs)))
                    if hs == false then
                        local R = dur:GetRemainingDuration()
                        if not IsSecret(R) and type(R) == "number" then
                            add(("     remaining=%s"):format(Show(R)))
                            if sStart and sDur then
                                local phase = (now - sStart + R) / sDur
                                local k = math.floor(phase)
                                add(("     -> lands in swing +%d at %.0f%% across the bar"):format(
                                    k, (phase - k) * 100))
                            end
                        end
                    else
                        add("     remaining is SECRET - the engine picks the tick (watch the bar)")
                    end
                    if sStart and sDur then
                        local e = now - sStart
                        for k = 0, MAX_AHEAD do
                            add(("     window swing +%d: remaining in [%s, %s)"):format(
                                k, Show(k * sDur - e), Show((k + 1) * sDur - e)))
                        end
                    end
                end
            end
        end
    end
    -- cross-addon probe for ArcDisplay's item path: are ITEM cooldowns secret
    -- in this combat too? Docs say C_Container.GetItemCooldown is never
    -- secret; GetInventoryItemCooldown (trinkets) is an undocumented legacy
    -- global. Conclusive only while the probed item is actually on cooldown.
    local function ItemProbe(label, s, d, en)
        local st
        if s == nil and d == nil then
            st = "no data"
        elseif IsSecret(s) or IsSecret(d) or IsSecret(en) then
            st = "SECRET"
        elseif type(d) == "number" and d > 0 then
            st = "plain, ON cooldown (conclusive)"
        else
            st = "plain, idle (not conclusive until it is on cooldown)"
        end
        add(("  %s: %s"):format(label, st))
    end
    add("item cooldown secrecy probe (for ArcDisplay):")
    if C_Container and C_Container.GetItemCooldown then
        ItemProbe("Hearthstone, bag path", C_Container.GetItemCooldown(6948))
    end
    if GetInventoryItemCooldown then
        ItemProbe("trinket slot 13", GetInventoryItemCooldown("player", 13))
        ItemProbe("trinket slot 14", GetInventoryItemCooldown("player", 14))
    end

    for _, lane in ipairs(lanes) do
        local d = lane.diag
        if d then
            add(("last drawn pass, %s (swing source: %s):"):format(lane.name, tostring(d.source)))
            for _, sp in ipairs(d.spells) do
                add(("  %s: %s"):format(tostring(sp.name), tostring(sp.state)))
            end
        else
            add(("last drawn pass, %s: none (not swinging, switched off, or bar hidden)"):format(
                lane.name))
        end
    end
    return table.concat(L, "\n")
end

NS.MarkerColors = COL
function NS.GetDB() return DB end
function NS.Label(entry) return EntryLabel(entry) end
function NS.Resolve(entry) return ResolveEntry(entry) end
NS.SetEnabled = SetEnabled
NS.AddSpell = AddSpell
NS.RemoveAt = RemoveAt
NS.SetJumpToEnd = SetJumpToEnd
NS.SetTickPlace = SetTickPlace
function NS.GetTickPlace() return GetTickPlace() end
NS.SetOffHand = SetOffHand
NS.SetOffHandIconsAbove = SetOffHandIconsAbove
NS.SizeRange = SIZE          -- the panel reads min/max/step from here
NS.SetMarkerSize = SetMarkerSize
NS.SetShowIcon = SetShowIcon
function NS.GetMarkerSize(key) return Opt(key) end
function NS.GetShowIcon() return ShowIcon() end
NS.SetQueueBarTint = SetQueueBarTint
NS.SetQueueBarColor = SetQueueBarColor
function NS.GetQueueBarTint() return DB ~= nil and DB.queueBarTint == true end
function NS.GetQueueBarColor() return QueueBarColor() end
NS.SetAbilityQueueColor = SetAbilityQueueColor
function NS.GetAbilityQueueColor(entry) return AbilityQueueColor(entry) end

SLASH_ARCWEAVESWING1 = "/ans"
SLASH_ARCWEAVESWING2 = "/arcnextswing"
SlashCmdList.ARCWEAVESWING = function(input)
    if not DB then Msg("not initialized yet") return end
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if (cmd == "" or cmd == "config" or cmd == "options") and NS.TogglePanel then
        NS.TogglePanel()
        return
    end
    if cmd == "toggle" then
        SetEnabled(not DB.enabled)
        Msg(DB.enabled and "enabled" or "disabled")
        if NS.RefreshPanel then NS.RefreshPanel() end
    elseif cmd == "add" and rest ~= "" then
        AddSpell(rest)
        Msg("tracking " .. EntryLabel(rest))
        if NS.RefreshPanel then NS.RefreshPanel() end
    elseif cmd == "remove" and rest ~= "" then
        local want = rest:lower()
        for i = #DB.spells, 1, -1 do
            if tostring(DB.spells[i]):lower() == want then RemoveAt(i) end
        end
        Msg("removed " .. rest)
        if NS.RefreshPanel then NS.RefreshPanel() end
    elseif cmd == "debug" then
        if NS.ToggleDebug then NS.ToggleDebug() else print(NS.Snapshot()) end
    elseif cmd == "minimap" then
        DB.minimapHidden = not DB.minimapHidden or nil
        if NS.mmBtn then NS.mmBtn:SetShown(not DB.minimapHidden) end
        Msg(DB.minimapHidden and "minimap button hidden (/ans minimap to bring it back)"
            or "minimap button shown")
    elseif cmd == "list" then
        Msg((DB.enabled and "enabled" or "DISABLED") .. " - tracked on the mainhand swing bar:")
        if #DB.spells == 0 then print("   (none - /ans add Raptor Strike)") end
        for _, e in ipairs(DB.spells) do print("   - " .. EntryLabel(e)) end
        print("   /ans add <spell name or ID>  |  /ans remove <same>  |  /ans toggle")
    else
        Msg("commands: /ans (panel), add <spell>, remove <spell>, list, toggle, debug, minimap")
    end
end
