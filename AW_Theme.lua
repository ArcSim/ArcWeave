--[[===========================================================================
  ARC UI THEME -- canonical primitives for a hand-built (no-Ace) options panel.

  THIS FILE IS THE SOURCE OF TRUTH. Copy it into a new Arc addon, rename AT if
  you like, and build the panel from it. Do NOT re-derive the look from an
  existing addon's file: those drift. Fix bugs and add features HERE first, then
  carry them into the addons.

  Everything hangs off ONE table (AT). That is deliberate: a big single-file
  addon sits at Lua's 200-file-level-local ceiling, and thirty loose locals for
  the theme is enough to tip it into a hard load failure that luac -p reports as
  "too many local variables".

  A MENU, NOT A FRAMEWORK. Take only what the addon needs; nothing here is a stub.
  Minimum viable panel: CreateWindow -> NewPage -> Section -> Row* -> LayoutPage.

  FOUNDATION (always)
    AT.COL                     the palette. Never hardcode a hex.
    AT.Skin(f, bg, border)     flat fill + 1px edge, every surface
    AT.CloseDropdown()         wire to the window OnMouseDown/OnHide

  CHROME (as the addon's shape needs)
    AT.CreateWindow(name,opts) solid navy window, title bar, close, drag, resize grip
    AT.AddTabs(p,names,pages)  chip tabs on a cyan line. Skip for a single-page addon.
    AT.AddDiscordFooter(p,nm)  Discord button + copy popup. Reserve 34px at the bottom.

  CONTROLS (raw widgets, when a row builder does not fit)
    AT.MakeCheckbox(parent)    THE toggle. :SetOn(bool) :SetHover(bool)
    AT.MakeSmallButton(p,l,w)  raised navy/steel button, cyan border on hover only
    AT.MakeSwatch(p,w,h)       colour swatch, :SetColor{r,g,b}
    AT.MakeDropdown(...)       windowed-scroll select; itemsFn re-read on every open
    AT.MakeChevron(parent)     THE drawn arrow (dropdowns, tree carets). :SetDown(bool)
    AT.MakeSplitter(p, axis, cb) the drag handle between two panes: hairline + 3-dot grip,
                               cb.onStart / onDrag(delta) / onStop (v15)

  ROW ENGINE (this is what makes it look Arc)
    AT.NewPage(parent)         a page with its own rows and sections
    AT.Section(pg,text,opts)   titled bordered box. opts: visibleFn, side "L"/"R",
                               ctrlX, collapsible=true (header bar), store (remembers)
    AT.LayoutPage(pg)          flow, size boxes to VISIBLE rows, measure the control
                               column. Call after anything that shows/hides a row.
    AT.AddRow / AT.RowLabel    bare row + standard label, for custom controls
    AT.Tooltip(region,t,body)  hover tooltip. Descriptions NEVER get their own row.

  ROW BUILDERS (one line each, fully wired)
    AT.RowToggle   label + checkbox, whole row clickable, flip sound
    AT.RowInput    sunken field; `hint` shows what is in effect WITHOUT pre-filling
    AT.RowDropdown label + select
    AT.RowSlider   fill slider + [-] typed box [+]; grows with the box
    AT.RowColor    label + swatch + ColorPickerFrame
    AT.RowButton   left-aligned action button (an action, not a setting)
    AT.RowDesc     dim paragraph. Prefer a `desc` tooltip; use this only when the
                   text must always be visible.

  TWO MECHANISMS TO UNDERSTAND FIRST
    visibleFn   on any row/section: return false and it hides AND its box shrinks on
                the next LayoutPage. This is how dependent options collapse away.
    row._sync   set by the builders, called by LayoutPage every pass to re-read the DB
                into the widget. Set it on custom rows too or they go stale.

  House rules baked in: solid background, one cyan accent, boxed sections,
  raised buttons vs sunken fields, square checkbox toggles, descriptions as
  hover tooltips, no em-dashes or emoji in user-facing strings.
=============================================================================]]

local AT = {}

-- THEME VERSION. Bump this on EVERY change to this file, and never edit a copy
-- of it in another addon - copies are pushed from here by
-- E:\WoWDev\tools\arc-theme-sync\sync.lua, which reads this number to report
-- who is behind. Before this existed there was no way to answer "who has the
-- latest theme" without auditing feature by feature, and four different
-- generations had accumulated across the addons (the skill's template being
-- the OLDEST, which is how new addons kept being born stale).
--   5  2026-09-23  auto-fit window scale: a panel lands on the same share of
--                  screen height at any resolution, with a HARD per-window
--                  clamp (MAX_W/MAX_H) that no slider value can defeat.
--                  Hairline now measures device-pixels-per-unit on the frame
--                  itself. LayoutPage syncs rows BEFORE measuring the control
--                  column (the ".." blank-label bug, which was live in 8 files).
--   6  2026-09-23  default uiScale 0.85 (Arc's preferred size on a fresh
--                  install, across every Arc addon)
--   7  2026-09-23  STRUCTURE PASS. Section header actions (opts.action),
--                  AT.RowActions (grouped, edge-aligned button rows),
--                  AT.MakeQuietButton (secondary/destructive weight) and
--                  AT.RowDivider. See the ANCHORED-ACTION and GROUPED-ACTION
--                  laws: a standalone RowButton floats on the left margin with
--                  nothing to align to, and a panel full of them reads as
--                  scattered controls.
--   8  2026-09-23  SECTION BLOCKS. A hairline rule under every plain section
--                  title (spanning the section), header height up to LAY.hdr,
--                  and LAY.gap 12 -> 18. Arc, comparing against Blizzard's own
--                  options: "more structure on the sections". A 10px title
--                  with 13px of header did not read as a boundary at all.
--   9  2026-09-23  REVERSES the v7 header action. Arc: "don't put buttons on
--                  the title of the section - they look like they are part of
--                  the title". A header sits right under the PREVIOUS
--                  section's content, so a button there has ambiguous
--                  ownership. opts.action is GONE. Instead AT.RowButton now
--                  puts its button ON THE CONTROL COLUMN (and takes an
--                  optional row label), so an action lines up with every other
--                  control and stays visibly inside its section.
--  10  2026-09-23  Control-column cap measures the WIDEST control in the
--                  section instead of assuming 34px. A wide action button on
--                  a column measured from long labels ran past the section
--                  edge and SetClipsChildren cut its right side off.
--  11  2026-09-23  FIRST-PASS SIZES. An anchored frame has no real width until
--                  the client lays it out, so the first LayoutPage after a
--                  panel is built measured 0 and every width-dependent
--                  decision was skipped - a wide button stayed clipped until
--                  the window was resized BY HAND, which is how Arc found it.
--                  Now the width is derived from the page (same insets span()
--                  uses), and anything still unresolved flags a single capped
--                  re-pass on the next frame. RowDesc flags it too.
-- v12 (2026-09-23): RowSlider LIVE BOUNDS - minV / maxV may be functions,
--                  re-read on every sync, so a slider's range can follow the
--                  record (Arc: a stack threshold slider ran 0..99 on a
--                  three-stack aura, "the sliders throw me off"; it now runs
--                  2..the bar's own maximum). Fixed numbers work as before.
-- v13 (2026-09-23): AT.Tooltip DYNAMIC BODY NIL. `f() or body` handed back the
--                  FUNCTION when a body function answered nil, so a title-only
--                  tooltip fired on every region whose body said "nothing now"
--                  (Arc UI v2's rail rows). Resolved in two steps; a title
--                  function is guarded the same way.
-- v14 (2026-09-23): DROPDOWN WIDTH FROM THE LIVE LIST. MakeDropdown sized its
--                  field once at build, when a record-dependent list held
--                  only its placeholder; the field stayed too narrow until
--                  the first open re-measured it. Refresh (run on every sync)
--                  now re-sizes to the current items, so the first paint is
--                  already right.
-- v15 (2026-09-23): AT.MakeSplitter - the drag handle between two panes (a
--                  strip filling the gap, a hairline down its middle, a
--                  three-dot grip at its centre, cyan on hover / drag), with
--                  onStart / onDrag(delta) / onStop callbacks. Arc UI v2's
--                  rail width and layout-list height ride on it.
AT.VERSION = 15

AT.WHITE = "Interface\\Buttons\\WHITE8X8"
AT.DISCORD = "https://discord.gg/yMZmnFjUTd"

AT.COL = {
    bg       = { 0.043, 0.059, 0.102 },  -- window body (SOLID, never translucent)
    panel    = { 0.063, 0.094, 0.153 },  -- title bar, dropdown pullout, header bars
    well     = { 0.039, 0.067, 0.125 },  -- SUNKEN input fields and dropdowns
    line     = { 0.114, 0.165, 0.247 },  -- 1px borders and hairlines
    line2    = { 0.165, 0.231, 0.341 },  -- brighter outer window border, checkbox edge
    box      = { 0.055, 0.078, 0.130 },  -- section container fill, a step above bg
    ink      = { 0.950, 0.970, 1.000 },  -- near-white primary text
    dim      = { 0.700, 0.780, 0.880 },  -- secondary text, hints, unselected tabs
    faint    = { 0.550, 0.650, 0.780 },  -- placeholder text, off-state knob
    arc      = { 0.247, 0.788, 0.949 },  -- ARC CYAN, the one accent (#3FC9F2)
    arcDeep  = { 0.078, 0.353, 0.451 },  -- deep teal, hover borders
    btn      = { 0.110, 0.161, 0.243 },  -- raised navy button fill
    btnHover = { 0.150, 0.205, 0.295 },  -- button fill on hover
    steel    = { 0.298, 0.400, 0.549 },  -- steel button border (cyan only on hover)
    blurple  = { 0.345, 0.396, 0.949 },  -- Discord #5865F2
}

-- Layout constants. Row heights are deliberately tight: the locked template lets
-- the row height do the breathing, not padding.
AT.LAY = {
    rowH = 24, descH = 20, hdr = 22,
    ctrl = 230,          -- fallback control column when a section does not measure
    gap  = 18,           -- between section blocks. Blizzard's options give a
                         -- heading real air above it and that is most of why
                         -- theirs scans; 12 was too tight for a titled block
                         -- to read as separate from the one before it.
    fieldW = 180,
    sliderW = 110,       -- the locked template slider: whole cluster
                         -- (slider + [-][value][+]) lands at ~190px, the
                         -- same footprint as ArcSkin's range rows
}

local COL, WHITE, LAY = AT.COL, AT.WHITE, AT.LAY

-- ONE physical pixel in a frame's effective UI units. A literal edgeSize=1
-- rounds to ZERO on one side at fractional effective scales - the "missing
-- border on the checkbox" class of bug - so every edge is sized in real
-- pixels instead.
function AT.Px(f)
    local _, physH = GetPhysicalScreenSize()
    local scale = (f and f.GetEffectiveScale and f:GetEffectiveScale())
        or (UIParent:GetEffectiveScale()) or 1
    if not physH or physH <= 0 or scale <= 0 then return 1 end
    return (768 / physH) / scale
end

-- THE HAIRLINE LAW (2026-09-22, Panel scale 1.6 lost the left edge of every
-- checkbox on the Visibility tab): at a pixel-perfect scale (one unit = a
-- whole number of device pixels) a hairline is exactly ONE device pixel; at
-- a fractional Panel scale every control sits on fractional pixels, and a
-- one-pixel strip can fall between two pixel columns and vanish - so there a
-- hairline is TWO device pixels, which always owns one solid column whatever
-- the phase. Every Skin border reads this; SetUIScale re-applies it to every
-- skinned frame, so a live slider change can never strand a strip at the
-- old width either.
AT.skinned = AT.skinned or setmetatable({}, { __mode = "k" })
function AT.Hairline(f)
    local px = AT.Px(f)
    -- the TOTAL factor, not just the slider: auto-fit alone is fractional on
    -- most screens, so reading AT.uiScale here would report "integer, 1px is
    -- safe" at 1440p with the slider untouched and strand the edges again.
    -- Measured on the frame's OWN window, since each one now fits separately.
    local v = (AT.ScaleFactor and AT.ScaleFactor(f)) or (AT.uiScale or 1)
    if math.abs(v - math.floor(v + 0.5)) < 0.01 then return px end
    return px * 2
end

-- PANEL SCALE (Arc's ask: "a bigger scale might be needed on some screens").
-- The pixel-perfect law fixes a window at one-unit-equals-one-physical-pixel,
-- which on a dense display makes every panel small. This multiplies that base
-- so text AND controls grow together - the whole window, not a font size -
-- which is the only way to enlarge a pixel-scaled panel without the layout
-- coming apart. Above 1.0 a hairline is no longer exactly one device pixel:
-- AT.Hairline widens it to two, so it can never fall between pixel columns.
-- 0.85, not 1: Arc's own default across every Arc addon (2026-09-23). A fresh
-- install with nothing saved lands here, so the panels are a touch smaller than
-- the raw auto-fit target and match what he actually runs at.
AT.uiScale = 0.85
AT.windows = AT.windows or {}

-- AUTO-FIT (2026-09-23, Arc: "a bigger ratio of the screen, but the same
-- ratio on any screen people play"). The pixel-perfect law alone makes a
-- window cover designH/physH of the screen - 37% at 1440p, 25% at 4K - so
-- the better the monitor the smaller the panel, and uiScale defaulting to 1
-- meant everyone had to find the slider on every machine. This bakes the
-- screen fraction into the DEFAULT: a panel designed at REF_H units lands on
-- TARGET_H of screen height at any resolution or UI scale, and uiScale stays
-- a personal multiplier ON TOP of that.
AT.TARGET_H = 0.60        -- share of screen height a reference panel fills
AT.REF_H = 540            -- the height a "normal" Arc options panel is built at
AT.MAX_W, AT.MAX_H = 0.94, 0.92   -- it may NEVER exceed these, whatever the slider says

-- A window's height on screen is (its design height * its scale) measured in
-- UIParent units, so the scale that lands it on TARGET_H of the screen is just
-- TARGET_H * UIParent height / design height. It MUST use the window's own
-- design size: a fixed reference height (the 2026-09-23 first cut used 540)
-- scales a tall panel as though it were short, and ArcDisplay's options window
-- ran off the top and bottom of the screen.
--
-- THE CLAMP IS THE POINT. Auto-fit, a saved uiScale and a big design size all
-- multiply, so the result is capped against BOTH screen axes at the end. This
-- is a hard ceiling, applied after the slider, and it is what guarantees a
-- panel can never grow past the screen no matter what is stored.
function AT.FitScale(designW, designH)
    local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
    if not (uw and uh and uh > 0) then return AT.Px(UIParent) * (AT.uiScale or 1) end
    if not designH or designH <= 0 then return AT.Px(UIParent) * (AT.uiScale or 1) end
    -- Measured against max(this window, the reference panel). A window BIGGER
    -- than the reference shrinks to hit the target instead of overflowing
    -- (Arc's options panel is ~900 units tall and a shared factor ran it off
    -- the screen); a window SMALLER than it - a picker popup, a confirm box -
    -- rides the reference scale so it stays in proportion to the main panel
    -- rather than blowing a 150-unit popup up to 60% of the screen.
    local ref = designH > AT.REF_H and designH or AT.REF_H
    local s = (AT.TARGET_H * uh / ref) * (AT.uiScale or 1)
    -- floor FIRST (the old pixel-perfect size is the smallest we ever go)...
    local floor = AT.Px(UIParent)
    if s < floor then s = floor end
    -- ...then the caps, so the ceiling is always the LAST word. Applying the
    -- floor afterwards could shove an oversized window back past the screen,
    -- which would defeat the whole point of the clamp.
    local capH = AT.MAX_H * uh / designH
    if s > capH then s = capH end
    if designW and designW > 0 then
        local capW = AT.MAX_W * uw / designW
        if s > capW then s = capW end
    end
    return s
end

-- the scale a window is CURRENTLY entitled to, from the size it was built at
function AT.ScaleFor(w)
    if not w then return AT.Px(UIParent) * (AT.uiScale or 1) end
    return AT.FitScale(w._designW, w._designH)
end

-- the TOTAL multiplier on the pixel-perfect base. Everything that cares about
-- whether units land on whole pixels must read THIS, not AT.uiScale: auto-fit
-- is fractional on most screens (1.6 at 1440p) even with the slider at 1.
-- DEVICE PIXELS PER UNIT of a frame. Whole number = that frame's units land on
-- pixel boundaries and a one-pixel hairline is safe; fractional = it can fall
-- between columns and needs two. Works for a window OR any skinned child,
-- which the old "is AT.uiScale an integer?" test could not do - and that test
-- also went blind the moment auto-fit made the real factor fractional with the
-- slider still sitting at 1.
function AT.ScaleFactor(f)
    local _, physH = GetPhysicalScreenSize()
    if not physH or physH <= 0 then return AT.uiScale or 1 end
    local s = (f and f.GetEffectiveScale and f:GetEffectiveScale())
        or (UIParent and UIParent:GetEffectiveScale()) or 1
    return s * (physH / 768)
end

-- kept for call sites that have no window in hand (a default-sized panel)
function AT.WinScale()
    return AT.FitScale(460, 540)
end

function AT.SetUIScale(v)
    v = tonumber(v) or 1
    if v < 0.7 then v = 0.7 elseif v > 2 then v = 2 end
    AT.uiScale = v
    for _, w in ipairs(AT.windows) do
        if w and w.SetScale then
            -- PER WINDOW: each one's scale comes from its OWN design size and
            -- carries its own clamp, so a tall panel and a small popup can
            -- never share one number (that is what overflowed the screen).
            local target = AT.ScaleFor(w)
            -- ANCHOR-DRIFT COMPENSATION. A SetPoint offset is expressed in the
            -- frame's OWN scaled space, so screen position = offset * scale:
            -- rescaling alone slides the window toward or away from its anchor
            -- corner. ArcUI's bars hit this and sidestepped it by scaling SIZE
            -- instead ("SetScale causes anchor-based drift"); ProcTracker fixes
            -- it properly by re-offsetting through the scale ratio, which is
            -- what this does, so the window stays exactly where it looks.
            local old = w:GetScale() or 1
            local ratio = (target > 0) and (old / target) or 1
            local pt, rel, relPt, x, y = w:GetPoint()
            w:SetScale(target)
            if pt and x and y and ratio ~= 1 then
                w:ClearAllPoints()
                w:SetPoint(pt, rel or UIParent, relPt or pt, x * ratio, y * ratio)
            end
            if w:IsShown() then AT.SnapWindow(w) end
        end
    end
    -- the hairline law: strips were sized in the OLD unit space - re-size
    -- every skinned frame for the new scale (once per change, never per frame)
    for f in pairs(AT.skinned) do
        local e = f._atEdges
        if e then
            local px = AT.Hairline(f)
            e.top:SetHeight(px)
            e.bottom:SetHeight(px)
            e.left:SetWidth(px)
            e.right:SetWidth(px)
        end
    end
end

-- The single most reused primitive: flat fill + 1px edge. The edge is FOUR
-- pixel-snapped color-texture strips, NOT a backdrop edge: backdrop edges
-- drop a side whenever the frame rests at a fractional pixel position (the
-- trembling-borders / missing-pill-top report), while plain textures ride
-- the client's texel snapping and stay whole at any position. The frame's
-- SetBackdropBorderColor is rerouted to recolor the strips, so every
-- existing call site (hover states, focus rings) keeps working unchanged.
local EDGE_KEYS = { "top", "bottom", "left", "right" }
function AT.Skin(f, bg, borderCol)
    if not f._atEdges then
        f:SetBackdrop({ bgFile = WHITE })
        local e = {}
        for _, k in ipairs(EDGE_KEYS) do
            local t = f:CreateTexture(nil, "BORDER")
            t:SetColorTexture(1, 1, 1, 1)
            -- DEFAULT texel sampling on purpose (the ArcUI-proven config):
            -- grid-snapping a strip that is exactly one physical pixel tall
            -- can COLLAPSE it to zero rows at certain fractional positions
            -- (both edges round to the same pixel). With default sampling a
            -- hairline at a fractional spot renders slightly soft instead -
            -- dimmer at worst, never absent.
            e[k] = t
        end
        e.top:SetPoint("TOPLEFT", 0, 0)
        e.top:SetPoint("TOPRIGHT", 0, 0)
        e.bottom:SetPoint("BOTTOMLEFT", 0, 0)
        e.bottom:SetPoint("BOTTOMRIGHT", 0, 0)
        e.left:SetPoint("TOPLEFT", 0, 0)
        e.left:SetPoint("BOTTOMLEFT", 0, 0)
        e.right:SetPoint("TOPRIGHT", 0, 0)
        e.right:SetPoint("BOTTOMRIGHT", 0, 0)
        f._atEdges = e
        f.SetBackdropBorderColor = function(self, r, g, b, a)
            for _, t in pairs(self._atEdges) do
                t:SetVertexColor(r, g, b, a or 1)
            end
        end
    end
    AT.skinned[f] = true
    local px = AT.Hairline(f)
    f._atEdges.top:SetHeight(px)
    f._atEdges.bottom:SetHeight(px)
    f._atEdges.left:SetWidth(px)
    f._atEdges.right:SetWidth(px)
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    local b = borderCol or COL.line
    f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
end

-- pin a window's rect to the physical pixel grid: everything inside then
-- inherits an aligned origin, which is what keeps hairlines whole at rest
function AT.SnapWindow(p)
    local px = AT.Px(p)
    local l, t = p:GetLeft(), p:GetTop()
    if not (l and t) or px <= 0 then return end
    local function S(v) return math.floor(v / px + 0.5) * px end
    local w, h = p:GetWidth(), p:GetHeight()
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", S(l), S(t))
    p:SetSize(S(w), S(h))
end
local Skin = AT.Skin

-- one dropdown pullout open at a time, panel-wide
AT.openDropdown = nil
function AT.CloseDropdown()
    if AT.openDropdown then AT.openDropdown:Hide(); AT.openDropdown = nil end
end

--[[ CONTROLS ================================================================]]

-- THE canonical toggle: a WoW-style square checkbox. The box is CONSTANT (it
-- never recolours); only the mark toggles. checkmark-minimal renders GREEN, so
-- desaturate BEFORE tinting or it stays green. The 20px mark in an 18px box
-- overhangs slightly, exactly like Blizzard's.
function AT.MakeCheckbox(parent)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    c:SetSize(18, 18); Skin(c, COL.well, COL.line2)
    c.check = c:CreateTexture(nil, "OVERLAY")
    c.check:SetAtlas("checkmark-minimal")
    c.check:SetDesaturated(true)
    c.check:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    c.check:SetSize(20, 20); c.check:SetPoint("CENTER"); c.check:Hide()
    c.glow = c:CreateTexture(nil, "ARTWORK")
    c.glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    c.glow:SetBlendMode("ADD")
    c.glow:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.55)
    c.glow:SetPoint("TOPLEFT", -3, 3); c.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    c.glow:Hide()
    function c:SetHover(on) self.glow:SetShown(on and true or false) end
    function c:SetOn(on) self.check:SetShown(on and true or false) end
    return c
end

-- Raised action button: navy fill + STEEL border (never a cyan resting border),
-- cyan only on hover. Reads as raised against the sunken well fields.
function AT.MakeSmallButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 92, 22); Skin(b, COL.btn, COL.steel)
    local bevel = b:CreateTexture(nil, "ARTWORK")
    bevel:SetTexture(WHITE); bevel:SetVertexColor(1, 1, 1, 0.06)
    bevel:SetPoint("TOPLEFT", 1, -1); bevel:SetPoint("TOPRIGHT", -1, -1); bevel:SetHeight(1)
    b.fs = b:CreateFontString(nil, "OVERLAY")
    b.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    b.fs:SetPoint("CENTER")
    b.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    b.fs:SetText(label or "")
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(COL.btnHover[1], COL.btnHover[2], COL.btnHover[3], 1)
        b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropColor(COL.btn[1], COL.btn[2], COL.btn[3], 1)
        b:SetBackdropBorderColor(COL.steel[1], COL.steel[2], COL.steel[3], 1)
    end)
    return b
end

-- QUIET VARIANT. A destructive or secondary action ("Clear all", "Remove all")
-- rendered at full button weight competes with the primary action next to it
-- and the panel reads as a pile of equal buttons. This keeps the same
-- geometry - so a row of mixed buttons still lines up - and only drops the
-- fill and text down a step, lifting to the normal treatment on hover.
function AT.MakeQuietButton(parent, label, w)
    local b = AT.MakeSmallButton(parent, label, w)
    b:SetBackdropColor(0, 0, 0, 0)
    b:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
    b.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(COL.btnHover[1], COL.btnHover[2], COL.btnHover[3], 1)
        b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        b.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropColor(0, 0, 0, 0)
        b:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
        b.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    end)
    return b
end

function AT.MakeSwatch(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 24, h or 14); Skin(b, COL.well)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetTexture(WHITE)
    b.tex:SetPoint("TOPLEFT", 1, -1); b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    function b:SetColor(c) self.tex:SetVertexColor(c[1], c[2], c[3], 1) end
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    return b
end

-- THE Arc chevron: two rotated 1.5px bars (same as ArcSkin) - never a text
-- "v" / ">" glyph. One painter for the dropdown arrow AND every tree caret:
-- :SetDown(true) points down (dropdown, open branch), false points right
-- (shut branch). :SetDir("up"|"down"|"left"|"right") points any of the four
-- ways (the on-screen group grow arrows need up and left). :SetColor(c)
-- tints both bars. Mouse-transparent.
function AT.MakeChevron(parent)
    local arrow = CreateFrame("Frame", nil, parent)
    arrow:SetSize(12, 12)
    local a1 = arrow:CreateTexture(nil, "OVERLAY")
    a1:SetTexture(WHITE); a1:SetSize(7, 1.5)
    local a2 = arrow:CreateTexture(nil, "OVERLAY")
    a2:SetTexture(WHITE); a2:SetSize(7, 1.5)
    function arrow:SetDown(down)
        a1:ClearAllPoints(); a2:ClearAllPoints()
        if down then
            a1:SetPoint("CENTER", -2, 0.5); a1:SetRotation(math.rad(-50))
            a2:SetPoint("CENTER", 2, 0.5); a2:SetRotation(math.rad(50))
        else
            -- the same shape turned a quarter: tip on the right
            a1:SetPoint("CENTER", -0.5, 2); a1:SetRotation(math.rad(-40))
            a2:SetPoint("CENTER", -0.5, -2); a2:SetRotation(math.rad(40))
        end
    end
    -- the two missing directions are the mirror images of SetDown's pair
    function arrow:SetDir(dir)
        if dir == "down" or dir == "right" then
            arrow:SetDown(dir == "down")
            return
        end
        a1:ClearAllPoints(); a2:ClearAllPoints()
        if dir == "up" then
            a1:SetPoint("CENTER", -2, -0.5); a1:SetRotation(math.rad(50))
            a2:SetPoint("CENTER", 2, -0.5); a2:SetRotation(math.rad(-50))
        else
            -- "left": tip on the left
            a1:SetPoint("CENTER", 0.5, 2); a1:SetRotation(math.rad(40))
            a2:SetPoint("CENTER", 0.5, -2); a2:SetRotation(math.rad(-40))
        end
    end
    function arrow:SetColor(c)
        a1:SetVertexColor(c[1], c[2], c[3], 1)
        a2:SetVertexColor(c[1], c[2], c[3], 1)
    end
    arrow:SetDown(true); arrow:SetColor(COL.arc)
    return arrow
end

-- Windowed-scroll dropdown. itemsFn() -> { {value=,text=}, ... }, re-read on every
-- open so live lists stay current. Opens scrolled to the current value.
-- SPLITTER (v15, Arc UI v2, Arc: "the side one needs to be bigger and
-- needs a line so it reads as draggable"): the drag handle between two
-- panes, drawn the way every desktop app draws one - a strip filling the
-- gap, a hairline down its middle and a three-dot grip at its centre;
-- hairline + dots go cyan on hover and while dragging. axis = "x" (a
-- vertical bar dragged left / right, 12 wide) or "y" (a horizontal bar
-- dragged up / down, 12 tall). The caller anchors it and reacts through
-- cb.onStart() on press, cb.onDrag(delta) whenever the cursor moved (delta
-- in the strip's own units from the press point; right / up positive) and
-- cb.onStop() on release. The hairline follows AT.Hairline on every show.
function AT.MakeSplitter(parent, axis, cb)
    cb = cb or {}
    local s = CreateFrame("Frame", nil, parent)
    s:EnableMouse(true)
    if axis == "x" then s:SetWidth(12) else s:SetHeight(12) end
    s.line = s:CreateTexture(nil, "ARTWORK")
    s.dots = {}
    for i = -1, 1 do
        local d = s:CreateTexture(nil, "OVERLAY")
        d:SetSize(3, 3)
        if axis == "x" then d:SetPoint("CENTER", 0, i * 6)
        else d:SetPoint("CENTER", i * 6, 0) end
        s.dots[#s.dots + 1] = d
    end
    local function place()
        local px = AT.Hairline(s)
        s.line:ClearAllPoints()
        if axis == "x" then
            s.line:SetPoint("TOP", 0, 0); s.line:SetPoint("BOTTOM", 0, 0); s.line:SetWidth(px)
        else
            s.line:SetPoint("LEFT", 0, 0); s.line:SetPoint("RIGHT", 0, 0); s.line:SetHeight(px)
        end
    end
    local function paint(hot)
        local l = hot and COL.arc or COL.line
        s.line:SetColorTexture(l[1], l[2], l[3], 1)
        local c = hot and COL.arc or COL.faint
        for _, d in ipairs(s.dots) do d:SetColorTexture(c[1], c[2], c[3], hot and 1 or 0.85) end
    end
    place()
    paint(false)
    s:SetScript("OnShow", place)
    s:SetScript("OnEnter", function() paint(true) end)
    s:SetScript("OnLeave", function() if not s._drag then paint(false) end end)
    s:SetScript("OnMouseDown", function()
        s._drag = true
        paint(true)
        local x0, y0 = GetCursorPosition()
        local sc = s:GetEffectiveScale()
        if cb.onStart then cb.onStart() end
        s:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local d = ((axis == "x") and (x - x0) or (y - y0)) / sc
            if d ~= s._last then
                s._last = d
                if cb.onDrag then cb.onDrag(d) end
            end
        end)
    end)
    s:SetScript("OnMouseUp", function()
        s._drag, s._last = nil, nil
        s:SetScript("OnUpdate", nil)
        paint(false)
        if cb.onStop then cb.onStop() end
    end)
    return s
end

function AT.MakeDropdown(owner, parent, w, itemsFn, get, set, onSelect)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or LAY.fieldW, 20); Skin(b, COL.well)
    local vf = b:CreateFontString(nil, "OVERLAY")
    vf:SetFont(STANDARD_TEXT_FONT, 11, "")
    vf:SetPoint("LEFT", 8, 0); vf:SetPoint("RIGHT", -18, 0); vf:SetJustifyH("LEFT")
    -- a 20px-tall field is ONE line: bounded LEFT+RIGHT text WRAPS by
    -- default, and a wrapped option name spills out over the box
    vf:SetWordWrap(false)
    vf:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    -- drawn chevron (AT.MakeChevron) - never a text "v" glyph
    local arrow = AT.MakeChevron(b)
    arrow:SetPoint("RIGHT", -5, 0)
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)

    -- Auto width (w == nil): the field is exactly as long as the LONGEST
    -- option name plus insets (8 text + 18 chevron), floored at 80 and
    -- capped at 300 so a runaway name cannot eat the row. The pullout below
    -- always copies the field width, so the two stay edge to edge. An
    -- explicit w is honored untouched (hand-tuned call sites).
    local function SizeToItems(items)
        if w then return end
        local fs = AT._measureFS
        if not fs then
            fs = UIParent:CreateFontString(nil, "ARTWORK")
            fs:SetFont(STANDARD_TEXT_FONT, 11, ""); fs:Hide()
            AT._measureFS = fs
        end
        local widest = 0
        for _, it in ipairs(items or itemsFn() or {}) do
            fs:SetText(it.text or "")
            local tw = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
                or fs:GetStringWidth() or 0
            if tw > widest then widest = tw end
        end
        -- the insets eat exactly 26 (8 text + 18 chevron), so rounding
        -- DOWN left the text sitting on the bound - round up and keep a
        -- few pixels of slack so it can never touch it
        local want = math.ceil(widest) + 30
        if want < 80 then want = 80 end
        if want > 300 then want = 300 end
        b:SetWidth(want)
    end

    -- Refresh re-reads the value AND re-sizes to the CURRENT items. A list
    -- that depends on the selected record is a lone placeholder at build
    -- time, and a field sized only then stayed too narrow until the first
    -- open re-measured it (v14, Arc: "not big enough to fit the biggest
    -- text, yet fixed as soon as I open it"). LayoutPage calls Refresh on
    -- every sync through row._sync, so the width follows the live list.
    function b.Refresh()
        local cur = get()
        local items = itemsFn() or {}
        SizeToItems(items)
        for _, it in ipairs(items) do
            if it.value == cur then vf:SetText(it.text) return end
        end
        vf:SetText(cur ~= nil and tostring(cur) or "")
    end
    b.Refresh()

    b:SetScript("OnClick", function()
        if AT.openDropdown and AT.openDropdown._owner == b then AT.CloseDropdown() return end
        AT.CloseDropdown()
        local items = itemsFn() or {}
        SizeToItems(items)
        local vis = math.min(#items, 12)
        local list = CreateFrame("Frame", nil, owner, "BackdropTemplate")
        list:SetFrameLevel(owner:GetFrameLevel() + 30)
        list:SetWidth(b:GetWidth()); list:SetHeight(vis * 20 + 2)
        Skin(list, COL.panel, COL.arcDeep)
        list:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -1)
        list._owner = b
        list:EnableMouse(true); list:EnableMouseWheel(true)
        local off, maxOff = 0, math.max(0, #items - vis)
        for i, it in ipairs(items) do
            if it.value == get() then off = math.min(maxOff, math.max(0, i - 1)) end
        end
        local rows = {}
        for i = 1, vis do
            local ib = CreateFrame("Button", nil, list)
            ib:SetHeight(20)
            ib:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 20)
            ib:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 20)
            ib:SetHighlightTexture(WHITE)
            ib:GetHighlightTexture():SetVertexColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 0.5)
            ib.t = ib:CreateFontString(nil, "OVERLAY")
            ib.t:SetFont(STANDARD_TEXT_FONT, 11, "")
            ib.t:SetPoint("LEFT", 8, 0); ib.t:SetPoint("RIGHT", -6, 0); ib.t:SetJustifyH("LEFT")
            ib.t:SetWordWrap(false)
            rows[i] = ib
        end
        local function draw()
            for i = 1, vis do
                local it, ib = items[i + off], rows[i]
                if it then
                    ib.t:SetText(it.text)
                    if it.value == get() then ib.t:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
                    else ib.t:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]) end
                    ib:SetScript("OnClick", function()
                        set(it.value); b.Refresh(); AT.CloseDropdown()
                        if onSelect then onSelect(it.value) end
                    end)
                    ib:Show()
                else ib:Hide() end
            end
        end
        list:SetScript("OnMouseWheel", function(_, d)
            off = math.min(maxOff, math.max(0, off - d * 3)); draw()
        end)
        draw()
        AT.openDropdown = list
    end)
    return b
end

--[[ WINDOW CHROME ===========================================================]]

-- Solid navy window, panel title bar ("Word1" cyan + rest light), boxed close,
-- draggable, resizable. minW/minH matter: these pages do not scroll, they CLIP.
-- Arc scroll region (canonized from Arc Pings): plain ScrollFrame, slim
-- 4px well-colored track on the right edge, proportional CYAN thumb that
-- only shows when there is overflow, mouse-wheel driven. Never use
-- UIPanelScrollFrameTemplate (stone buttons) in an Arc panel.
-- Returns host, content. Size the CONTENT's height after laying out its
-- children, then call host:UpdateScroll(). Pass an existing region (e.g.
-- a multiline EditBox) as `child` to scroll it instead of a new frame.
function AT.MakeScroll(parent, child)
    local host = CreateFrame("ScrollFrame", nil, parent)
    local content = child or CreateFrame("Frame", nil, host)
    if not child then content:SetSize(1, 1) end
    host:SetScrollChild(content)
    local track = CreateFrame("Frame", nil, host, "BackdropTemplate")
    track:SetWidth(5)
    track:SetPoint("TOPRIGHT", host, "TOPRIGHT", 2, 0)
    track:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 2, 0)
    Skin(track, COL.well, COL.well)
    local thumb = track:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(WHITE)
    thumb:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.8)
    thumb:SetPoint("TOPLEFT", 0, 0)
    thumb:SetPoint("TOPRIGHT", 0, 0)
    track:Hide()
    function host:UpdateScroll()
        local viewH = host:GetHeight() or 0
        local contentH = content:GetHeight() or 0
        local over = contentH - viewH
        if over <= 1 or viewH <= 0 then
            host:SetVerticalScroll(0)
            track:Hide()
            return
        end
        track:Show()
        local cur = math.min(host:GetVerticalScroll() or 0, over)
        if cur < 0 then cur = 0 end
        host:SetVerticalScroll(cur)
        local thumbH = math.max(20, viewH * (viewH / contentH))
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", 0, -(viewH - thumbH) * (cur / over))
        thumb:SetPoint("TOPRIGHT", 0, -(viewH - thumbH) * (cur / over))
    end
    host:EnableMouseWheel(true)
    host:SetScript("OnMouseWheel", function(_, delta)
        local viewH = host:GetHeight() or 0
        local over = ((content:GetHeight() or 0)) - viewH
        if over <= 0 then return end
        local cur = (host:GetVerticalScroll() or 0) - delta * 32
        if cur < 0 then cur = 0 elseif cur > over then cur = over end
        host:SetVerticalScroll(cur)
        host:UpdateScroll()
        AT.CloseDropdown()
    end)
    host:SetScript("OnSizeChanged", function() host:UpdateScroll() end)
    return host, content
end

function AT.CreateWindow(globalName, opts)
    opts = opts or {}
    local minW, minH = opts.minW or 400, opts.minH or 480
    local p = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    p:SetSize(math.max(minW, opts.w or 460), math.max(minH, opts.h or 540))
    p:SetPoint("CENTER", 0, 40)
    -- PIXEL-PERFECT SCALE (the ElvUI strategy - the structural hairline
    -- fix): scale the window so ONE unit inside it equals ONE physical
    -- pixel. A 1px line then always occupies exactly one pixel row, at any
    -- position and any panel size - it cannot vanish, tremble, or soften.
    -- SnapWindow keeps the origin on the grid; inside, integer math IS
    -- pixel math. Re-applied when the resolution or UI scale changes.
    -- the size this window was DESIGNED at drives its own fit and its own
    -- clamp; without it every window would be scaled as if it were 460x540
    p._designW = math.max(minW, opts.w or 460)
    p._designH = math.max(minH, opts.h or 540)
    p:SetScale(AT.ScaleFor(p))
    AT.windows[#AT.windows + 1] = p
    p:RegisterEvent("UI_SCALE_CHANGED")
    p:RegisterEvent("DISPLAY_SIZE_CHANGED")
    p:SetScript("OnEvent", function(self)
        -- the screen itself changed, so the clamp has to be recomputed
        self:SetScale(AT.ScaleFor(self))
        if self:IsShown() then AT.SnapWindow(self) end
    end)
    p:SetFrameStrata("DIALOG"); p:SetToplevel(true); p:SetClampedToScreen(true)
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        AT.SnapWindow(self)
    end)
    p:SetScript("OnMouseDown", AT.CloseDropdown)
    p:SetScript("OnHide", AT.CloseDropdown)
    p:SetScript("OnShow", function(self) AT.SnapWindow(self) end)
    Skin(p, COL.bg, COL.line2)
    if globalName then tinsert(UISpecialFrames, globalName) end

    local bar = CreateFrame("Frame", nil, p, "BackdropTemplate")
    bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("TOPRIGHT", -1, -1); bar:SetHeight(30)
    Skin(bar, COL.panel)
    local t1 = bar:CreateFontString(nil, "OVERLAY")
    t1:SetFont(STANDARD_TEXT_FONT, 14, ""); t1:SetPoint("LEFT", 12, 0)
    t1:SetText(opts.title or "|cff3fc9f2Arc|r|cffd5e2f2 Addon|r")
    if opts.version then
        local ver = bar:CreateFontString(nil, "OVERLAY")
        ver:SetFont(STANDARD_TEXT_FONT, 10, "")
        ver:SetPoint("LEFT", t1, "RIGHT", 8, -1)
        ver:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        ver:SetText(opts.version)
    end
    local close = CreateFrame("Button", nil, bar, "BackdropTemplate")
    close:SetSize(18, 18); close:SetPoint("RIGHT", -6, 0); Skin(close, COL.well, COL.line2)
    local cx = close:CreateFontString(nil, "OVERLAY")
    cx:SetFont(STANDARD_TEXT_FONT, 12, ""); cx:SetPoint("CENTER", 0, 0); cx:SetText("x")
    cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    close:SetScript("OnEnter", function()
        cx:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
        close:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    end)
    close:SetScript("OnLeave", function()
        cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        close:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
    end)
    close:SetScript("OnClick", function() p:Hide() end)
    p.titleBar, p.titleText = bar, t1

    if opts.resizable ~= false then
        p:SetResizable(true)
        if p.SetResizeBounds then p:SetResizeBounds(minW, minH, opts.maxW or 900, opts.maxH or 1000) end
        local grip = CreateFrame("Button", nil, p)
        grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2); grip:EnableMouse(true)
        local gt = grip:CreateTexture(nil, "OVERLAY")
        gt:SetAllPoints(); gt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        gt:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.8)
        grip:SetScript("OnEnter", function() gt:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1) end)
        grip:SetScript("OnLeave", function() gt:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.8) end)
        local sizing
        grip:SetScript("OnMouseDown", function()
            AT.CloseDropdown()
            -- PIN THE TOP-LEFT FIRST. A CENTER-anchored frame grows symmetrically,
            -- so sizing from the corner lurches the whole window.
            local l, t = p:GetLeft(), p:GetTop()
            if l and t then
                p:ClearAllPoints()
                p:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
            end
            -- MANUAL SIZING, never StartSizing: on a pixel-scaled window
            -- (SetScale(AT.Px)) the client can compute StartSizing's grab
            -- offset in the wrong coordinate space and the frame BALLOONS
            -- the moment the drag begins. Cursor deltas divided by the
            -- window's own effective scale are exact in any scale.
            local cx, cy = GetCursorPosition()
            sizing = { w = p:GetWidth(), h = p:GetHeight(), x = cx, y = cy }
            local maxW, maxH = opts.maxW or 900, opts.maxH or 1000
            grip:SetScript("OnUpdate", function()
                if not sizing then return end
                local nx, ny = GetCursorPosition()
                local es = p:GetEffectiveScale()
                if not es or es <= 0 then return end
                local w = sizing.w + (nx - sizing.x) / es
                local h = sizing.h - (ny - sizing.y) / es
                if w < minW then w = minW elseif w > maxW then w = maxW end
                if h < minH then h = minH elseif h > maxH then h = maxH end
                p:SetSize(w, h)
            end)
        end)
        grip:SetScript("OnMouseUp", function()
            grip:SetScript("OnUpdate", nil)
            sizing = nil
            AT.SnapWindow(p)
            if opts.onResize then opts.onResize(p:GetWidth(), p:GetHeight()) end
            if p.RefreshActive then p:RefreshActive() end
        end)
    end
    -- Frames spawn SHOWN. A toggle-style opener (if IsShown then Hide) sees
    -- the brand-new window as open and immediately closes it, costing the
    -- user a second slash command (the Arc Bonus Roll two-/abr bug). A
    -- window is created closed; the caller shows it.
    p:Hide()
    return p
end

-- Chip tabs sitting on a CONTINUOUS cyan line. tabs = { "General", "Alerts" }.
-- Returns a select(name) function; pages are created by the caller via NewPage.
function AT.AddTabs(p, tabs, pages, y)
    y = y or -34
    p._tabs = {}
    local x = 10
    local function repaint(active)
        for name, d in pairs(p._tabs) do
            local sel = (name == active)
            pages[name]:SetShown(sel)
            if sel then
                Skin(d.chip, COL.panel, COL.arc)
                d.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
                if pages[name].Refresh then pages[name]:Refresh() end
            else
                Skin(d.chip, COL.well, COL.line)
                d.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end
        p._activeTab = active
    end
    local function select(name) repaint(name) end
    for _, name in ipairs(tabs) do
        local tb = CreateFrame("Button", nil, p, "BackdropTemplate")
        tb:SetHeight(24)
        local fs = tb:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 12, ""); fs:SetPoint("CENTER"); fs:SetText(name)
        tb:SetWidth(math.max(70, (fs:GetStringWidth() or 40) + 22))
        tb:SetPoint("TOPLEFT", x, y); x = x + tb:GetWidth() + 3
        tb:SetScript("OnClick", function() AT.CloseDropdown(); select(name) end)
        tb:SetScript("OnEnter", function()
            if p._activeTab ~= name then
                tb:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
                fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            end
        end)
        tb:SetScript("OnLeave", function()
            if p._activeTab ~= name then
                tb:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
                fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end)
        p._tabs[name] = { chip = tb, fs = fs }
    end
    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    line:SetPoint("TOPLEFT", 10, y - 25); line:SetPoint("TOPRIGHT", -10, y - 25)
    line:SetHeight(1)
    p.SelectTab = select
    function p:RefreshActive()
        if self._activeTab and pages[self._activeTab] and pages[self._activeTab].Refresh then
            pages[self._activeTab]:Refresh()
        end
    end
    return select
end

--[[ ROW ENGINE ==============================================================]]

function AT.NewPage(parent)
    local pg = CreateFrame("Frame", nil, parent)
    -- ONE page = ONE panel (the ArcSkin win.page law): a flat panel-colored
    -- body that section boxes nest inside - never floating boxes on bare
    -- window background
    pg._bg = pg:CreateTexture(nil, "BACKGROUND", nil, -8)
    pg._bg:SetTexture(WHITE)
    pg._bg:SetVertexColor(COL.panel[1], COL.panel[2], COL.panel[3], 1)
    pg._bg:SetAllPoints()
    pg._rows, pg._sections, pg._curSection = {}, {}, nil
    function pg:Refresh() AT.LayoutPage(self) end
    pg:Hide()
    return pg
end

function AT.AddRow(pg, h, visibleFn)
    local sec = pg._curSection
    local row = CreateFrame("Frame", nil, (sec and sec.box) or pg)
    h = h or LAY.rowH
    row:SetHeight(h); row._h = h; row._visibleFn = visibleFn
    row._ctrlX = (sec and sec.ctrlX) or LAY.ctrl
    if sec then sec.rows[#sec.rows + 1] = row else pg._rows[#pg._rows + 1] = row end
    return row
end

function AT.RowLabel(row, text)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 12, ""); fs:SetPoint("LEFT", 10, 0)
    fs:SetWordWrap(false); fs:SetJustifyH("LEFT")
    fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); fs:SetText(text)
    return fs
end

-- ── tab strip (the ArcSkin/ProcTracker painter, ported exactly) ─────────────
-- Physical chips on ONE arc-cyan attach line spanning the strip. Z-order does
-- the classic-attached-tab trick: unselected chips sit UNDER the line (+1) so
-- it covers their bottom edges, the line lives at +2, and the selected chip
-- rises ABOVE it (+3) with a window-bg fill and no bottom edge, so it notches
-- through and opens into the page below. Chips wrap to a second row when the
-- strip is too narrow (same maxW guard as ArcSkin). Set() is pool-based and
-- idempotent - call it from a _sync on every refresh. fontSize: 12 = main
-- row, 11 = sub/section rows. All edges are 1px strips, DEFAULT sampling.
function AT.TabRow(parent)
    local strip = CreateFrame("Frame", nil, parent)
    strip._tabs = {}
    strip._lineF = CreateFrame("Frame", nil, strip)
    strip._lineF:SetPoint("TOPLEFT", 0, -23)
    strip._lineF:SetPoint("TOPRIGHT", 0, -23)
    strip._lineF:SetHeight(1)
    strip._line = strip._lineF:CreateTexture(nil, "OVERLAY")
    strip._line:SetTexture(WHITE)
    strip._line:SetAllPoints()
    strip._line:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.9)
    local function Edge(t)
        local e = t:CreateTexture(nil, "OVERLAY")
        e:SetTexture(WHITE)
        return e
    end
    local function PaintIdle(tb)
        if tb._active then return end
        tb.bg:SetVertexColor(COL.well[1], COL.well[2], COL.well[3], 1)
        tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        for _, e in ipairs({ tb.eL, tb.eT, tb.eR, tb.eB }) do
            e:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 1)
            e:Show()
        end
    end
    function strip:Set(names, active, onClick, fontSize)
        self._lineF:SetFrameLevel(self:GetFrameLevel() + 2)
        -- what the selected chip "opens into": window bg by default
        -- (ArcSkin's context), the page panel when the strip lives inside a
        -- panel-bodied page (set strip._openFill = COL.panel there)
        local open = self._openFill or COL.bg
        local chipH = 24
        local x, rowY = 0, 0
        -- usable width: on the FIRST layout pass the strip (and its row)
        -- have no resolved size yet - walk up to the page, which is
        -- anchored at Build time. A wrong fallback here wrapped the chips
        -- over the content on first open.
        local maxW
        local probe = self
        for _ = 1, 4 do
            if not probe then break end
            local w = probe:GetWidth()
            if w and w > 50 then maxW = w break end
            probe = probe:GetParent()
        end
        maxW = (maxW or 500) - 4
        for i = 1, math.max(#names, #self._tabs) do
            local name, tb = names[i], self._tabs[i]
            if name and not tb then
                tb = CreateFrame("Button", nil, self)
                tb.bg = tb:CreateTexture(nil, "BACKGROUND")
                tb.bg:SetTexture(WHITE)
                tb.bg:SetAllPoints()
                tb.fs = tb:CreateFontString(nil, "OVERLAY")
                tb.fs:SetPoint("CENTER", 0, 0)
                tb.eL, tb.eT, tb.eR, tb.eB = Edge(tb), Edge(tb), Edge(tb), Edge(tb)
                tb.eL:SetPoint("TOPLEFT"); tb.eL:SetPoint("BOTTOMLEFT"); tb.eL:SetWidth(1)
                tb.eT:SetPoint("TOPLEFT"); tb.eT:SetPoint("TOPRIGHT"); tb.eT:SetHeight(1)
                tb.eR:SetPoint("TOPRIGHT"); tb.eR:SetPoint("BOTTOMRIGHT"); tb.eR:SetWidth(1)
                tb.eB:SetPoint("BOTTOMLEFT"); tb.eB:SetPoint("BOTTOMRIGHT"); tb.eB:SetHeight(1)
                self._tabs[i] = tb
            end
            if tb then
                if name then
                    tb:SetHeight(chipH)
                    tb.fs:SetFont(STANDARD_TEXT_FONT, fontSize or 12, "")
                    tb.fs:SetText(name)
                    local w = math.floor((tb.fs:GetStringWidth() or 40) + 24 + 0.5)
                    tb:SetWidth(w)
                    if x + w > maxW and x > 0 then x = 0; rowY = rowY - (chipH + 4) end
                    tb:ClearAllPoints()
                    tb:SetPoint("TOPLEFT", x, rowY)
                    x = x + w + 5
                    local on = (name == active)
                    tb._active = on
                    tb:SetFrameLevel(self:GetFrameLevel() + (on and 3 or 1))
                    if on then
                        -- open bottom: fill continuous with whatever sits
                        -- under the line, arc side/top edges
                        tb.bg:SetVertexColor(open[1], open[2], open[3], 1)
                        tb.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
                        tb.eL:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1); tb.eL:Show()
                        tb.eT:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1); tb.eT:Show()
                        tb.eR:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1); tb.eR:Show()
                        tb.eB:Hide()
                    else
                        PaintIdle(tb)
                    end
                    tb:SetScript("OnClick", function()
                        AT.CloseDropdown()
                        if onClick then onClick(name) end
                    end)
                    tb:SetScript("OnEnter", function(s)
                        if not s._active then
                            for _, e in ipairs({ s.eL, s.eT, s.eR, s.eB }) do
                                e:SetVertexColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
                            end
                            s.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
                        end
                    end)
                    tb:SetScript("OnLeave", function(s) PaintIdle(s) end)
                    tb:Show()
                else
                    tb:Hide()
                end
            end
        end
        -- pin the attach line to the LAST chip row's bottom edge (1px up,
        -- so it overlays chip bottoms exactly like ArcSkin's yOff - 1)
        local h = -rowY + chipH
        self._lineF:ClearAllPoints()
        self._lineF:SetPoint("TOPLEFT", 0, -(h - 1))
        self._lineF:SetPoint("TOPRIGHT", 0, -(h - 1))
        return h
    end
    return strip
end

function AT.Tooltip(region, title, body)
    region:HookScript("OnEnter", function(self)
        -- a dynamic body that answers nil means "no tooltip right now".
        -- Resolved in two steps on purpose: `f() or body` hands back the
        -- FUNCTION when f() is nil, and a title-only tooltip appeared on
        -- every row whose body said nil (v13, Arc UI v2 rail, 2026-09-23)
        local b = body
        if type(b) == "function" then b = b() end
        if type(b) ~= "string" or b == "" then return end
        local t = title
        if type(t) == "function" then t = t() end
        if type(t) ~= "string" then t = "" end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(t, 1, 1, 1)
        GameTooltip:AddLine(b, 0.75, 0.82, 0.92, true)
        GameTooltip:Show()
    end)
    region:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- COLLAPSIBLE SECTION. A 22px header bar the width of the box: the arrow at
-- the LEFT with the title right after it (Arc, 2026-09-22: "just like ArcUI's
-- own drop down" - v1's CollapsibleHeader puts its arrow 4px in and the text
-- 6px after it; the old arrow-pinned-RIGHT rule is retired), whole bar
-- clickable. Right = shut, down = open. Collapsed, the bar keeps a cyan
-- underline so a shut section still reads as Arc.
--   opts = { visibleFn, side = "L"/"R", ctrlX, collapsible = false, store = table }
-- `store` is any table you own; the open/shut state is saved under the title.
function AT.Section(pg, text, opts)
    opts = opts or {}
    local titled = (text ~= nil and text ~= "")
    -- SOLID PAGE law (Arc, 2026-09-16, supersedes boxed sections): the page
    -- is ONE continuous panel like WoW/WeakAuras options - sections are
    -- INVISIBLE layout containers, separated by their uppercase cyan
    -- headers and row spacing, never by cut-out boxes
    local box = CreateFrame("Frame", nil, pg, "BackdropTemplate")
    box:SetClipsChildren(true)
    local sec = {
        box = box, rows = {}, visibleFn = opts.visibleFn, side = opts.side,
        ctrlX = opts.ctrlX or LAY.ctrl, collapsed = false, f = 1, store = opts.store,
    }
    if titled and opts.collapsible then
        -- A COLLAPSIBLE SECTION IS A BOX (Arc, 2026-09-19: "when you do a drop
        -- down like this you should be making like a window of itself and the
        -- items are inside this window"). This is a deliberate carve-out from
        -- the SOLID PAGE law, which still governs every plain titled section:
        -- a thing you open and shut has to show what it contains.
        local bar = CreateFrame("Button", nil, pg, "BackdropTemplate")
        bar:SetHeight(LAY.hdr); Skin(bar, COL.panel, COL.line)
        -- THE ONE ARROW: the drawn Arc chevron, never a Blizzard atlas and
        -- never a text caret (the one-arrow law, same glyph as the rail),
        -- LEFT, with the title after it
        local arrow = AT.MakeChevron(bar)
        arrow:SetPoint("LEFT", 7, 0)
        local title = bar:CreateFontString(nil, "OVERLAY")
        title:SetFont(STANDARD_TEXT_FONT, 11, "")
        title:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
        title:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]); title:SetText(text)
        local rule = bar:CreateTexture(nil, "OVERLAY")
        rule:SetTexture(WHITE)
        rule:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        rule:SetPoint("BOTTOMLEFT", 1, 1); rule:SetPoint("BOTTOMRIGHT", -1, 1)
        rule:SetHeight(1); rule:Hide()
        -- the body is a real container while it is open
        Skin(box, COL.box, COL.line)
        sec.hit, sec.title, sec.arrow, sec.rule = bar, title, arrow, rule
        sec.boxed = true
        local function paint(hot)
            local c = hot and COL.ink or COL.arc
            title:SetTextColor(c[1], c[2], c[3])
            arrow:SetColor(c)
            local f = hot and COL.btnHover or COL.panel
            bar:SetBackdropColor(f[1], f[2], f[3], 1)
        end
        bar:SetScript("OnEnter", function() paint(true) end)
        bar:SetScript("OnLeave", function() paint(false) end)
        bar:SetScript("OnClick", function()
            AT.CloseDropdown()
            sec.collapsed = not sec.collapsed
            if sec.store then
                sec.store.secCollapsed = sec.store.secCollapsed or {}
                sec.store.secCollapsed[text] = sec.collapsed or nil
            end
            PlaySound(sec.collapsed and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
                                     or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON, "Master")
            sec.page = pg
            AT.anims = AT.anims or {}
            AT.anims[sec] = true
            if not AT.animDriver then
                AT.animDriver = CreateFrame("Frame")
                AT.animDriver:SetScript("OnUpdate", function(drv, elapsed)
                    local pages, any = {}, false
                    for s in pairs(AT.anims) do
                        local target = s.collapsed and 0 or 1
                        local f = s.f or (1 - target)
                        local step = elapsed / 0.16
                        if f < target then f = math.min(target, f + step)
                        else f = math.max(target, f - step) end
                        s.f = f
                        if f == target then AT.anims[s] = nil else any = true end
                        if s.page then pages[s.page] = true end
                    end
                    for p2 in pairs(pages) do AT.LayoutPage(p2) end
                    -- ZERO IDLE COST: the driver dies the moment nothing moves
                    if not any then drv:SetScript("OnUpdate", nil); AT.animDriver = nil end
                end)
            end
        end)
        if sec.store and (sec.store.secCollapsed or {})[text] then
            sec.collapsed, sec.f = true, 0
        end
    elseif titled then
        -- ArcSkin boxtitle law: cyan, font 10, ALWAYS uppercase
        local t = pg:CreateFontString(nil, "OVERLAY")
        t:SetFont(STANDARD_TEXT_FONT, 10, "")
        t:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
        t:SetText(string.upper(text))
        sec.title = t
        -- THE SECTION RULE (v8). A 10px uppercase title alone does not read as
        -- a boundary - the page comes out as one undifferentiated pile with
        -- controls and buttons in it. Blizzard's own options give every
        -- section a heavy heading and real whitespace, and that is the whole
        -- reason theirs scans. This is the flat Arc equivalent: a hairline
        -- under the title, spanning the section, so each block has a visible
        -- top edge. Cheap, quiet, and it does all the structural work.
        local hr = pg:CreateTexture(nil, "ARTWORK")
        hr:SetTexture(WHITE)
        hr:SetVertexColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
        sec.hr = hr
        -- NO BUTTONS ON A SECTION TITLE (Arc, 2026-09-23). v7 briefly put a
        -- section's action on its header line, right-aligned. It was wrong:
        -- a header sits directly under the PREVIOUS section's content, so a
        -- button there reads as belonging to the title, or to the block above,
        -- and Arc could not tell which section owned it. Blizzard never do it
        -- either - their buttons live in the content, under the heading.
        -- Actions go in ROWS, aligned to the control column, via AT.RowButton.
    end
    pg._sections[#pg._sections + 1] = sec
    pg._curSection = sec
    return box
end

-- ── page scrolling ──────────────────────────────────────────────────────────
-- Scrolls a page IN PLACE - no ScrollFrame, no scroll child, no re-parenting.
-- LayoutPage already flows every row and section from pg._startY, so the whole
-- mechanism is "offset _startY and clip the page". That matters because pages
-- here get re-parented and re-anchored at runtime (the icon editor moves
-- between the group and free panes); a real scroll child would have to be
-- chased around, an offset does not.
function AT.MakeScrollable(pg)
    if not pg or pg._scroll then return pg end
    pg:SetClipsChildren(true)
    pg:EnableMouseWheel(true)
    pg._scrollOff = 0
    local track = CreateFrame("Frame", nil, pg, "BackdropTemplate")
    track:SetWidth(5)
    track:SetPoint("TOPRIGHT", -1, -3)
    track:SetPoint("BOTTOMRIGHT", -1, 3)
    Skin(track, COL.well, COL.well)
    local thumb = track:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(WHITE)
    thumb:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.8)
    thumb:SetPoint("TOPLEFT", 0, 0)
    thumb:SetPoint("TOPRIGHT", 0, 0)
    track:Hide()
    local function overflow()
        local viewH = pg:GetHeight() or 0
        return math.max(0, (pg._contentH or 0) - viewH), viewH
    end
    pg._scroll = {
        track = track,
        overflow = overflow,
        paint = function()
            local over, viewH = overflow()
            if over <= 1 or viewH <= 0 then track:Hide() return end
            -- re-asserted every paint, not set once: a page that gets
            -- re-parented (the icon editor moves between panes) takes a new
            -- base level with it, and a level fixed at build time would sink
            -- under the rows
            track:SetFrameLevel(pg:GetFrameLevel() + 30)
            track:Show()
            local th = math.max(20, viewH * (viewH / (pg._contentH or viewH)))
            local travel = math.max(0, viewH - th - 6)
            local t = -travel * ((pg._scrollOff or 0) / over)
            thumb:SetHeight(th)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPLEFT", 0, t)
            thumb:SetPoint("TOPRIGHT", 0, t)
        end,
    }
    pg:SetScript("OnMouseWheel", function(_, delta)
        local over = overflow()
        if over <= 0 then return end
        local cur = (pg._scrollOff or 0) - delta * 36
        if cur < 0 then cur = 0 elseif cur > over then cur = over end
        if cur == pg._scrollOff then return end
        pg._scrollOff = cur
        AT.CloseDropdown()
        AT.LayoutPage(pg)
    end)
    return pg
end

-- Flow rows, size each box to its VISIBLE rows, and place every single-control
-- row's control on ONE column measured per section.
function AT.LayoutPage(pg)
    if not (pg and pg._sections) then return end
    if pg._scroll then
        -- clamp against the LAST measured content: the wheel handler already
        -- clamps live, so a one-pass-stale bound here only ever shows up when
        -- content shrinks under the scroll, and the next layout corrects it
        local over = pg._scroll.overflow()
        local off = pg._scrollOff or 0
        if off > over then off = over elseif off < 0 then off = 0 end
        pg._scrollOff = off
        pg._startY = -4 + off
    end
    local y = pg._startY or -4
    for _, row in ipairs(pg._rows) do
        if row._sync then row._sync() end
        if (not row._visibleFn) or row._visibleFn() then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 2, y); row:SetPoint("TOPRIGHT", -2, y)
            row:Show(); y = y - row._h
        else row:Hide() end
    end
    local pairTopY, pairBottomY
    for _, sec in ipairs(pg._sections) do
        local side = sec.side
        if sec.visibleFn and not sec.visibleFn() then
            if sec.hit then sec.hit:Hide() end
            if sec.title then sec.title:Hide() end
            if sec.hr then sec.hr:Hide() end
            sec.box:Hide()
            if side == "L" then pairTopY, pairBottomY = y, y
            elseif side == "R" then pairTopY, pairBottomY = nil, nil end
        else
            -- a section whose rows are ALL hidden paints nothing: no title,
            -- no empty box sliver, no gap (ArcSkin's anyVisible rule - the
            -- "random empty boxes" class of bug)
            local anyVis = false
            for _, r in ipairs(sec.rows) do
                if (not r._visibleFn) or r._visibleFn() then anyVis = true break end
            end
            if not anyVis then
                if sec.hit then sec.hit:Hide() end
                if sec.title then sec.title:Hide() end
                if sec.hr then sec.hr:Hide() end
                sec.box:Hide()
                if side == "L" then pairTopY, pairBottomY = y, y
                elseif side == "R" then pairTopY, pairBottomY = nil, nil end
            else
            local topY = (side == "R" and pairTopY) or y
            local hdrH = 0
            local function span(f, top)
                f:ClearAllPoints()
                if side == "L" then
                    f:SetPoint("TOPLEFT", 6, top); f:SetPoint("TOPRIGHT", pg, "TOP", -6, top)
                elseif side == "R" then
                    f:SetPoint("TOPLEFT", pg, "TOP", 6, top); f:SetPoint("TOPRIGHT", -6, top)
                else
                    f:SetPoint("TOPLEFT", 6, top); f:SetPoint("TOPRIGHT", -6, top)
                end
            end
            if sec.hit then
                span(sec.hit, topY); sec.hit:Show(); hdrH = LAY.hdr
                -- THE TITLE COMES BACK WITH ITS BAR (Arc, 2026-09-22: headers
                -- with no names). A hidden section hides sec.title as well as
                -- the bar, and this branch used to re-show only the bar, so a
                -- collapsible section lost its name for good after the first
                -- pass it spent hidden - i.e. after any tab switch.
                if sec.title then sec.title:Show() end
                sec.arrow:SetDown(not sec.collapsed)
                sec.rule:SetShown(sec.collapsed)
            elseif sec.title then
                sec.title:ClearAllPoints()
                if side == "R" then sec.title:SetPoint("TOPLEFT", pg, "TOP", 12, topY - 2)
                else sec.title:SetPoint("TOPLEFT", 12, topY - 2) end
                sec.title:Show(); hdrH = LAY.hdr
                -- the rule sits under the title and spans the section, giving
                -- the block a visible top edge (see THE SECTION RULE)
                if sec.hr then
                    span(sec.hr, topY - hdrH + 5)   -- same edges as the box
                    sec.hr:SetHeight(AT.Hairline(pg))
                    sec.hr:Show()
                end
            end
            local boxTop = topY - hdrH
            span(sec.box, boxTop)

            -- SYNC BEFORE MEASURING. A row whose label text only arrives in
            -- _sync (every dynamic list row) was otherwise measured while still
            -- EMPTY, so the control column came out at ~26px and the label
            -- rendered as ".." until some later layout re-measured it.
            for _, r in ipairs(sec.rows) do
                if r._sync then r._sync() end
            end
            -- CONTROL COLUMN, measured. Use the UNBOUNDED width: GetStringWidth
            -- reports the already-truncated width, so a truncated label would feed
            -- a smaller column back in on the next pass and ratchet down.
            local col
            for _, r in ipairs(sec.rows) do
                if r._colLabel and ((not r._visibleFn) or r._visibleFn()) then
                    local fs = r._colLabel
                    local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
                           or fs:GetStringWidth() or 0
                    w = 10 + w + 16
                    if not col or w > col then col = w end
                end
            end
            local by = -2
            for _, row in ipairs(sec.rows) do
                if (not row._visibleFn) or row._visibleFn() then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", sec.box, "TOPLEFT", 6, by)
                    row:SetPoint("TOPRIGHT", sec.box, "TOPRIGHT", -6, by)
                    row:Show(); by = by - row._h
                else row:Hide() end
            end
            if col then
                -- An anchored frame has NO real width until the client lays it
                -- out, so on the first pass after a panel is built the box
                -- measures 0. The old code just skipped the cap ("until real")
                -- and nothing ever re-ran, which is why a wide button stayed
                -- clipped until the window was resized by hand.
                -- FIRST: derive the width from the PAGE, whose size comes from
                -- the window's explicit SetSize, using the same insets span()
                -- applies. That resolves it immediately in almost every case.
                local bw = sec.box:GetWidth() or 0
                if bw <= 60 then
                    local pw = pg:GetWidth() or 0
                    if pw > 60 then
                        bw = (side and (pw / 2) or pw) - 12
                    end
                end
                -- SECOND: if it still is not known, ask for one more pass on
                -- the next frame rather than leaving the panel wrong.
                if bw <= 60 then pg._sizeUnresolved = true end
                if bw > 60 then
                    -- CAP AGAINST THE WIDEST CONTROL, not a fixed 34. That
                    -- constant assumed every control was a checkbox, so a wide
                    -- action button ("Clear all queueing abilities", 190px)
                    -- placed at a column measured from long labels ran past
                    -- the section edge and SetClipsChildren sliced its right
                    -- side off. Any control on the column must fit.
                    local widest = 34
                    for _, r in ipairs(sec.rows) do
                        if r._colCtrl and ((not r._visibleFn) or r._visibleFn()) then
                            local cw = r._colCtrl:GetWidth() or 0
                            if cw > widest then widest = cw end
                        end
                    end
                    local cap = bw - widest - 12
                    if col > cap then col = math.max(12, cap) end
                end
                for _, r in ipairs(sec.rows) do
                    if r._colCtrl then
                        r._colCtrl:ClearAllPoints()
                        r._colCtrl:SetPoint("LEFT", r, "LEFT", col, 0)
                        -- _colFill = true: fill to the ROW's right edge
                        -- (inputs); a frame: stop at that frame (sliders)
                        if r._colFill == true then
                            r._colCtrl:SetPoint("RIGHT", r, "RIGHT", -12, 0)
                        elseif r._colFill then
                            r._colCtrl:SetPoint("RIGHT", r._colFill, "LEFT", -8, 0)
                        end
                        if r._colLabel then r._colLabel:SetPoint("RIGHT", r, "LEFT", col - 6, 0) end
                    end
                end
            end
            local fullH = math.max(10, -by + 3)
            local f = sec.f or 1
            local shownH = (f >= 1) and fullH or math.max(2, math.floor(fullH * f + 0.5))
            sec.box:SetShown(not (sec.collapsed and f <= 0))
            sec.box:SetHeight(shownH)
            local bottom = boxTop - (sec.box:IsShown() and shownH or 0) - LAY.gap
            if side == "L" then pairTopY, pairBottomY, y = topY, bottom, bottom
            elseif side == "R" then y = math.min(pairBottomY or bottom, bottom); pairTopY, pairBottomY = nil, nil
            else y = bottom end
            end
        end
    end
    -- add the scroll offset back: _contentH is the FULL laid-out height, not
    -- what is left below the current scroll position
    pg._contentH = -y + 8 + (pg._scrollOff or 0)
    if pg._scroll then pg._scroll.paint() end

    -- SELF-CORRECTING FIRST PASS. Something was laid out against a width the
    -- client had not resolved yet, so this pass used a fallback. Run once more
    -- on the next frame, when the real sizes exist. Guarded so it can only
    -- ever queue one re-pass, and the flag clears before the re-pass so a
    -- genuinely unresolvable page (a hidden panel) cannot spin.
    -- CAPPED. A page that can never resolve (hidden, zero-width parent) must
    -- not re-queue for ever - that would be a permanent timer burning CPU for
    -- nothing. Three frames is far more than the one it actually takes, and
    -- the count resets whenever a pass succeeds.
    if pg._sizeUnresolved then
        if not pg._relayoutQueued and (pg._relayoutTries or 0) < 3 then
            pg._relayoutQueued = true
            pg._relayoutTries = (pg._relayoutTries or 0) + 1
            C_Timer.After(0, function()
                pg._relayoutQueued = nil
                pg._sizeUnresolved = nil
                if pg:IsShown() then AT.LayoutPage(pg) end
            end)
        end
    else
        pg._relayoutTries = nil
    end
end

--[[ ROW BUILDERS ============================================================]]

-- Checkbox sits NEXT TO its label (LayoutPage then column-aligns it), whole row
-- clickable, description as a hover TOOLTIP and never an inline row.
function AT.RowToggle(pg, label, get, set, visibleFn, desc)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local cb = AT.MakeCheckbox(row)
    cb:SetPoint("LEFT", lbl, "RIGHT", 14, 0)
    cb:SetOn(get())
    local function flip()
        AT.CloseDropdown()
        set(not get()); cb:SetOn(get())
        PlaySound(get() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                         or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
        AT.LayoutPage(pg)
    end
    cb:SetScript("OnClick", flip)
    row:EnableMouse(true); row:SetScript("OnMouseUp", flip)
    row:HookScript("OnEnter", function() cb:SetHover(true) end)
    row:HookScript("OnLeave", function() cb:SetHover(false) end)
    -- the checkbox is a child Button that EATS mouse events: hover glow and
    -- tooltip must be hooked on it too, or the toggle itself is a dead zone
    cb:HookScript("OnEnter", function() cb:SetHover(true) end)
    cb:HookScript("OnLeave", function() cb:SetHover(false) end)
    if desc then AT.Tooltip(row, label, desc); AT.Tooltip(cb, label, desc) end
    row._colLabel, row._colCtrl = lbl, cb
    row._sync = function() cb:SetOn(get()) end
    return row
end

-- desc and hint may each be a string OR a function (live text). hint draws dim
-- placeholder text INSIDE the box while empty: use it to show what is in effect
-- without PRE-FILLING, which would turn "I left it alone" into a saved value.
-- live = true commits on every USER keystroke/paste (not just focus lost), for
-- fields that feed a derived row (e.g. a link the next row transforms).
function AT.RowInput(pg, label, get, set, visibleFn, desc, hint, live)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    -- inputs sit ON the shared control column (the locked template forbids
    -- far-edge pinning: the field drifts away from the word it belongs to)
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    box:SetSize(160, 18); box:SetPoint("LEFT", row._ctrlX, 0); Skin(box, COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, ""); box:SetTextInsets(6, 6, 0, 0)
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); box:SetAutoFocus(false)
    box:SetText(get() or "")
    local hintFS
    if hint then
        hintFS = box:CreateFontString(nil, "OVERLAY")
        hintFS:SetFont(STANDARD_TEXT_FONT, 11, "")
        hintFS:SetPoint("LEFT", 6, 0); hintFS:SetPoint("RIGHT", -6, 0)
        hintFS:SetJustifyH("LEFT")
        hintFS:SetTextColor(COL.faint[1], COL.faint[2], COL.faint[3])
    end
    local function syncHint()
        if not hintFS then return end
        hintFS:SetText(((type(hint) == "function") and hint()) or hint or "")
        hintFS:SetShown((box:GetText() or "") == "")
    end
    syncHint()
    box:SetScript("OnTextChanged", function(self, userInput)
        syncHint()
        if live and userInput then set(self:GetText() or "") end
    end)
    -- the tooltip must be hooked on the BOX too: it is a child that eats mouse
    -- events, so a row-only hook shows nothing when you hover the field
    if desc then AT.Tooltip(row, label, desc); AT.Tooltip(box, label, desc) end
    local function commit() set(box:GetText() or ""); box:SetText(get() or ""); syncHint() end
    box:SetScript("OnEnterPressed", function() box:ClearFocus() end)
    box:SetScript("OnEscapePressed", function() box:SetText(get() or ""); box:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    box:SetScript("OnEditFocusLost", function() commit(); box:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    -- inputs sit on the measured control column like every other control,
    -- at the FIXED ArcSkin field width - never filled to the row edge
    -- (Arc: a full-width box is "too much"; the template agrees at 160)
    row._colLabel, row._colCtrl = lbl, box
    row._sync = function()
        if not box:HasFocus() then box:SetText(get() or "") end
        syncHint()
    end
    return row
end

function AT.RowDropdown(pg, owner, label, get, set, itemsFn, visibleFn, onSelect)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local dd = AT.MakeDropdown(owner, row, nil, itemsFn, get, set, onSelect)
    dd:SetPoint("LEFT", row._ctrlX, 0)
    row._colLabel, row._colCtrl = lbl, dd
    row._sync = dd.Refresh
    return row
end

function AT.RowColor(pg, label, get, set, visibleFn)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local sw = AT.MakeSwatch(row)
    sw:SetPoint("LEFT", row._ctrlX, 0)
    local function refresh() sw:SetColor(get()) end
    refresh()
    sw:SetScript("OnClick", function()
        AT.CloseDropdown()
        local c = get()
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = c[1], g = c[2], b = c[3], hasOpacity = false,
                swatchFunc = function()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    set({ r, g, b }); refresh()
                end,
                cancelFunc = function() set({ c[1], c[2], c[3] }); refresh() end,
            })
        end
    end)
    row._colLabel, row._colCtrl = lbl, sw
    row._sync = refresh
    return row
end

-- Slider FILLS the space between the column and the stepper, so it grows with
-- the box and never leaves dead air or clips in a narrow one.
function AT.RowSlider(pg, label, get, set, minV, maxV, step, isPct, visibleFn)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local lbl = AT.RowLabel(row, label)
    local s = CreateFrame("Slider", nil, row, "BackdropTemplate")
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    local settingUp = true
    -- isPct: true = a 0..1 value shown as a percent; a FORMAT STRING (e.g.
    -- "%.2f") = the raw value shown with it, typed values taken as-is (for
    -- fine-step units like seconds that a percent display would misread)
    local fmtStr = type(isPct) == "string" and isPct or nil
    if fmtStr then isPct = false end
    local function fmt(v)
        v = tonumber(v) or 0
        if fmtStr then return fmtStr:format(v)
        elseif isPct then return ("%.0f"):format(v * 100)
        elseif step < 1 then return ("%.1f"):format(v)
        else return ("%d"):format(math.floor(v + 0.5)) end
    end
    -- LIVE BOUNDS (v12): minV / maxV may be FUNCTIONS, re-read on every
    -- refresh, so a range can follow the record; the slider's own range is
    -- re-applied on every sync
    local function bounds()
        local lo = (type(minV) == "function") and minV() or minV
        local hi = (type(maxV) == "function") and maxV() or maxV
        lo, hi = tonumber(lo) or 0, tonumber(hi) or 0
        if hi < lo then hi = lo end
        return lo, hi
    end
    local function clamp(v)
        local lo, hi = bounds()
        if v < lo then v = lo elseif v > hi then v = hi end
        if step >= 1 then v = math.floor(v + 0.5) end
        return v
    end
    local function refresh()
        settingUp = true
        local lo, hi = bounds()
        s:SetMinMaxValues(lo, hi)
        s:SetValue(math.max(lo, math.min(hi, get() or 0)))
        if not box:HasFocus() then box:SetText(fmt(get() or 0)) end
        settingUp = false
    end
    local function setVal(v) set(clamp(v)); refresh() end
    local function arrow(glyph, delta)
        local b = CreateFrame("Button", nil, row, "BackdropTemplate")
        b:SetSize(14, 14); Skin(b, COL.well)
        local g = b:CreateFontString(nil, "OVERLAY")
        g:SetFont(STANDARD_TEXT_FONT, 11, ""); g:SetPoint("CENTER")
        g:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]); g:SetText(glyph)
        b:SetScript("OnClick", function() AT.CloseDropdown(); setVal((get() or (bounds())) + delta) end)
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
        return b
    end
    local plus = arrow("+", step)
    local minus = arrow("-", -step)
    box:SetSize(38, 16); Skin(box, COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, "")
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    box:SetJustifyH("CENTER"); box:SetAutoFocus(false)
    local function commitTyped(self)
        local n = tonumber(self:GetText())
        if n then if isPct then n = n / 100 end setVal(n) else refresh() end
    end
    box:SetScript("OnEnterPressed", function(self) commitTyped(self); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", commitTyped)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Blizzard-length: a FIXED slider with the stepper cluster trailing it,
    -- never a row-filling bar (the "massive sliders" report)
    s:SetOrientation("HORIZONTAL"); s:SetHeight(10)
    s:SetWidth(LAY.sliderW)
    s:SetPoint("LEFT", row._ctrlX, 0)
    minus:SetPoint("LEFT", s, "RIGHT", 8, 0)
    box:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    plus:SetPoint("LEFT", box, "RIGHT", 2, 0)
    Skin(s, COL.well)
    s:SetThumbTexture(WHITE)
    local th = s:GetThumbTexture()
    th:SetSize(8, 10); th:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    s:SetMinMaxValues(bounds()); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
    s:SetScript("OnValueChanged", function(_, v)
        if settingUp then return end
        if step >= 1 then v = math.floor(v + 0.5) end
        if not box:HasFocus() then box:SetText(fmt(v)) end
        set(v)
    end)
    refresh()
    row._colLabel, row._colCtrl = lbl, s
    row._sync = refresh
    return row
end

-- An action row. THE BUTTON SITS ON THE CONTROL COLUMN, exactly like a
-- toggle's checkbox or a dropdown, so it lines up with every other control on
-- the page instead of floating at its own left offset - that floating was what
-- made panels read as "random buttons around" (Arc, 2026-09-23).
--
-- rowLabel (optional) puts explanatory text on the left, which is the form to
-- prefer: "Pick the abilities that queue it   [ Pick on my bars ]" reads as a
-- row of the section, where a lone button reads as loose furniture.
-- quiet = true for destructive or secondary actions.
function AT.RowButton(pg, label, onClick, visibleFn, w, rowLabel, quiet)
    local row = AT.AddRow(pg, LAY.rowH, visibleFn)
    local b = (quiet and AT.MakeQuietButton or AT.MakeSmallButton)(row, label, w or 150)
    b:SetScript("OnClick", function() AT.CloseDropdown(); onClick() end)
    if rowLabel then
        local lbl = AT.RowLabel(row, rowLabel)
        row._colLabel = lbl
    end
    -- LayoutPage pins _colCtrl to the measured column; a row with no label
    -- still aligns there, so a bare button never invents a third margin
    row._colCtrl = b
    row.button = b
    return row
end

-- ACTION ROW: several buttons on ONE line, evenly spaced, aligned to one edge.
--
-- THE GROUPED-ACTION LAW: stacking N separate RowButtons puts N buttons of N
-- widths down the left margin with content rows between them, which is what
-- makes a panel look like scattered controls. Actions that belong together go
-- on one line, share a width, and sit at a predictable edge.
--
-- list  = { { label, onClick, quiet = bool, visibleFn = fn, w = n }, ... }
-- align = "right" (default, the dialog-footer read) or "left"
function AT.RowActions(pg, list, align, visibleFn)
    local row = AT.AddRow(pg, LAY.rowH + 4, visibleFn)
    local made = {}
    for i, spec in ipairs(list) do
        local b = (spec.quiet and AT.MakeQuietButton or AT.MakeSmallButton)(row, spec.label, spec.w or 150)
        b:SetScript("OnClick", function() AT.CloseDropdown() spec.onClick() end)
        made[i] = { btn = b, vis = spec.visibleFn }
    end
    -- re-laid every pass so a button appearing or vanishing re-packs the row
    -- instead of leaving a hole where it used to be
    row._sync = function()
        local shown = {}
        for _, m in ipairs(made) do
            if (not m.vis) or m.vis() then shown[#shown + 1] = m.btn else m.btn:Hide() end
        end
        local prev
        for _, b in ipairs(shown) do
            b:ClearAllPoints()
            if align == "left" then
                if prev then b:SetPoint("LEFT", prev, "RIGHT", 8, 0)
                else b:SetPoint("LEFT", 12, 0) end
            else
                if prev then b:SetPoint("RIGHT", prev, "LEFT", -8, 0)
                else b:SetPoint("RIGHT", -12, 0) end
            end
            b:Show()
            prev = b
        end
    end
    return row
end

-- a hairline between logical blocks inside one section, for when a section has
-- two distinct parts but does not deserve two headers
function AT.RowDivider(pg, visibleFn)
    local row = AT.AddRow(pg, 9, visibleFn)
    local line = row:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetVertexColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
    line:SetPoint("LEFT", 12, 0)
    line:SetPoint("RIGHT", -12, 0)
    line:SetHeight(1)
    row._sync = function() line:SetHeight(AT.Hairline(row)) end
    return row
end

function AT.RowDesc(pg, text, h, visibleFn)
    local row = AT.AddRow(pg, h or LAY.descH, visibleFn)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    fs:SetPoint("TOPLEFT", 10, -2)
    fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3]); fs:SetText(text)
    -- AUTO-HEIGHT: long descriptions wrap, and the row grows to hold every
    -- line (the passed h is a MINIMUM) - text must never bleed into the
    -- next row. Width comes from the page: the row itself is unsized on
    -- the first pass.
    row._minH = h or LAY.descH
    row._sync = function()
        local w = pg:GetWidth() or 0
        -- same first-pass problem as the control column: bailing here left the
        -- row at its minimum height and the text overflowing into the next
        -- one. Flag it so LayoutPage re-runs once the real width exists.
        if w < 60 then pg._sizeUnresolved = true return end
        fs:SetWidth(w - 36)
        local want = math.max(row._minH, math.floor((fs:GetStringHeight() or 12) + 8))
        if row._h ~= want then row._h = want row:SetHeight(want) end
    end
    return row
end

--[[ DISCORD FOOTER ==========================================================]]

-- Addons cannot open URLs, so the button shows a copy popup with the invite
-- selected for Ctrl+C. Reserve ~34px at the window bottom for the footer band.
function AT.AddDiscordFooter(p, globalName)
    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    line:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 1)
    line:SetPoint("BOTTOMLEFT", 10, 32); line:SetPoint("BOTTOMRIGHT", -10, 32)
    line:SetHeight(1)
    local b = CreateFrame("Button", nil, p, "BackdropTemplate")
    b:SetSize(84, 20); b:SetPoint("BOTTOMLEFT", 10, 9); Skin(b, COL.well)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 11, ""); fs:SetPoint("CENTER")
    fs:SetText("|cff7289DADiscord|r")
    local hint = p:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 11, "")
    hint:SetPoint("LEFT", b, "RIGHT", 10, 0)
    hint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    hint:SetText("Questions or help? Join the Arc UI Discord")
    b:SetScript("OnEnter", function()
        b:SetBackdropBorderColor(COL.blurple[1], COL.blurple[2], COL.blurple[3], 1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
    end)
    b:SetScript("OnClick", function()
        if not AT.copyPopup then
            local d = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
            d:SetSize(300, 70); d:SetFrameStrata("FULLSCREEN_DIALOG"); d:SetToplevel(true)
            Skin(d, COL.panel, COL.arc)
            local t = d:CreateFontString(nil, "OVERLAY")
            t:SetFont(STANDARD_TEXT_FONT, 12, ""); t:SetPoint("TOP", 0, -10)
            t:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            t:SetText("Press Ctrl+C to copy, then open it in your browser")
            local eb = CreateFrame("EditBox", nil, d, "BackdropTemplate")
            eb:SetSize(272, 22); eb:SetPoint("TOP", 0, -32); Skin(eb, COL.well)
            eb:SetFont(STANDARD_TEXT_FONT, 12, ""); eb:SetTextInsets(6, 6, 0, 0)
            eb:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); eb:SetAutoFocus(false)
            eb:SetScript("OnEscapePressed", function() d:Hide() end)
            eb:SetScript("OnEnterPressed", function() d:Hide() end)
            eb:SetScript("OnEditFocusLost", function() d:Hide() end)
            if globalName then tinsert(UISpecialFrames, globalName) end
            d.box = eb; AT.copyPopup = d
        end
        AT.copyPopup:ClearAllPoints()
        AT.copyPopup:SetPoint("CENTER", p, "CENTER", 0, 0)
        AT.copyPopup:Show(); AT.copyPopup:Raise()
        AT.copyPopup.box:SetText(AT.DISCORD)
        AT.copyPopup.box:SetFocus(); AT.copyPopup.box:HighlightText()
    end)
    return b
end

-- mock-addon export (replaces the canonical file's trailing return, which a
-- toc-loaded file discards): hang AT on the private namespace instead
local _ADDON, NS = ...
NS.AT = AT
