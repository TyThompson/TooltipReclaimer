-- Names the addon behind each line of a tooltip.
--
-- AddLine, AddDoubleLine, and the line fontstrings' SetText are hooked, and
-- the calling file is read from debugstack. Lines drawn by the client are
-- "Game" and stay hidden unless /ttr game is on. The labels are a separate
-- frame. Detected addon hooks are listed under Options with the file they
-- came from, and unchecking one removes that addon's lines from the tooltip.

local ADDON = ...
local SELF = "TooltipReclaimer"
local MAX_LINES = 200

local db = {
    enabled = true,
    showGame = false,
    showFile = false,
    seen = {},
    hidden = {},
}

local sourceOf = setmetatable({}, { __mode = "k" })
local tracked = {}
local hookedMethods = setmetatable({}, { __mode = "k" })
local hookedFonts = setmetatable({}, { __mode = "k" })
local overlays = {}
local errorOnce

local Remember, PackTooltip, QueuePack
local packing
local packQueued = setmetatable({}, { __mode = "k" })
-- One compress per hover (cleared on Hide). After that, OnUpdate only enforces
-- bottom padding so a later client resize can't clip the last line again.
local packedOnce = setmetatable({}, { __mode = "k" })
local fitHold = setmetatable({}, { __mode = "k" })

local function Say(msg)
    print("|cff6ec6ffTooltip Reclaimer|r  " .. msg)
end

local function LoadDB()
    local saved = TooltipReclaimerDB
    if type(saved) ~= "table" then
        saved = {}
        TooltipReclaimerDB = saved
    end
    if saved.enabled == nil then saved.enabled = true end
    if saved.showGame == nil then saved.showGame = false end
    if saved.showFile == nil then saved.showFile = false end
    if type(saved.seen) ~= "table" then saved.seen = {} end
    if type(saved.hidden) ~= "table" then saved.hidden = {} end
    for name, value in pairs(saved.seen) do
        if type(value) ~= "table" then saved.seen[name] = {} end
    end
    db = saved
end

local function IsClient(addon)
    return addon == "Game"
        or addon == "Blizzard"
        or addon:sub(1, 9) == "Blizzard_"
end

local function IsPlayer(addon)
    return addon and not IsClient(addon)
end

local function IsHidden(addon)
    return type(db.hidden) == "table" and db.hidden[addon] == true
end

-- Midnight tooltips hand back secret numbers. type() still says "number",
-- and a comparison raises once this addon has tainted the execution.
local function IsSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret and true or false
end

local function PlainNumber(value)
    if type(value) ~= "number" or IsSecret(value) then return nil end
    return value
end

local function Metric(obj, method)
    if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
    local ok, value = pcall(obj[method], obj)
    if not ok then return nil end
    return PlainNumber(value)
end

local function Flag(obj, method)
    if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
    local ok, value = pcall(obj[method], obj)
    if not ok or IsSecret(value) then return nil end
    return value
end

local onAddonSeen
local seenRefreshQueued

local function FlushSeen()
    seenRefreshQueued = false
    if onAddonSeen then onAddonSeen() end
end

local function SourceFile(detail)
    if type(detail) ~= "string" or detail == "" then return nil end
    return detail:match("^(.*):%d+$") or detail
end

local function FileLabel(addon)
    local files = type(db.seen) == "table" and db.seen[addon]
    if type(files) ~= "table" then return "" end
    local list = {}
    for file, on in pairs(files) do
        if on and type(file) == "string" then
            list[#list + 1] = file
        end
    end
    table.sort(list)
    return table.concat(list, ",  ")
end

local function NoteSeen(addon, detail)
    if not IsPlayer(addon) then return end
    if type(db.seen) ~= "table" then db.seen = {} end
    local files = db.seen[addon]
    local first = type(files) ~= "table"
    if first then
        files = {}
        db.seen[addon] = files
    end
    local file = SourceFile(detail)
    local added = file and not files[file]
    if added then files[file] = true end
    if not first and not added then return end
    if not onAddonSeen or seenRefreshQueued then return end
    seenRefreshQueued = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, FlushSeen)
    else
        FlushSeen()
    end
end

local function HSV(h, s, v)
    local c = v * s
    local hp = h / 60
    local x = c * (1 - math.abs(hp % 2 - 1))
    local m = v - c
    local r, g, b = 0, 0, 0
    if hp < 1 then r, g, b = c, x, 0
    elseif hp < 2 then r, g, b = x, c, 0
    elseif hp < 3 then r, g, b = 0, c, x
    elseif hp < 4 then r, g, b = 0, x, c
    elseif hp < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x
    end
    return r + m, g + m, b + m
end

local function Color(addon)
    if IsClient(addon) then return 0.67, 0.67, 0.67 end
    local hash = 0
    for i = 1, #addon do
        hash = (hash * 33 + addon:byte(i)) % 997
    end
    return HSV(hash % 360, 0.55, 1)
end

local function Colored(addon)
    local r, g, b = Color(addon)
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5),
        addon)
end

-- Closest addon frame in the stack. Blizzard frames are kept only as a fallback
-- so a line the client drew is "Game", while a line an addon asked AddLine to
-- draw is named for that addon even though FrameXML sits between them.
local function Caller()
    if type(debugstack) ~= "function" then return "Game" end
    local ok, stack = pcall(debugstack, 2, 40, 0)
    if not ok or type(stack) ~= "string" then return "Game" end
    if type(issecretvalue) == "function" then
        local secretOk, secret = pcall(issecretvalue, stack)
        if secretOk and secret then return "Game" end
    end

    local blizz, blizzDetail
    for line in stack:gmatch("[^\r\n]+") do
        if not line:find(SELF, 1, true) then
            local name = line:match("[Aa]dd[Oo]ns[/\\]+([^/\\:\"%]]+)")
            if name and name ~= SELF then
                local file, num = line:match("([^/\\:\"%]]+%.lua)%D+(%d+)")
                if not file then
                    file, num = line:match("([^/\\:\"%]]+%.xml)%D+(%d+)")
                end
                local detail = file and num and (file .. ":" .. num) or nil
                if not IsClient(name) then
                    return name, detail
                elseif not blizz then
                    blizz, blizzDetail = name, detail
                end
            end
        end
    end
    if blizz then return blizz, blizzDetail end
    return "Game"
end

local function FontString(tooltip, side, index)
    local key = side .. index
    local fs = tooltip[key]
    if fs then return fs end
    local name = tooltip.GetName and tooltip:GetName()
    if name then return _G[name .. key] end
end

local function ForEachLine(tooltip, fn)
    for i = 1, MAX_LINES do
        local left = FontString(tooltip, "TextLeft", i)
        local right = FontString(tooltip, "TextRight", i)
        if not left and not right then return end
        fn(i, left, right)
    end
end

local function Shown(fs)
    if not fs then return false end
    local shown = Flag(fs, "IsShown")
    if shown == nil or shown == false then return false end
    local width = Metric(fs, "GetStringWidth")
    if not width then return true end
    return width > 1
end

local function CenterOf(fs)
    local top = Metric(fs, "GetTop")
    local bottom = Metric(fs, "GetBottom")
    if not top or not bottom then return nil end
    return (top + bottom) / 2, top - bottom
end

-- Remember the function hooksecurefunc left behind. Comparing against the
-- original would see a new wrapper every time and stack another hook per call.
local function HookMethod(tooltip, method, handler)
    local fn = tooltip[method]
    if type(fn) ~= "function" or type(hooksecurefunc) ~= "function" then return end
    local state = hookedMethods[tooltip]
    if not state then
        state = {}
        hookedMethods[tooltip] = state
    end
    if state[method] == fn then return end
    hooksecurefunc(tooltip, method, handler)
    state[method] = tooltip[method]
end

local function HookFontString(fs)
    if not fs or type(hooksecurefunc) ~= "function" then return end
    local function hook(method)
        local fn = fs[method]
        if type(fn) ~= "function" then return end
        local state = hookedFonts[fs]
        if not state then
            state = {}
            hookedFonts[fs] = state
        end
        if state[method] == fn then return end
        hooksecurefunc(fs, method, function(self)
            if packing then return end
            local addon, detail = Caller()
            local parent = self.GetParent and self:GetParent()
            Remember(self, addon, detail, false, parent)
        end)
        state[method] = fs[method]
    end
    hook("SetText")
    hook("SetFormattedText")
end

local function Snapshot(fs)
    local okT, text = pcall(fs.GetText, fs)
    if not okT then return end
    local r, g, b
    local okC, cr, cg, cb = pcall(fs.GetTextColor, fs)
    if okC then
        r, g, b = PlainNumber(cr), PlainNumber(cg), PlainNumber(cb)
    end
    return text, r, g, b, true
end

local function BlankFont(fs)
    if not fs then return end
    pcall(fs.SetText, fs, "")
    pcall(fs.Hide, fs)
    if fs.SetAlpha then pcall(fs.SetAlpha, fs, 0) end
    sourceOf[fs] = nil
end

local function WriteFont(fs, entry)
    if not fs then return end
    if not entry then
        BlankFont(fs)
        return
    end
    if not entry.data then
        -- Kept the slot but couldn't snapshot (rare); leave the glyphs alone.
        sourceOf[fs] = entry.src
        return
    end
    if fs.SetAlpha then pcall(fs.SetAlpha, fs, 1) end
    pcall(fs.Show, fs)
    pcall(fs.SetText, fs, entry.data.text)
    if entry.data.r then
        pcall(fs.SetTextColor, fs, entry.data.r, entry.data.g, entry.data.b)
    end
    sourceOf[fs] = entry.src
end

local function LineBlocked(fs)
    local src = fs and sourceOf[fs]
    return src and IsHidden(src.addon) or false
end

-- Copy a line even when the text is secret (Forever/Midnight). Passing the
-- value straight into SetText is fine; reading it for compares is not.
local function ReadLine(fs)
    local text, r, g, b, hasText = Snapshot(fs)
    if not hasText then return nil end
    if IsSecret(text) then
        return { text = text }
    end
    return { text = text, r = r, g = g, b = b }
end

local function LineBottom(fs)
    if not fs then return nil end
    local bottom = Metric(fs, "GetBottom")
    if bottom then return bottom end
    local top = Metric(fs, "GetTop")
    if not top then return nil end
    local extent = Metric(fs, "GetStringHeight") or Metric(fs, "GetHeight")
    if extent then return top - extent end
end

-- True if the fontstring is up (even alpha 0 spacers); ignores string-width.
local function IsUp(fs)
    return fs and Flag(fs, "IsShown") and true or false
end

-- Grow the frame so the lowest shown line has BOTTOM_PAD px of air under it.
-- Uses height shortfall (not absolute tipTop math) so bottom-anchored tips work.
-- Safe to call every OnUpdate: no-ops when the gap is already large enough.
local BOTTOM_PAD = 32
local function FitPackedTooltip(tooltip)
    local tipBottom = Metric(tooltip, "GetBottom")
    local height = Metric(tooltip, "GetHeight")
    if not tipBottom or not height then return end

    local bottom
    ForEachLine(tooltip, function(_, left, right)
        local fs = IsUp(left) and left or (IsUp(right) and right or nil)
        local lineBottom = LineBottom(fs)
        if lineBottom then
            bottom = bottom and math.min(bottom, lineBottom) or lineBottom
        end
    end)
    -- Also cover money frames hanging under a "Sell Price" line.
    if tooltip.GetName then
        local ok, name = pcall(tooltip.GetName, tooltip)
        if ok and type(name) == "string" then
            for i = 1, 4 do
                local money = _G[name .. "MoneyFrame" .. i]
                if money and Flag(money, "IsShown") then
                    local mb = Metric(money, "GetBottom")
                    if mb then
                        bottom = bottom and math.min(bottom, mb) or mb
                    end
                end
            end
        end
    end
    -- No measurable lines (secrets): do nothing — never grow unboundedly on OnUpdate.
    if not bottom then return end

    local gap = bottom - tipBottom
    if gap >= BOTTOM_PAD then return end
    pcall(tooltip.SetHeight, tooltip, height + (BOTTOM_PAD - gap))
end

-- Invisible spacer under the last kept line so measurement has a pad row.
local function AddBottomSpacer(pair)
    if not pair or not pair.left then return end
    local fs = pair.left
    pcall(fs.SetText, fs, ".")
    if fs.SetAlpha then pcall(fs.SetAlpha, fs, 0) end
    pcall(fs.Show, fs)
    sourceOf[fs] = nil
end

-- Drop lines a blocked addon added and close the gap by sliding the kept
-- lines up. Runs at most once per hover.
PackTooltip = function(tooltip, force)
    if packing or type(tooltip) ~= "table" then return end
    if packedOnce[tooltip] and not force then return end

    local linePairs = {}
    ForEachLine(tooltip, function(_, left, right)
        linePairs[#linePairs + 1] = { left = left, right = right }
    end)

    local kept = {}
    local blocked = false
    for _, pair in ipairs(linePairs) do
        local showL, showR = Shown(pair.left), Shown(pair.right)
        if showL or showR then
            local blockL = showL and LineBlocked(pair.left)
            local blockR = showR and LineBlocked(pair.right)
            if blockL or blockR then blocked = true end
            local keepL = showL and not blockL
            local keepR = showR and not blockR
            if keepL or keepR then
                kept[#kept + 1] = {
                    left = keepL and { data = ReadLine(pair.left), src = sourceOf[pair.left] } or nil,
                    right = keepR and { data = ReadLine(pair.right), src = sourceOf[pair.right] } or nil,
                }
            end
        end
    end
    if not blocked then return end

    packing = true
    local okPack, packErr = pcall(function()
        for i, pair in ipairs(linePairs) do
            local row = kept[i]
            if row then
                WriteFont(pair.left, row.left)
                WriteFont(pair.right, row.right)
            elseif Shown(pair.left) or Shown(pair.right) or sourceOf[pair.left] or sourceOf[pair.right] then
                BlankFont(pair.left)
                BlankFont(pair.right)
            end
        end
        AddBottomSpacer(linePairs[#kept + 1])
        FitPackedTooltip(tooltip)
    end)
    packing = false
    packedOnce[tooltip] = true
    if okPack then
        fitHold[tooltip] = true
    elseif not errorOnce then
        errorOnce = true
        Say("|cffff8888couldn't remove a blocked line:|r " .. tostring(packErr))
    end
end

QueuePack = function(tooltip)
    if packing or type(tooltip) ~= "table" then return end
    if packedOnce[tooltip] or packQueued[tooltip] then return end
    packQueued[tooltip] = true
    local function run()
        packQueued[tooltip] = nil
        -- Second defer so other addons' After(0) stock/craft lines land first.
        local function go()
            PackTooltip(tooltip)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0, go)
        else
            go()
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, run)
    else
        run()
    end
end

-- upgradeOnly fills a line AddLine created before its fontstring was hooked.
-- A later SetText (upgradeOnly false) is the real writer and replaces it.
Remember = function(fs, addon, detail, upgradeOnly, tooltip)
    if packing or not fs or not addon then return false end
    NoteSeen(addon, detail)
    HookFontString(fs)
    if IsPlayer(addon) and IsHidden(addon) then
        local prev = sourceOf[fs]
        if prev and prev.hasText and not IsHidden(prev.addon) and not upgradeOnly then
            packing = true
            pcall(fs.SetText, fs, prev.text)
            if prev.r then pcall(fs.SetTextColor, fs, prev.r, prev.g, prev.b) end
            packing = false
            sourceOf[fs] = prev
            return false
        end
        sourceOf[fs] = { addon = addon, detail = detail }
        if type(tooltip) == "table" and packedOnce[tooltip] then
            -- Already resized this fill — hide only, never refit.
            packing = true
            pcall(fs.SetText, fs, "")
            pcall(fs.Hide, fs)
            if fs.SetAlpha then pcall(fs.SetAlpha, fs, 0) end
            packing = false
        elseif type(tooltip) == "table" then
            QueuePack(tooltip)
        end
        return false
    end
    local prev = sourceOf[fs]
    if upgradeOnly and prev and (IsPlayer(prev.addon) or not IsPlayer(addon)) then
        return false
    end
    local text, r, g, b, hasText = Snapshot(fs)
    sourceOf[fs] = {
        addon = addon, detail = detail,
        text = text, r = r, g = g, b = b,
        hasText = hasText and true or false,
    }
    return false
end

local OnAdded, ClearSources
local methodHandlers = setmetatable({}, { __mode = "k" })

local function Handlers(tooltip)
    local handlers = methodHandlers[tooltip]
    if handlers then return handlers end
    handlers = {
        added = function(self) OnAdded(self, false) end,
        addedDouble = function(self) OnAdded(self, true) end,
    }
    methodHandlers[tooltip] = handlers
    return handlers
end

local function InstallHooks(tooltip)
    local handlers = Handlers(tooltip)
    HookMethod(tooltip, "AddLine", handlers.added)
    HookMethod(tooltip, "AddDoubleLine", handlers.addedDouble)
    HookMethod(tooltip, "ClearLines", ClearSources)
    ForEachLine(tooltip, function(_, left, right)
        HookFontString(left)
        HookFontString(right)
    end)
end

OnAdded = function(tooltip, isDouble)
    if packing then return end
    local addon, detail = Caller()
    local count = PlainNumber(select(2, pcall(tooltip.NumLines, tooltip)))
    if not count or count < 1 then return end
    Remember(FontString(tooltip, "TextLeft", count), addon, detail, true, tooltip)
    if isDouble then
        Remember(FontString(tooltip, "TextRight", count), addon, detail, true, tooltip)
    end
    InstallHooks(tooltip)
end

ClearSources = function(tooltip)
    -- Leave packedOnce alone until OnHide. Clearing it here re-packs on every
    -- in-place rebuild and strobes the tip.
    packQueued[tooltip] = nil
    ForEachLine(tooltip, function(_, left, right)
        if left then sourceOf[left] = nil end
        if right then sourceOf[right] = nil end
    end)
end

local function IsGameTooltip(frame)
    if type(frame) ~= "table" or tracked[frame] then return false end
    if frame.IsForbidden then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if ok and forbidden then return false end
    end
    if not frame.GetObjectType then return false end
    local ok, kind = pcall(frame.GetObjectType, frame)
    return ok and kind == "GameTooltip"
end

local function OnScreen(tooltip)
    local alpha = Metric(tooltip, "GetAlpha")
    if alpha and alpha < 0.05 then return false end
    local left, right = Metric(tooltip, "GetLeft"), Metric(tooltip, "GetRight")
    local top, bottom = Metric(tooltip, "GetTop"), Metric(tooltip, "GetBottom")
    if not (left and right and top and bottom) then return true end
    local uiRight = Metric(UIParent, "GetRight") or 0
    local uiTop = Metric(UIParent, "GetTop") or 0
    if right < 0 or bottom > uiTop or left > uiRight or top < 0 then return false end
    if left < -2000 or bottom < -2000 then return false end
    return true
end

local function Collect(left, right, includeGame, includeHidden)
    local out = {}
    local function add(fs)
        if not Shown(fs) then return end
        local src = sourceOf[fs]
        local addon = src and src.addon or "Game"
        if not includeGame and IsClient(addon) then return end
        if not includeHidden and IsHidden(addon) then return end
        local detail = src and src.detail
        local last = out[#out]
        if last and last.addon == addon and last.detail == detail then return end
        out[#out + 1] = { addon = addon, detail = detail }
    end
    add(left)
    add(right)
    return out
end

local function FormatSources(sources, withFile, markHidden)
    local names, details = {}, {}
    for _, src in ipairs(sources) do
        local name = Colored(src.addon)
        if markHidden and IsHidden(src.addon) then
            name = name .. " |cff777777(hidden)|r"
        end
        names[#names + 1] = name
        if src.detail then details[#details + 1] = src.detail end
    end
    local text = table.concat(names, "  |cff777777/|r  ")
    if withFile and #details > 0 then
        text = text .. "  |cff9a9a9a" .. table.concat(details, " / ") .. "|r"
    end
    return text
end

local function MakeOverlay(tooltip)
    local overlay = CreateFrame("Frame", nil, UIParent)
    overlay:SetFrameStrata("TOOLTIP")
    overlay:EnableMouse(false)
    overlay.rows = {}

    local border = overlay:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(0.18, 0.18, 0.18, 0.95)

    local fill = overlay:CreateTexture(nil, "BORDER")
    fill:SetAllPoints()
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetVertexColor(0.04, 0.04, 0.04, 0.92)

    overlay:Hide()
    overlays[tooltip] = overlay
    return overlay
end

local function Row(overlay, index)
    local row = overlay.rows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, overlay)
    row:EnableMouse(false)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetAllPoints()
    if row.text.SetWordWrap then row.text:SetWordWrap(false) end
    row.text:SetShadowColor(0, 0, 0, 1)
    row.text:SetShadowOffset(1, -1)
    overlay.rows[index] = row
    return row
end

local function SideBlocked(tooltip, width, direction)
    local tipLeft, tipRight = Metric(tooltip, "GetLeft"), Metric(tooltip, "GetRight")
    if not tipLeft or not tipRight then return false end
    for _, other in pairs(tracked) do
        if other ~= tooltip and Flag(other, "IsShown") then
            local left, right = Metric(other, "GetLeft"), Metric(other, "GetRight")
            if left and right then
                if direction == "right" and left >= tipRight - 8 and left < tipRight + width + 12 then
                    return true
                end
                if direction == "left" and right <= tipLeft + 8 and right > tipLeft - width - 12 then
                    return true
                end
            end
        end
    end
    return false
end

local function ShouldPlaceRight(tooltip, width)
    local uiRight = Metric(UIParent, "GetRight") or 0
    local tipRight = Metric(tooltip, "GetRight")
    local tipLeft = Metric(tooltip, "GetLeft")
    if not tipRight or not tipLeft then return true end
    local need = width + 10
    local rightFree = (uiRight - tipRight) >= need and not SideBlocked(tooltip, width, "right")
    if rightFree then return true end
    local leftFree = tipLeft >= need and not SideBlocked(tooltip, width, "left")
    if leftFree then return false end
    return (uiRight - tipRight) >= tipLeft
end

local function Refresh(tooltip)
    local overlay = overlays[tooltip] or MakeOverlay(tooltip)
    if not Flag(tooltip, "IsShown") or not OnScreen(tooltip) then
        overlay:Hide()
        return
    end
    InstallHooks(tooltip)

    -- Labels can be off while the blocked-addon filter keeps running.
    -- Do not QueuePack here — OnShow/OnUpdate would re-enter every layout tick.
    if not db.enabled then
        overlay:Hide()
        return
    end

    local entries = {}
    local maxWidth = 40
    ForEachLine(tooltip, function(_, left, right)
        local anchor = Shown(left) and left or (Shown(right) and right or nil)
        if not anchor then return end
        local sources = Collect(left, right, db.showGame)
        if #sources == 0 then return end
        local mid, height = CenterOf(anchor)
        if not mid then return end
        local row = Row(overlay, #entries + 1)
        row.text:SetText(FormatSources(sources, db.showFile))
        local width = Metric(row.text, "GetStringWidth") or 0
        if width > maxWidth then maxWidth = width end
        entries[#entries + 1] = { mid = mid, height = height or 12 }
    end)

    if #entries == 0 then
        overlay:Hide()
        return
    end

    local padX, padY = 6, 3
    local width = maxWidth + padX * 2
    local placeRight = ShouldPlaceRight(tooltip, width)

    local tipTop = Metric(tooltip, "GetTop")
    if not tipTop then
        overlay:Hide()
        return
    end

    local topEdge, botEdge
    for _, entry in ipairs(entries) do
        local half = math.max(entry.height, 12) / 2
        local top = entry.mid + half
        local bot = entry.mid - half
        topEdge = topEdge and math.max(topEdge, top) or top
        botEdge = botEdge and math.min(botEdge, bot) or bot
    end

    local level = (Metric(tooltip, "GetFrameLevel") or 0) + 20
    if level > 65535 then level = 65535 end
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetFrameLevel(level)
    overlay:SetWidth(width)
    overlay:SetHeight((topEdge - botEdge) + padY * 2)
    overlay:ClearAllPoints()
    local y = topEdge + padY - tipTop
    if placeRight then
        overlay:SetPoint("TOPLEFT", tooltip, "TOPRIGHT", 4, y)
    else
        overlay:SetPoint("TOPRIGHT", tooltip, "TOPLEFT", -4, y)
    end

    local justify = placeRight and "LEFT" or "RIGHT"
    local overlayTop = topEdge + padY
    for i, entry in ipairs(entries) do
        local row = overlay.rows[i]
        local rowH = math.max(entry.height or 12, 12)
        row:SetHeight(rowH)
        row.text:SetJustifyH(justify)
        row.text:SetJustifyV("MIDDLE")
        row:ClearAllPoints()
        local rowTop = entry.mid + rowH / 2
        row:SetPoint("TOPLEFT", overlay, "TOPLEFT", padX, rowTop - overlayTop)
        row:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -padX, rowTop - overlayTop)
        row:Show()
    end
    for i = #entries + 1, #overlay.rows do
        overlay.rows[i]:Hide()
    end
    overlay:Show()
end

local function SafeRefresh(tooltip)
    local ok, err = pcall(Refresh, tooltip)
    if not ok and not errorOnce then
        errorOnce = true
        Say("|cffff8888couldn't draw labels:|r " .. tostring(err))
    end
end

local function RefreshShown()
    for tooltip in pairs(tracked) do
        if Flag(tooltip, "IsShown") then
            SafeRefresh(tooltip)
        else
            local overlay = overlays[tooltip]
            if overlay then overlay:Hide() end
        end
    end
end

local function Track(tooltip)
    if not IsGameTooltip(tooltip) then return end
    tracked[tooltip] = tooltip
    local ok, err = pcall(function()
        InstallHooks(tooltip)
        tooltip:HookScript("OnShow", function(self) SafeRefresh(self) end)
        tooltip:HookScript("OnHide", function(self)
            packedOnce[self] = nil
            fitHold[self] = nil
            packQueued[self] = nil
            local overlay = overlays[self]
            if overlay then overlay:Hide() end
        end)
        tooltip:HookScript("OnUpdate", function(self)
            if fitHold[self] and Flag(self, "IsShown") then
                packing = true
                pcall(FitPackedTooltip, self)
                packing = false
            end
            if db.enabled and Flag(self, "IsShown") then SafeRefresh(self) end
        end)
    end)
    if not ok and not errorOnce then
        errorOnce = true
        Say("|cffff8888couldn't watch a tooltip:|r " .. tostring(err))
    end
end

local function ScanChildren(frame, depth)
    if type(frame) ~= "table" or depth > 2 then return end
    if frame.IsForbidden then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if ok and forbidden then return end
    end
    if IsGameTooltip(frame) then Track(frame) end
    if not frame.GetChildren then return end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if not ok or type(children) ~= "table" then return end
    for _, child in ipairs(children) do
        ScanChildren(child, depth + 1)
    end
end

local function ScanGlobals()
    local names = {
        "GameTooltip", "ItemRefTooltip",
        "ShoppingTooltip1", "ShoppingTooltip2", "ShoppingTooltip3",
        "WorldMapTooltip", "WorldMapCompareTooltip1", "WorldMapCompareTooltip2",
        "EmbeddedItemTooltip", "SmallTextTooltip",
    }
    for _, name in ipairs(names) do
        if IsGameTooltip(_G[name]) then Track(_G[name]) end
    end
    if type(EmbeddedItemTooltip) == "table" and IsGameTooltip(EmbeddedItemTooltip.Tooltip) then
        Track(EmbeddedItemTooltip.Tooltip)
    end
    if type(GameTooltip) == "table" and type(GameTooltip.shoppingTooltips) == "table" then
        for _, tip in ipairs(GameTooltip.shoppingTooltips) do
            if IsGameTooltip(tip) then Track(tip) end
        end
    end
    for key, value in pairs(_G) do
        if type(key) == "string" and type(value) == "table" and key:find("Tooltip") then
            if IsGameTooltip(value) then Track(value) end
        end
    end
    if UIParent then ScanChildren(UIParent, 0) end
end

local function Dump(tooltip)
    if not tooltip or not Flag(tooltip, "IsShown") then
        Say("Hover something first, then run /ttr list.")
        return
    end
    local any = false
    ForEachLine(tooltip, function(i, left, right)
        if not Shown(left) and not Shown(right) then return end
        any = true
        local sources = Collect(left, right, true, true)
        if #sources == 0 then
            Say(i .. "  " .. Colored("Game"))
        else
            Say(i .. "  " .. FormatSources(sources, true, true))
        end
    end)
    if not any then Say("That tooltip has no text lines.") end
end

local function Status()
    Say(string.format("%s. Client lines %s. File names %s.",
        db.enabled and "|cff7dffa0on|r" or "|cffff8888off|r",
        db.showGame and "shown" or "hidden",
        db.showFile and "shown" or "hidden"))
end

local function Help()
    Say("|cffdddddd/ttr|r  toggle the labels")
    Say("|cffdddddd/ttr options|r  open the options menu")
    Say("|cffdddddd/ttr game|r  also name lines that come from the game client")
    Say("|cffdddddd/ttr file|r  add the file and line that wrote each one")
    Say("|cffdddddd/ttr list|r  print sources for the tooltip under the cursor")
end

-- Canvas options, same registration path and Waypoint-style chrome as TyGear.
local InterfaceOptions_AddCategory = InterfaceOptions_AddCategory or function(frame)
    frame.OnCommit = frame.okay
    frame.OnDefault = frame.default
    frame.OnRefresh = frame.refresh
    if frame.parent then
        local category = Settings.GetCategory(frame.parent)
        return Settings.RegisterCanvasLayoutSubcategory(category, frame, frame.name)
    end
    local category = Settings.RegisterCanvasLayoutCategory(frame, frame.name, frame.name)
    Settings.RegisterAddOnCategory(category)
    return category
end

local optionChecks = {}
local optionsCategory, optionsPanel

local function SetOption(key, value)
    db[key] = value and true or false
    local check = optionChecks[key]
    if check and check.SetChecked then
        check:SetChecked(db[key])
    end
    RefreshShown()
end

local function ApplySectionBlockBackdrop(frame)
    frame:SetBackdrop({
        bgFile = "Interface/ChatFrame/ChatFrameBackground",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.11, 0.11, 0.12, 0.92)
    frame:SetBackdropBorderColor(0.48, 0.48, 0.48, 0.95)
end

local function HookBlockRowHoverChild(row, frame)
    local highlight = row and row.ttrHoverHighlight
    if not highlight or not frame or not frame.HookScript then return end
    frame:HookScript("OnEnter", function()
        highlight:Show()
    end)
    frame:HookScript("OnLeave", function()
        if row:IsMouseOver() then return end
        highlight:Hide()
    end)
end

local function AttachBlockRowHover(row, ...)
    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    if highlight.SetColorTexture then
        highlight:SetColorTexture(1, 1, 1, 0.12)
    else
        highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
        highlight:SetVertexColor(1, 1, 1, 0.12)
    end
    highlight:Hide()
    row.ttrHoverHighlight = highlight

    row:EnableMouse(true)
    row:HookScript("OnEnter", function() highlight:Show() end)
    row:HookScript("OnLeave", function()
        if row:IsMouseOver() then return end
        highlight:Hide()
    end)
    for i = 1, select("#", ...) do
        HookBlockRowHoverChild(row, select(i, ...))
    end
end

local function CreateInfoButton(parent, title, description)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(18, 18)
    btn:EnableMouse(true)
    btn:SetBackdrop({
        bgFile = "Interface/ChatFrame/ChatFrameBackground",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    btn:SetBackdropColor(0.12, 0.12, 0.14, 0.95)
    btn:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.95)

    local mark = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mark:SetPoint("CENTER", 0, 0)
    mark:SetText("i")

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.85, 0.75, 0.35, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b, true)
        if description and description ~= "" then
            GameTooltip:AddLine(description, HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.55, 0.55, 0.55, 0.95)
        GameTooltip:Hide()
    end)
    return btn
end

local function NewBlockSettingRow(parent, key, label, description)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(500, 28)

    local check = CreateFrame("CheckButton", "TooltipReclaimer" .. key .. "CheckButton", row, "InterfaceOptionsCheckButtonTemplate")
    check:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    local templateText = _G[check:GetName() .. "Text"]
    if templateText then
        templateText:SetText("")
        templateText:Hide()
    end
    check:SetHitRectInsets(0, 0, 0, 0)
    check:SetChecked(db[key] and true or false)
    check:SetScript("OnClick", function(self)
        local tick = self:GetChecked()
        SetOption(key, tick and true or false)
        if tick then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        else
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end
    end)
    optionChecks[key] = check

    local info
    if description and description ~= "" then
        info = CreateInfoButton(row, label, description)
    end

    local title = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(label)

    if info then
        info:SetPoint("RIGHT", check, "LEFT", -6, 0)
        title:SetPoint("LEFT", 4, 0)
        title:SetPoint("RIGHT", info, "LEFT", -8, 0)
    else
        title:SetPoint("LEFT", 4, 0)
        title:SetPoint("RIGHT", check, "LEFT", -14, 0)
    end

    AttachBlockRowHover(row, check, info)
    row:SetScript("OnMouseUp", function(_, button)
        if button and button ~= "LeftButton" then return end
        if not check:IsEnabled() then return end
        if check.IsMouseOver and check:IsMouseOver() then return end
        if info and info.IsMouseOver and info:IsMouseOver() then return end
        check:Click()
    end)

    return row
end

local hookRowSerial = 0

local function NewAddonRow(parent, addon, shown, onToggle)
    hookRowSerial = hookRowSerial + 1
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(500, 28)
    row.addon = addon

    local check = CreateFrame("CheckButton", "TooltipReclaimerHook" .. hookRowSerial .. "CheckButton", row, "InterfaceOptionsCheckButtonTemplate")
    check:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    local templateText = _G[check:GetName() .. "Text"]
    if templateText then
        templateText:SetText("")
        templateText:Hide()
    end
    check:SetHitRectInsets(0, 0, 0, 0)
    check:SetChecked(shown and true or false)
    check:SetScript("OnClick", function(self)
        local tick = self:GetChecked() and true or false
        onToggle(addon, tick)
        if tick then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        else
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end
    end)
    row.check = check

    local title = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(Colored(addon))
    row.title = title

    local file = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    file:SetJustifyH("LEFT")
    file:SetJustifyV("TOP")
    file:SetWordWrap(true)
    file:SetTextColor(0.62, 0.62, 0.62)
    row.file = file

    function row:Reflow()
        local text = FileLabel(self.addon)
        self.title:ClearAllPoints()
        self.file:ClearAllPoints()
        if text == "" then
            self.file:SetText("")
            self.file:Hide()
            self.title:SetPoint("LEFT", 4, 0)
            self.title:SetPoint("RIGHT", self.check, "LEFT", -14, 0)
            self:SetHeight(28)
            return
        end
        self.file:Show()
        self.file:SetText(text)
        self.title:SetPoint("TOPLEFT", 4, -5)
        self.title:SetPoint("TOPRIGHT", self.check, "LEFT", -14, -5)
        self.file:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -1)
        self.file:SetPoint("RIGHT", self.check, "LEFT", -14, 0)
        local height = Metric(self.file, "GetStringHeight") or 12
        self:SetHeight(math.max(40, 8 + 16 + height))
    end
    row:Reflow()

    AttachBlockRowHover(row, check)
    row:SetScript("OnMouseUp", function(_, button)
        if button and button ~= "LeftButton" then return end
        if not check:IsEnabled() then return end
        if check.IsMouseOver and check:IsMouseOver() then return end
        check:Click()
    end)

    return row
end

local function RegisterOptions()
    if not (_G.InterfaceOptions_AddCategory
        or (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory)) then
        return
    end

    local PAGE_PAD, BLOCK_PAD, BLOCK_ROW_GAP = 12, 12, 6
    local BLOCK_INSET, RIGHT_MARGIN = 8, 36

    local panel = CreateFrame("Frame", "TooltipReclaimerOptionsMenu")
    panel:SetWidth(1)
    panel:SetHeight(1)

    local scroll = CreateFrame("ScrollFrame", "TooltipReclaimerOptionsScrollFrame", nil, "UIPanelScrollFrameTemplate")
    scroll.name = "TooltipReclaimer"
    scroll:SetScrollChild(panel)

    local scrollBar = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
    if scrollBar then
        local function anchorBar()
            scrollBar:ClearAllPoints()
            scrollBar:SetWidth(18)
            scrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", -28, -18)
            scrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", -28, 18)
        end
        anchorBar()
        scroll:HookScript("OnShow", anchorBar)
        scroll:HookScript("OnSizeChanged", anchorBar)
    end

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 8, -8)
    title:SetText("TooltipReclaimer")

    local credit = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    credit:SetPoint("TOPLEFT", 8, -28)
    credit:SetJustifyH("LEFT")
    credit:SetText("Names the addon that added each tooltip line.")

    local container = CreateFrame("Frame", "TooltipReclaimerOptionsContainer", panel, "BackdropTemplate")
    container:SetBackdrop({
        bgFile = "Interface/ChatFrame/ChatFrameBackground",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    container:SetBackdropColor(0.1, 0.1, 0.1, 0.3)
    container:SetBackdropBorderColor(0.5, 0.5, 0.5)
    container:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -46)

    local page = CreateFrame("Frame", nil, container)
    page:SetPoint("TOPLEFT", container, "TOPLEFT", PAGE_PAD, -PAGE_PAD)
    page:SetPoint("TOPRIGHT", container, "TOPRIGHT", -PAGE_PAD, -PAGE_PAD)

    local header = CreateFrame("Frame", nil, page)
    header:SetSize(400, 20)
    header:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    local headerText = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    headerText:SetPoint("BOTTOMLEFT", 4, 2)
    headerText:SetText("Labels")

    local block = CreateFrame("Frame", nil, page, "BackdropTemplate")
    ApplySectionBlockBackdrop(block)
    block:SetPoint("TOPLEFT", header, "BOTTOMLEFT", BLOCK_INSET, -6)

    local rows = {
        NewBlockSettingRow(block, "enabled", "Show source labels",
            "Name the addon that added each tooltip line. Labels sit beside the tooltip."),
        NewBlockSettingRow(block, "showGame", "Show client lines",
            "Also label lines drawn by the game client (shown as Game / Blizzard)."),
        NewBlockSettingRow(block, "showFile", "Show file names",
            "Append the Lua/XML file and line that wrote each labeled source."),
    }

    local SECTION_GAP = 18
    local addonRows, addonOrder = {}, {}

    local addonHeader = CreateFrame("Frame", nil, page)
    addonHeader:SetSize(400, 20)
    local addonHeaderText = addonHeader:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    addonHeaderText:SetPoint("BOTTOMLEFT", 4, 2)
    addonHeaderText:SetText("Detected addon hooks")
    local addonInfo = CreateInfoButton(addonHeader, "Detected addon hooks",
        "Addons that have written a tooltip line, and the file the hook came from. Uncheck one to remove that addon's lines from tooltips. Check it again and hover once more to bring them back.")
    addonInfo:SetPoint("LEFT", addonHeaderText, "RIGHT", 6, 0)

    local addonBlock = CreateFrame("Frame", nil, page, "BackdropTemplate")
    ApplySectionBlockBackdrop(addonBlock)

    local empty = CreateFrame("Frame", nil, addonBlock)
    empty:SetHeight(36)
    local emptyText = empty:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    emptyText:SetPoint("LEFT", 4, 0)
    emptyText:SetPoint("RIGHT", -4, 0)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetJustifyV("MIDDLE")
    emptyText:SetWordWrap(true)
    emptyText:SetTextColor(0.62, 0.62, 0.62)
    emptyText:SetText("None yet. Hover a tooltip and the hooks that write to it show up here.")

    local function SetAddonShown(addon, shown)
        if type(db.hidden) ~= "table" then db.hidden = {} end
        if shown then
            db.hidden[addon] = nil
        else
            db.hidden[addon] = true
        end
        local row = addonRows[addon]
        if row and row.check then
            row.check:SetChecked(shown and true or false)
        end
        if not shown then
            for tooltip in pairs(tracked) do
                if Flag(tooltip, "IsShown") then
                    packedOnce[tooltip] = nil
                    PackTooltip(tooltip, true)
                end
            end
        end
        RefreshShown()
    end

    local function SyncAddonRows()
        local names = {}
        if type(db.seen) == "table" then
            for name in pairs(db.seen) do
                if type(name) == "string" and IsPlayer(name) then
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names, function(a, b)
            local al, bl = a:lower(), b:lower()
            if al == bl then return a < b end
            return al < bl
        end)
        addonOrder = names
        for _, name in ipairs(names) do
            local row = addonRows[name]
            if not row then
                row = NewAddonRow(addonBlock, name, not IsHidden(name), SetAddonShown)
                addonRows[name] = row
            else
                row.check:SetChecked(not IsHidden(name))
                row:Reflow()
            end
        end
    end

    local function Layout()
        local width = math.max((scroll:GetWidth() or 0) - RIGHT_MARGIN, 1)
        panel:SetWidth(width + 8)
        local inner = math.max(width - PAGE_PAD * 2 - BLOCK_INSET, 1)
        local blockWidth = math.max(inner - BLOCK_INSET, 1)
        block:SetWidth(blockWidth)
        addonBlock:SetWidth(blockWidth)

        local y = BLOCK_PAD
        for i, row in ipairs(rows) do
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", block, "TOPLEFT", BLOCK_PAD, -y)
            row:SetPoint("TOPRIGHT", block, "TOPRIGHT", -BLOCK_PAD, -y)
            y = y + (row:GetHeight() or 28) + (i < #rows and BLOCK_ROW_GAP or 0)
        end
        block:SetHeight(y + BLOCK_PAD)

        addonHeader:ClearAllPoints()
        addonHeader:SetPoint("TOPLEFT", block, "BOTTOMLEFT", -BLOCK_INSET, -SECTION_GAP)
        addonBlock:ClearAllPoints()
        addonBlock:SetPoint("TOPLEFT", addonHeader, "BOTTOMLEFT", BLOCK_INSET, -6)

        local ay = BLOCK_PAD
        if #addonOrder == 0 then
            empty:Show()
            empty:ClearAllPoints()
            empty:SetPoint("TOPLEFT", addonBlock, "TOPLEFT", BLOCK_PAD, -ay)
            empty:SetPoint("TOPRIGHT", addonBlock, "TOPRIGHT", -BLOCK_PAD, -ay)
            ay = ay + (empty:GetHeight() or 36)
        else
            empty:Hide()
            for i, name in ipairs(addonOrder) do
                local row = addonRows[name]
                row:Show()
                row:SetWidth(math.max(addonBlock:GetWidth() - BLOCK_PAD * 2, 1))
                row:Reflow()
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", addonBlock, "TOPLEFT", BLOCK_PAD, -ay)
                row:SetPoint("TOPRIGHT", addonBlock, "TOPRIGHT", -BLOCK_PAD, -ay)
                ay = ay + (row:GetHeight() or 28) + (i < #addonOrder and BLOCK_ROW_GAP or 0)
            end
        end
        addonBlock:SetHeight(ay + BLOCK_PAD)

        local pageHeight = 20 + 6 + block:GetHeight()
            + SECTION_GAP + 20 + 6 + addonBlock:GetHeight()
            + PAGE_PAD
        page:SetHeight(pageHeight)
        container:SetWidth(width)
        container:SetHeight(pageHeight + PAGE_PAD)
        panel:SetHeight(46 + container:GetHeight() + 16)
    end

    local function RefreshChecks()
        for key, check in pairs(optionChecks) do
            check:SetChecked(db[key] and true or false)
        end
        for name, row in pairs(addonRows) do
            if row.check then
                row.check:SetChecked(not IsHidden(name))
            end
        end
    end

    onAddonSeen = function()
        SyncAddonRows()
        Layout()
    end
    SyncAddonRows()

    scroll:HookScript("OnShow", function()
        RefreshChecks()
        Layout()
    end)
    scroll:HookScript("OnSizeChanged", Layout)
    panel:HookScript("OnShow", function()
        RefreshChecks()
        Layout()
    end)

    optionsPanel = scroll
    optionsCategory = InterfaceOptions_AddCategory(scroll)
    Layout()
end

local function CategoryID()
    if optionsCategory and optionsCategory.GetID then
        local ok, id = pcall(optionsCategory.GetID, optionsCategory)
        if ok and id then return id end
    end
    if not (SettingsPanel and SettingsPanel.GetAllCategories and optionsPanel) then return end
    local ok, categories = pcall(SettingsPanel.GetAllCategories, SettingsPanel)
    if not ok or type(categories) ~= "table" then return end
    for _, category in pairs(categories) do
        if category.name == optionsPanel.name and category.GetID then
            local idOk, id = pcall(category.GetID, category)
            if idOk and id then return id end
        end
    end
end

local function OpenOptions()
    if InCombatLockdown and InCombatLockdown() then
        Say("The options menu can't be opened in combat.")
        return
    end
    if not optionsPanel then
        Say("Options aren't ready yet.")
        return
    end
    if Settings and Settings.OpenToCategory then
        local id = CategoryID()
        if id and pcall(Settings.OpenToCategory, id) then return end
        if optionsPanel.name and pcall(Settings.OpenToCategory, optionsPanel.name) then return end
    end
    if InterfaceOptionsFrame_OpenToCategory then
        -- The first call only selects the category on some clients.
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        return
    end
    Say("Open |cffddddddEsc > Options > AddOns > TooltipReclaimer|r.")
end

SLASH_TOOLTIPRECLAIMER1 = "/ttr"
SLASH_TOOLTIPRECLAIMER2 = "/tooltipreclaimer"
SlashCmdList.TOOLTIPRECLAIMER = function(msg)
    LoadDB()
    msg = (msg or ""):lower():match("^%s*(.-)%s*$") or ""
    if msg == "" or msg == "toggle" then
        SetOption("enabled", not db.enabled)
        Status()
    elseif msg == "on" then
        SetOption("enabled", true)
        Status()
    elseif msg == "off" then
        SetOption("enabled", false)
        Status()
    elseif msg == "options" or msg == "option" or msg == "config" then
        OpenOptions()
        return
    elseif msg == "game" then
        SetOption("showGame", not db.showGame)
        Status()
    elseif msg == "file" then
        SetOption("showFile", not db.showFile)
        Status()
    elseif msg == "list" or msg == "dump" or msg == "where" then
        Dump(GameTooltip)
        return
    elseif msg == "status" then
        Status()
        return
    else
        Help()
        return
    end
end

local catchQueued, pendingTips = false, {}

local function CatchNewTooltips()
    catchQueued = false
    local batch = pendingTips
    pendingTips = {}
    for _, item in ipairs(batch) do
        local name, parent = item[1], item[2]
        if type(name) == "string" and IsGameTooltip(_G[name]) then
            Track(_G[name])
        end
        if type(parent) == "string" then parent = _G[parent] end
        if type(parent) == "table" and parent.GetChildren then
            local ok, children = pcall(function() return { parent:GetChildren() } end)
            if ok and type(children) == "table" then
                for _, child in ipairs(children) do
                    if IsGameTooltip(child) then Track(child) end
                end
            end
        end
    end
end

if type(hooksecurefunc) == "function" then
    hooksecurefunc("CreateFrame", function(kind, name, parent)
        if kind ~= "GameTooltip" then return end
        pendingTips[#pendingTips + 1] = { name, parent }
        if catchQueued then return end
        catchQueued = true
        if C_Timer and C_Timer.After then
            C_Timer.After(0, CatchNewTooltips)
        else
            CatchNewTooltips()
        end
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        LoadDB()
        RegisterOptions()
        ScanGlobals()
        return
    end
    if event == "PLAYER_LOGIN" then
        LoadDB()
        ScanGlobals()
        if db.enabled then
            Say("On. Labels sit beside the tooltip. |cffc7c7c7/ttr options|r opens the menu.")
        end
    end
end)

ScanGlobals()
