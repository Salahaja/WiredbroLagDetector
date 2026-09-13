--[[
    wow_stub.lua - just enough of WoW 1.12's Lua environment to load an addon
    on a desktop Lua and actually exercise its logic.

    This is not an emulator. It implements the parts this addon's behaviour
    depends on and nothing else:

      * The Lua 5.0 standard library pieces a modern Lua removed
        (string.gfind, table.getn, math.mod), so addon code written for
        1.12 runs unmodified.
      * A frame mock with REAL anchor geometry - SetPoint/ClearAllPoints/
        GetPoint/GetLeft/GetTop resolve through the anchor chain the way the
        client does, including frames anchored to other frames. That's the
        part that matters: this addon's whole job is moving frames around and
        reading where they ended up, so a mock where GetTop() is a stub
        would test nothing.
      * A roster, so UnitExists/UnitName answer for "party1".."party4",
        "raid1".."raid40" and "player".

    Anything else a frame gets asked to do resolves to a no-op that records
    its name in Stub.unknownCalls, so unrelated API surface doesn't break
    tests, but a typo is still discoverable.

    Load it with dofile() from the repo root; it returns the Stub table and
    installs the globals as a side effect.

    This file is addon-agnostic and is kept as an independent COPY in each
    addon repo that uses it, rather than shared from one place. That's
    deliberate: each addon ships and is cloned on its own, so a test harness
    that reached into a sibling repo would make a standalone addon only
    testable when some unrelated addon happened to be checked out next to it.
    If you change something here worth having elsewhere, copy it across by
    hand - there is no link between the copies.
--]]

local Stub = {}

-- ---------------------------------------------------------------------------
-- Lua 5.0 standard library shims (vanilla runs 5.0; desktop Lua is 5.4)
-- ---------------------------------------------------------------------------
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
math.mod = math.mod or function(a, b) return a % b end
unpack = unpack or table.unpack
loadstring = loadstring or load

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------
Stub.unknownCalls = {}

local UI_WIDTH, UI_HEIGHT = 1920, 1080

local function anchorEdgesY(point, top, bottom, height)
    -- Given a named anchor point and a frame's top/bottom, which y does that
    -- point sit at? (Used for the frame being anchored TO.)
    if string.find(point, "^TOP") then return top end
    if string.find(point, "^BOTTOM") then return bottom end
    return (top + bottom) / 2
end

local function anchorEdgesX(point, left, right)
    if string.find(point, "LEFT$") then return left end
    if string.find(point, "RIGHT$") then return right end
    return (left + right) / 2
end

local frameMethods = {}

function frameMethods:GetName() return self._name end
function frameMethods:GetParent() return self._parent end
function frameMethods:GetObjectType() return self._type end
function frameMethods:IsShown() return self._shown and true or false end
function frameMethods:IsVisible() return self._shown and true or false end
function frameMethods:Show() self._shown = true end
function frameMethods:Hide() self._shown = false end
function frameMethods:GetEffectiveScale() return 1 end
function frameMethods:GetScale() return 1 end
function frameMethods:GetWidth() return self._w end
function frameMethods:GetHeight() return self._h end
function frameMethods:SetWidth(w) self._w = w end
function frameMethods:SetHeight(h) self._h = h end
function frameMethods:GetFrameLevel() return self._level or 1 end
function frameMethods:SetFrameLevel(l) self._level = l end
function frameMethods:IsUserPlaced() return self._userPlaced and true or false end
function frameMethods:SetUserPlaced(v) self._userPlaced = v and true or false end

function frameMethods:ClearAllPoints()
    self._points = {}
end

function frameMethods:SetPoint(point, relativeTo, relPoint, x, y)
    -- The client accepts several argument shapes; the ones this addon uses
    -- are the full 5-argument form and (point, x, y). A string relativeTo is
    -- resolved by name, exactly as the client does.
    if type(relativeTo) == "string" then
        relativeTo = _G[relativeTo]
    end
    if type(relativeTo) == "number" then
        -- SetPoint(point, x, y)
        x, y, relativeTo, relPoint = relativeTo, relPoint, nil, point
    end
    if relPoint == nil then relPoint = point end

    -- Real SetPoint ADDS an anchor and only replaces one with the same point
    -- name. Reproducing that faithfully is the whole reason ClearAllPoints
    -- exists in this addon's code, so the mock must not quietly overwrite.
    for _, p in ipairs(self._points) do
        if p.point == point then
            p.relativeTo, p.relPoint, p.x, p.y = relativeTo, relPoint, x or 0, y or 0
            return
        end
    end
    table.insert(self._points, {
        point = point, relativeTo = relativeTo, relPoint = relPoint, x = x or 0, y = y or 0,
    })
end

function frameMethods:GetPoint(index)
    local p = self._points[index or 1]
    if not p then return nil end
    return p.point, p.relativeTo, p.relPoint, p.x, p.y
end

function frameMethods:GetNumPoints() return #self._points end

-- Resolves the frame's top edge through the anchor chain. Returns nil for a
-- frame that has no anchor and no explicitly seeded position - which is what
-- the client does for a frame that isn't laid out yet, and which this addon
-- has specific handling for.
function frameMethods:GetTop()
    local p = self._points[1]
    if not p then return self._baseTop end

    local rel = p.relativeTo or Stub.UIParent
    local relTop, relBottom
    if rel == Stub.UIParent then
        relTop, relBottom = UI_HEIGHT, 0
    else
        relTop = rel:GetTop()
        if not relTop then return nil end
        relBottom = relTop - rel:GetHeight()
    end

    local anchorY = anchorEdgesY(p.relPoint, relTop, relBottom) + p.y
    -- anchorY is where OUR point sits; convert that to our top edge.
    if string.find(p.point, "^TOP") then return anchorY end
    if string.find(p.point, "^BOTTOM") then return anchorY + self._h end
    return anchorY + self._h / 2
end

function frameMethods:GetLeft()
    local p = self._points[1]
    if not p then return self._baseLeft end

    local rel = p.relativeTo or Stub.UIParent
    local relLeft, relRight
    if rel == Stub.UIParent then
        relLeft, relRight = 0, UI_WIDTH
    else
        relLeft = rel:GetLeft()
        if not relLeft then return nil end
        relRight = relLeft + rel:GetWidth()
    end

    local anchorX = anchorEdgesX(p.relPoint, relLeft, relRight) + p.x
    if string.find(p.point, "LEFT$") then return anchorX end
    if string.find(p.point, "RIGHT$") then return anchorX - self._w end
    return anchorX - self._w / 2
end

function frameMethods:GetBottom()
    local t = self:GetTop()
    return t and (t - self._h) or nil
end

-- Text and mouse state are recorded rather than discarded: a label's text IS
-- the observable output of any addon that stamps numbers onto unit frames, and
-- whether the mouse is enabled is how a lock/unlock edit mode is verified.
function frameMethods:SetText(text) self._text = text end
function frameMethods:GetText() return self._text end
function frameMethods:EnableMouse(v) self._mouseEnabled = v and true or false end
function frameMethods:IsMouseEnabled() return self._mouseEnabled and true or false end
function frameMethods:GetFont() return "Fonts\\FRIZQT__.TTF", 10, "" end

function frameMethods:SetScript(name, fn) self._scripts[name] = fn end
function frameMethods:GetScript(name) return self._scripts[name] end
function frameMethods:HasScript(name) return true end
function frameMethods:RegisterEvent(e) self._events[e] = true end
function frameMethods:UnregisterEvent(e) self._events[e] = nil end
function frameMethods:RegisterForDrag(...) self._dragButtons = { ... } end
function frameMethods:RegisterForClicks(...) end
function frameMethods:SetMovable(v) self._movable = v end

function frameMethods:CreateTexture()
    return Stub.CreateFrame("Texture")
end
function frameMethods:CreateFontString()
    return Stub.CreateFrame("FontString")
end

-- Frame API this addon doesn't read anything back from - present so calls
-- don't error, doing nothing. Listed explicitly rather than handled by a
-- catch-all __index that invents methods on demand: a catch-all cannot tell a
-- method lookup from a field lookup, so `frame.gfPinnedFor` on a frame that
-- has no such field would come back as a function and read as truthy. Every
-- custom field this addon sets on host frames works exactly that way, so the
-- catch-all quietly broke all of them at once. Unknown keys must be nil.
for _, name in ipairs({
    "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor", "SetTexture",
    "SetTexCoord", "SetVertexColor", "SetAlpha", "GetAlpha",
    "SetJustifyH", "SetFont", "SetFontObject", "SetTextColor", "SetShadowOffset",
    "EnableMouseWheel", "SetToplevel", "SetClampedToScreen",
    "StartMoving", "StopMovingOrSizing", "SetHitRectInsets", "SetNormalTexture",
    "SetHighlightTexture", "SetPushedTexture", "SetID", "SetParent", "SetAllPoints",
    "SetStatusBarTexture", "SetStatusBarColor", "SetMinMaxValues", "SetValue",
    "SetOwner", "AddLine", "SetScale", "Raise", "Lower", "SetStrata",
    "SetFrameStrata", "SetResizable", "SetMinResize", "Disable", "Enable",
}) do
    if not frameMethods[name] then
        frameMethods[name] = function() return nil end
    end
end

local frameMeta = { __index = frameMethods }

function Stub.CreateFrame(frameType, name, parent)
    local f = setmetatable({
        _type = frameType or "Frame",
        _name = name,
        _points = {},
        _scripts = {},
        _events = {},
        _shown = true,
        _w = 120,
        _h = 49,
        _parent = parent,
    }, frameMeta)
    if name then _G[name] = f end
    return f
end

-- ---------------------------------------------------------------------------
-- Roster
-- ---------------------------------------------------------------------------
Stub.roster = { player = "Player", party = {}, raid = {} }

-- SetRoster{ player = "Me", party = {"Alice", "Bob"}, raid = {...} }
function Stub.SetRoster(spec)
    Stub.roster.player = spec.player or "Player"
    Stub.roster.party = spec.party or {}
    Stub.roster.raid = spec.raid or {}
end

local function unitToName(unit)
    if not unit then return nil end
    if unit == "player" then return Stub.roster.player end
    local _, _, pidx = string.find(unit, "^party(%d+)$")
    if pidx then return Stub.roster.party[tonumber(pidx)] end
    local _, _, ridx = string.find(unit, "^raid(%d+)$")
    if ridx then return Stub.roster.raid[tonumber(ridx)] end
    return nil
end

-- ---------------------------------------------------------------------------
-- Globals
-- ---------------------------------------------------------------------------
Stub.chat = {}
Stub.shiftDown = false
Stub.ctrlDown = false
Stub.cursor = { x = 0, y = 0 }

function Stub.InstallGlobals()
    Stub.UIParent = Stub.UIParent or setmetatable({
        _type = "Frame", _name = "UIParent", _points = {}, _scripts = {}, _events = {},
        _shown = true, _w = UI_WIDTH, _h = UI_HEIGHT, _baseLeft = 0, _baseTop = UI_HEIGHT,
    }, frameMeta)

    UIParent = Stub.UIParent
    WorldFrame = WorldFrame or Stub.CreateFrame("Frame", "WorldFrame")

    CreateFrame = Stub.CreateFrame
    getglobal = function(n) return _G[n] end
    setglobal = function(n, v) _G[n] = v end

    DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, msg) table.insert(Stub.chat, msg) end,
    }

    UnitExists = function(unit) return unitToName(unit) ~= nil end
    UnitName = function(unit) return unitToName(unit) end
    UnitIsUnit = function(a, b) return unitToName(a) == unitToName(b) end
    UnitClass = function() return "Warrior", "WARRIOR" end
    UnitIsConnected = function() return 1 end

    GetNumPartyMembers = function() return #Stub.roster.party end
    GetNumRaidMembers = function() return #Stub.roster.raid end

    IsShiftKeyDown = function() return Stub.shiftDown and 1 or nil end
    IsControlKeyDown = function() return Stub.ctrlDown and 1 or nil end
    IsAltKeyDown = function() return nil end
    GetCursorPosition = function() return Stub.cursor.x, Stub.cursor.y end
    GetTime = function() return os.clock() end

    SlashCmdList = {}
    ChatFrame1 = DEFAULT_CHAT_FRAME

    Stub.chat = {}
end

-- Wipes every global a previous load created, so each test starts from a
-- genuinely clean world rather than inheriting frames and saved variables
-- from the test before it.
function Stub.Reset()
    for _, prefix in ipairs({ "PartyMemberFrame", "ShaguTweaksRaidUnitFrame", "pfGroup", "pfRaid" }) do
        for i = 0, 40 do _G[prefix .. i] = nil end
    end
    GF, GF_Pins, GF_Order = nil, nil, nil
    Stub.unknownCalls = {}
    Stub.shiftDown, Stub.ctrlDown = false, false
    Stub.InstallGlobals()
end

-- Fires a frame's script the way the client does: via the `this`/`event`/
-- `arg1` globals that 1.12 handlers read instead of taking parameters.
function Stub.FireScript(frame, script, ev, a1, a2, a3, a4)
    local fn = frame:GetScript(script)
    if not fn then return end
    this, event, arg1, arg2, arg3, arg4 = frame, ev, a1, a2, a3, a4
    fn()
    this, event, arg1, arg2, arg3, arg4 = nil, nil, nil, nil, nil, nil
end

function Stub.RunSlash(cmd, text)
    local fn = SlashCmdList[cmd]
    if not fn then error("no slash handler registered for " .. cmd) end
    fn(text or "")
end

Stub.InstallGlobals()
return Stub
