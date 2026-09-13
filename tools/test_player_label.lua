-- Smoke test for WDLD's player ping label. Run from the repo root:
--   lua tools/test_player_label.lua [path/to/addon.lua]
--
local Stub = dofile("tools/wow_stub.lua")
local ADDON_PATH = arg[1] or "WiredbroLagDetector.lua"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

-- Extra API surface this addon touches beyond what wow_stub.lua covers.
local function installWdldExtras()
    GetNetStats = function() return 0, 0, 42, 0 end
    SendAddonMessage = function() end
    GetCVar = function() return "N'Zoth" end
    GetRealmName = function() return "N'Zoth" end
    date = function(fmt) return "12:00:00" end
    GameTooltip = Stub.CreateFrame("Frame", "GameTooltip")
    Minimap = Stub.CreateFrame("Frame", "Minimap")
    UIParent.GetEffectiveScale = function() return 1 end
    GetNumPartyMembers = function() return 0 end
    GetNumRaidMembers = function() return 0 end
    UnitIsDeadOrGhost = function() return nil end
    UnitAffectingCombat = function() return nil end
    GetFramerate = function() return 60 end
    ChatFrame1 = DEFAULT_CHAT_FRAME
    SlashCmdList = SlashCmdList or {}
end

local function freshWorld()
    Stub.Reset()
    installWdldExtras()
    Stub.SetRoster({ player = "Salahaja", party = { "Alice", "Bob" } })

    -- The frames WDLD stamps labels onto.
    local pf = Stub.CreateFrame("Button", "PlayerFrame")
    pf._w, pf._h = 232, 100
    pf:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 20, 800)
    for i = 1, 4 do
        local f = Stub.CreateFrame("Button", "PartyMemberFrame" .. i)
        f._w, f._h = 120, 49
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 20, 700 - (i - 1) * 60)
    end

    NW = nil
    dofile(ADDON_PATH)
end

print("the player label is created and anchored to PlayerFrame")
do
    freshWorld()
    NW.pingEnabled = true
    NW.lastRTT = 120
    NW.lastHomeLatency = 60
    NW.RefreshPlayerFrameLabel()

    local h = NW.playerPingHolder
    check("holder exists", h ~= nil, true)
    check("uses the player offset bucket", h.offsetKey, "player")
    check("parented to UIParent (draggable anywhere)", h:GetParent(), UIParent)
    local _, relativeTo = h:GetPoint()
    check("anchored to PlayerFrame by default", relativeTo, _G.PlayerFrame)
    check("names the player for the mouseover tooltip", h.memberName, "Salahaja")
end

print("the label shows the round-trip value, and -- / off for the other states")
do
    freshWorld()
    NW.pingEnabled = true
    NW.lastHomeLatency = 60

    NW.lastRTT = 120
    NW.RefreshPlayerFrameLabel()
    check("shows ms value", string.find(NW.playerPingHolder.text._text or "", "120ms") ~= nil, true)

    NW.lastRTT = nil
    NW.RefreshPlayerFrameLabel()
    check("shows -- when no reply", string.find(NW.playerPingHolder.text._text or "", "%-%-") ~= nil, true)

    NW.pingEnabled = false
    NW.RefreshPlayerFrameLabel()
    check("shows off when ping disabled", string.find(NW.playerPingHolder.text._text or "", "off") ~= nil, true)
end

print("moving the player label does not drag the group labels (and vice versa)")
do
    freshWorld()
    NW.pingEnabled = true
    NW.lastRTT = 120
    NW.lastHomeLatency = 60
    NW.RefreshPlayerFrameLabel()
    NW.RefreshPartyFrameLabels()

    local partyHolder = _G.PartyMemberFrame1.wdldPingHolder
    check("a party label exists to compare against", partyHolder ~= nil, true)
    local partyTopBefore = partyHolder:GetTop()
    local playerTopBefore = NW.playerPingHolder:GetTop()

    -- Move only the player bucket, as its OnDragStop would.
    NW.pingLabelOffsets.player.x = 300
    NW.pingLabelOffsets.player.y = -250
    NW.RepositionPingLabels()

    check("player label moved", NW.playerPingHolder:GetTop(), playerTopBefore - 250)
    check("party label did NOT move", partyHolder:GetTop(), partyTopBefore)

    -- And the reverse: moving the group bucket leaves the player label alone.
    local playerTopNow = NW.playerPingHolder:GetTop()
    NW.pingLabelOffsets.group.y = -40
    NW.RepositionPingLabels()
    check("party label moved", partyHolder:GetTop(), partyTopBefore - 40)
    check("player label unaffected", NW.playerPingHolder:GetTop(), playerTopNow)
end

print("reset puts both buckets back")
do
    freshWorld()
    NW.RefreshPlayerFrameLabel()
    NW.RefreshPartyFrameLabels()
    local playerTop = NW.playerPingHolder:GetTop()
    local partyTop = _G.PartyMemberFrame1.wdldPingHolder:GetTop()

    NW.pingLabelOffsets.player.x, NW.pingLabelOffsets.player.y = 300, -250
    NW.pingLabelOffsets.group.x, NW.pingLabelOffsets.group.y = -70, 90
    NW.RepositionPingLabels()

    for _, o in pairs(NW.pingLabelOffsets) do o.x, o.y = 0, 0 end
    NW.RepositionPingLabels()
    check("player label back to default", NW.playerPingHolder:GetTop(), playerTop)
    check("party label back to default", _G.PartyMemberFrame1.wdldPingHolder:GetTop(), partyTop)
end

print("unlocking enables the mouse on the player label too")
do
    freshWorld()
    NW.RefreshPlayerFrameLabel()
    NW.SetPingLabelsUnlocked(true)
    check("player holder is in the shared holder list", NW.playerPingHolder._mouseEnabled, true)
    NW.SetPingLabelsUnlocked(false)
    check("and re-locks", NW.playerPingHolder._mouseEnabled, false)
end

print("")
if failures == 0 then
    print("all " .. checks .. " checks passed")
    os.exit(0)
else
    print(failures .. " of " .. checks .. " checks FAILED")
    os.exit(1)
end
