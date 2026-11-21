-- Names the addon behind each line of a tooltip.
--
-- AddLine, AddDoubleLine, and the line fontstrings' SetText are hooked, and
-- the calling file is read from debugstack. Lines drawn by the client are
-- "Game" and stay hidden unless /ttr game is on. The labels are a separate
-- frame, so the tooltip text itself is never rewritten.

local ADDON = ...
local SELF = "TooltipReclaimer"
local MAX_LINES = 200

local db = {
    enabled = true,
    showGame = false,
    showFile = false,
}

local sourceOf = setmetatable({}, { __mode = "k" })
local tracked = {}
local hookedMethods = setmetatable({}, { __mode = "k" })
local hookedFonts = setmetatable({}, { __mode = "k" })
local overlays = {}
local errorOnce

local Remember

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
    if not fs or not fs.IsShown then return false end
    local ok, shown = pcall(fs.IsShown, fs)
    if not ok or not shown then return false end
    local okW, width = pcall(fs.GetStringWidth, fs)
    return okW and type(width) == "number" and width > 1
end

local function CenterOf(fs)
    local okT, top = pcall(fs.GetTop, fs)
    local okB, bottom = pcall(fs.GetBottom, fs)
    if not (okT and okB and type(top) == "number" and type(bottom) == "number") then
        return nil
    end
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
            if not db.enabled then return end
            local addon, detail = Caller()
            Remember(self, addon, detail, false)
        end)
        state[method] = fs[method]
    end
    hook("SetText")
    hook("SetFormattedText")
end

-- upgradeOnly fills a line AddLine created before its fontstring was hooked.
-- A later SetText (upgradeOnly false) is the real writer and replaces it.
Remember = function(fs, addon, detail, upgradeOnly)
    if not fs or not addon then return end
    HookFontString(fs)
    local prev = sourceOf[fs]
    if upgradeOnly and prev and (IsPlayer(prev.addon) or not IsPlayer(addon)) then
        return
    end
    sourceOf[fs] = { addon = addon, detail = detail }
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
    if not db.enabled then return end
    local addon, detail = Caller()
    local ok, count = pcall(tooltip.NumLines, tooltip)
    if not ok or type(count) ~= "number" or count < 1 then return end
    Remember(FontString(tooltip, "TextLeft", count), addon, detail, true)
    if isDouble then
        Remember(FontString(tooltip, "TextRight", count), addon, detail, true)
    end
    InstallHooks(tooltip)
end

ClearSources = function(tooltip)
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
    local okA, alpha = pcall(tooltip.GetAlpha, tooltip)
    if okA and type(alpha) == "number" and alpha < 0.05 then return false end
    local okL, left = pcall(tooltip.GetLeft, tooltip)
    local okR, right = pcall(tooltip.GetRight, tooltip)
    local okT, top = pcall(tooltip.GetTop, tooltip)
    local okB, bottom = pcall(tooltip.GetBottom, tooltip)
    if not (okL and okR and okT and okB) then return false end
    if type(left) ~= "number" or type(right) ~= "number"
        or type(top) ~= "number" or type(bottom) ~= "number" then
        return false
    end
    local uiRight = UIParent:GetRight() or 0
    local uiTop = UIParent:GetTop() or 0
    if right < 0 or bottom > uiTop or left > uiRight or top < 0 then return false end
    if left < -2000 or bottom < -2000 then return false end
    return true
end

local function Collect(left, right, includeGame)
    local out = {}
    local function add(fs)
        if not Shown(fs) then return end
        local src = sourceOf[fs]
        local addon = src and src.addon or "Game"
        if not includeGame and IsClient(addon) then return end
        local detail = src and src.detail
        local last = out[#out]
        if last and last.addon == addon and last.detail == detail then return end
        out[#out + 1] = { addon = addon, detail = detail }
    end
    add(left)
    add(right)
    return out
end

local function FormatSources(sources, withFile)
    local names, details = {}, {}
    for _, src in ipairs(sources) do
        names[#names + 1] = Colored(src.addon)
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
    local okL, tipLeft = pcall(tooltip.GetLeft, tooltip)
    local okR, tipRight = pcall(tooltip.GetRight, tooltip)
    if not (okL and okR and type(tipLeft) == "number" and type(tipRight) == "number") then
        return false
    end
    for _, other in pairs(tracked) do
        if other ~= tooltip then
            local okS, shown = pcall(other.IsShown, other)
            if okS and shown then
                local okOL, left = pcall(other.GetLeft, other)
                local okOR, right = pcall(other.GetRight, other)
                if okOL and okOR and type(left) == "number" and type(right) == "number" then
                    if direction == "right" and left >= tipRight - 8 and left < tipRight + width + 12 then
                        return true
                    end
                    if direction == "left" and right <= tipLeft + 8 and right > tipLeft - width - 12 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function ShouldPlaceRight(tooltip, width)
    local uiRight = UIParent:GetRight() or 0
    local tipRight = tooltip:GetRight() or 0
    local tipLeft = tooltip:GetLeft() or 0
    local need = width + 10
    local rightFree = (uiRight - tipRight) >= need and not SideBlocked(tooltip, width, "right")
    if rightFree then return true end
    local leftFree = tipLeft >= need and not SideBlocked(tooltip, width, "left")
    if leftFree then return false end
    return (uiRight - tipRight) >= tipLeft
end

local function Refresh(tooltip)
    local overlay = overlays[tooltip] or MakeOverlay(tooltip)
    if not db.enabled or not tooltip:IsShown() or not OnScreen(tooltip) then
        overlay:Hide()
        return
    end
    InstallHooks(tooltip)

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
        local width = row.text:GetStringWidth() or 0
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

    local okTop, tipTop = pcall(tooltip.GetTop, tooltip)
    if not okTop or type(tipTop) ~= "number" then
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

    local okLevel, level = pcall(tooltip.GetFrameLevel, tooltip)
    level = (okLevel and type(level) == "number" and level or 0) + 20
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
        if tooltip:IsShown() then
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
            local overlay = overlays[self]
            if overlay then overlay:Hide() end
        end)
        tooltip:HookScript("OnUpdate", function(self)
            if db.enabled and self:IsShown() then SafeRefresh(self) end
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
    if not tooltip or not tooltip.IsShown or not tooltip:IsShown() then
        Say("Hover something first, then run /ttr list.")
        return
    end
    local any = false
    ForEachLine(tooltip, function(i, left, right)
        if not Shown(left) and not Shown(right) then return end
        any = true
        local sources = Collect(left, right, true)
        if #sources == 0 then
            Say(i .. "  " .. Colored("Game"))
        else
            Say(i .. "  " .. FormatSources(sources, true))
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
    Say("|cffdddddd/ttr game|r  also name lines that come from the game client")
    Say("|cffdddddd/ttr file|r  add the file and line that wrote each one")
    Say("|cffdddddd/ttr list|r  print sources for the tooltip under the cursor")
end

SLASH_TOOLTIPRECLAIMER1 = "/ttr"
SLASH_TOOLTIPRECLAIMER2 = "/tooltipreclaimer"
SlashCmdList.TOOLTIPRECLAIMER = function(msg)
    LoadDB()
    msg = (msg or ""):lower():match("^%s*(.-)%s*$") or ""
    if msg == "" or msg == "toggle" then
        db.enabled = not db.enabled
        Status()
    elseif msg == "on" then
        db.enabled = true
        Status()
    elseif msg == "off" then
        db.enabled = false
        Status()
    elseif msg == "game" then
        db.showGame = not db.showGame
        Status()
    elseif msg == "file" then
        db.showFile = not db.showFile
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
    RefreshShown()
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
    if event == "ADDON_LOADED" and name ~= ADDON then return end
    LoadDB()
    ScanGlobals()
    if event == "PLAYER_LOGIN" and db.enabled then
        Say("On. Labels sit beside the tooltip. |cffc7c7c7/ttr|r toggles them, |cffc7c7c7/ttr list|r prints this one.")
    end
end)

ScanGlobals()
