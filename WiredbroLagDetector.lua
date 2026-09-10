--[[
    Addon:       WiredbroLagDetector (folder/internal name - ADDON_LOADED and
                 SavedVariables key off this, matching the folder/.toc/.lua
                 names; the internal Lua table is still NW for historical
                 reasons, and it displays in-game as "Wirebro DDOS Lag Detector")
    Description: Connection stability monitor. Vanilla's Lua API exposes latency
                 (GetNetStats: bandwidthIn, bandwidthOut, latencyHome, latencyWorld)
                 but NOT a true packet-loss percentage - that stat simply isn't
                 exposed to addons. latencyWorld also turned out to always read 0
                 on this server, so the whole monitor runs on latencyHome instead
                 - tracking its spikes and stalls, which is what packet
                 loss/timeouts actually look like from the client's side, and
                 keeping a timestamped log of them so you can look back and
                 correlate rough patches with server attacks.

                 Also does a real chat round-trip ping: sends a tiny addon message
                 to yourself over the GUILD channel (invisible in chat, never seen
                 by anyone - "WHISPER" is rejected outright by this client's
                 SendAddonMessage, confirmed via /script test, so GUILD is used
                 instead; requires being in a guild) and times how long it takes
                 to come back. This measures actual message-level round trip
                 through the server, which can diverge from GetNetStats' latency
                 number when the server itself is backed up rather than the
                 network path. Opt-in: run "/wdld pingtest" once to check before
                 turning on the automatic background ping. The per-ping timeout is
                 adaptive (2x the last real round trip, or 3x current home latency
                 before any round trip has completed yet) rather than a fixed
                 guess - see ComputePingTimeout. Reply-matching uses a small
                 incrementing counter, not the raw timestamp - round-tripping a
                 float with many decimal digits through tostring()/tonumber() can
                 lose enough precision (once GetTime() is large) that the exact
                 equality check would fail even for a reply that arrived on time,
                 which looked like frequent phantom timeouts before this was fixed.

                 Also broadcasts your own latency to PARTY/RAID (same addon-message
                 mechanism, different prefix) every 5s, and listens for the same
                 from anyone else in the group running this addon - a "Group
                 Latency" panel shows everyone's, worst first, so you can see at a
                 glance whether an issue is just you or everyone. On by default
                 (opt-out, not opt-in - unlike the ping, there's no "does this even
                 work" uncertainty here since it's the exact channel
                 Aegis_RallyPower's sync already proves works).

    Slash Commands (all equivalent - /wdld, /nw, /netwatch):
        /wdld                  toggle the on-screen monitor
        /wdld log              print the recent spike/recovery log to chat
        /wdld clear            clear the log
        /wdld set warn 500     ms threshold for a "warn" (yellow) state
        /wdld set severe 1500  ms threshold for a "severe" (red) state
        /wdld probe            dumps GetNetStats()'s raw return values, to verify the
                               assumed field order on this client
        /wdld pingtest         sends one GUILD-channel round-trip ping and reports
                               whether it worked and how long it took
        /wdld set ping on      turns on automatic background round-trip pinging
        /wdld set ping off     turns it back off (default)
        /wdld roster           opens the Group Latency panel
        /wdld set roster on    shares your latency with party/raid (default)
        /wdld set roster off   stops sharing (you can still see others')

    Right-click the monitor to open settings: update interval, ping interval
    (both 0.5s-10s sliders), the ping on/off checkbox, the roster share checkbox,
    and a button to open the Group Latency panel. Ping timeout is computed
    automatically, not a setting.
--]]

NW = {}
NW.ADDON_NAME = "WiredbroLagDetector"

NW.HISTORY_MAX      = 120  -- ~2 minutes of samples at 1s each
NW.SAMPLE_INTERVAL  = 1
NW.SPIKE_MULTIPLIER = 3     -- flag if current latency > rolling average * this
NW.BASELINE_FLOOR   = 60    -- ignore the multiplier check below this avg (ms) - too noisy on a low baseline
NW.LOG_MAX          = 100

-- latencyWorld turned out to always read 0 on this server (GetNetStats still
-- returns it, but it's never populated) - so the whole monitor runs on
-- latencyHome instead. This isn't just a display choice: the spike/warn/severe
-- detection below was built around latencyWorld originally, which means it was
-- silently never firing (0 never crosses any threshold) until this changed.
NW.history  = {}   -- ring of { ms = latencyHome }
NW.log      = {}   -- persisted: {time = "HH:MM:SS", kind = "warn"/"severe"/"recovered"/"ping*", ms = value, duration = sec or nil}
NW.state    = "normal"
NW.stateSince = nil
NW.sampleTimer = 0

NW.warnThreshold   = 500
NW.severeThreshold = 1500

-- Chat round-trip ping (see header note on SendAddonMessage / self-whisper).
-- Aegis_RallyPower's sync module (Aegis_Sync.lua, same PARTY/RAID addon-message
-- channel, tested on this exact server family) documents a ~250-byte payload
-- ceiling and self-throttles its own traffic to as tight as 1-3s between sends
-- of much larger messages. Our payload is a single timestamp (a few bytes),
-- adjustable 0.5s-10s via the settings slider.
NW.PING_PREFIX   = "WIREDBROLAG"
NW.PING_INTERVAL = 30  -- seconds between automatic background pings (slider-adjustable)
NW.pingEnabled   = false
NW.pendingPing   = nil -- { sentAt = GetTime(), timeout = seconds, isTest = bool }
NW.pingTimer     = 0
NW.lastRTT       = nil -- ms, nil until we get at least one reply
NW.warnedNoGuild = false -- so the "not in a guild" notice fires once, not every ping cycle

-- Group latency sync: broadcasts your own latency to PARTY/RAID (same
-- addon-message mechanism, proven by Aegis_RallyPower on this exact channel -
-- see Aegis_Sync.lua's RawSend). A separate prefix from the ping so a received
-- roster broadcast (sender = someone else, or your own echoing back) can never
-- be mistaken for a ping reply.
NW.ROSTER_PREFIX            = "WIREDBROLAGRC"
NW.ROSTER_BROADCAST_INTERVAL = 5   -- seconds between broadcasts, independent of the sample interval
NW.ROSTER_STALE_AFTER       = 20   -- seconds with no update before greying an entry out
NW.rosterBroadcast          = true -- opt-out, not opt-in: unlike the ping, there's no
                                    -- "does this even work" uncertainty here, and it's
                                    -- useless to everyone if it defaults off and nobody enables it
NW.rosterBroadcastTimer     = 0
NW.lastHomeLatency          = nil  -- cached from the most recent Sample(), for the broadcast and for
                                    -- the first ping's timeout estimate (see ComputePingTimeout)
NW.roster        = {}  -- [name] = { latency = ms, time = GetTime() }
NW.rosterOrder   = {}  -- insertion-ordered names, for stable row layout

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
function NW.Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5179Wirebro DDOS Lag Detector|r: " .. msg)
end

function NW.Now()
    return date("%H:%M:%S")
end

function NW.RollingAverage()
    local n = table.getn(NW.history)
    if n <= 1 then return nil end
    -- average everything except the most recent sample (that's "current", not baseline)
    local sum, count = 0, 0
    local stop = n - 1
    local start = stop - 29
    if start < 1 then start = 1 end
    for i = start, stop do
        sum = sum + NW.history[i].ms
        count = count + 1
    end
    if count == 0 then return nil end
    return sum / count
end

function NW.PushLog(kind, ms, duration)
    local entry = { time = NW.Now(), kind = kind, ms = ms, duration = duration }
    table.insert(NW.log, entry)
    while table.getn(NW.log) > NW.LOG_MAX do
        table.remove(NW.log, 1)
    end
    NW_Log = NW.log
end

-- ---------------------------------------------------------------------------------------------
-- Chat round-trip ping
-- ---------------------------------------------------------------------------------------------

-- Single toggle path shared by "/wdld set ping on|off" and the settings
-- checkbox, so both stay in sync instead of duplicating this logic.
function NW.SetPingEnabled(enabled)
    if enabled and not GetGuildInfo("player") then
        NW.Say("|cFFFF3333can't enable|r - the ping rides the GUILD addon-message channel, and you're not in a guild right now.")
        if NW.settingsFrame and NW.settingsFrame.pingCheck then
            NW.settingsFrame.pingCheck:SetChecked(false)
        end
        return
    end

    NW.pingEnabled = enabled
    NW_PingEnabled = enabled
    NW.warnedNoGuild = false -- reset so a future guild-status change warns again
    if enabled then
        NW.pingTimer = NW.PING_INTERVAL -- fire the first one almost immediately
        NW.Say("background chat round-trip pinging |cFF00FF7Fon|r - every " .. NW.PING_INTERVAL .. "s.")
    else
        NW.pendingPing = nil
        NW.Say("background chat round-trip pinging |cFFFF5179off|r.")
    end
    NW.UpdateChatRTTDisplay()
    if NW.settingsFrame and NW.settingsFrame.pingCheck then
        NW.settingsFrame.pingCheck:SetChecked(enabled)
    end
end

-- Runs every frame regardless of pingEnabled, so a manual "/wdld pingtest" gets
-- a timeout report too - previously only the automatic loop (inside SendPing,
-- and only reachable while pingEnabled) ever checked for a stale pendingPing,
-- so a pingtest run before enabling background pinging just hung forever with
-- no feedback at all if the reply never came back.
function NW.CheckPendingPingTimeout()
    if not NW.pendingPing then return end
    local timeout = NW.pendingPing.timeout or 5
    if GetTime() - NW.pendingPing.sentAt <= timeout then return end

    local wasTest = NW.pendingPing.isTest
    NW.pendingPing = nil

    if wasTest then
        NW.Say("|cFFFF3333ping test failed|r - no reply after " .. string.format("%.1f", timeout) ..
            "s. Something ate it, or you're not actually in a guild right now.")
    else
        NW.PushLog("pingtimeout", NW.lastRTT or 0, timeout)
        NW.Say("|cFFFF3333chat round-trip ping got no reply after " .. string.format("%.1f", timeout) .. "s - possible message loss|r")
    end
end

-- Adaptive instead of a fixed setting: once we have a real measured RTT, 2x
-- that is a far better basis than any fixed guess - it flags a genuine stall
-- quickly without false-tripping on ordinary jitter for someone with a fast
-- connection, and without being too tight for someone with a slow one. Before
-- the first successful ping ever completes there's no RTT yet, so that first
-- one uses 3x the current home latency as a rough stand-in, and if even THAT
-- isn't available yet, a 5s floor.
function NW.ComputePingTimeout()
    local computed
    if NW.lastRTT and NW.lastRTT > 0 then
        computed = (NW.lastRTT * 2) / 1000
    elseif NW.lastHomeLatency and NW.lastHomeLatency > 0 then
        computed = (NW.lastHomeLatency * 3) / 1000
    else
        computed = 5
    end
    if computed < 1 then computed = 1 end -- floor: guards a degenerate near-zero estimate
    return computed
end

-- "WHISPER" turned out to be rejected outright by this client's SendAddonMessage
-- ("Unknown addon chat type", confirmed via /script test) - not a server-side
-- self-whisper block, the client itself doesn't accept that chat type at all.
-- "GUILD" IS accepted (also confirmed live), so the ping rides that instead: it
-- broadcasts to the whole guild, but we only ever react to our OWN echo of it
-- (CHAT_MSG_ADDON's sender check below), so it's still effectively a self-ping -
-- guildmates' clients receive and instantly discard it, same as any addon
-- message with a prefix they don't recognize. Requires being in a guild, unlike
-- the old whisper approach, which needed nothing.
-- The ping payload used to be tostring(GetTime()) - a float with more decimal
-- digits than Lua's ~14-significant-digit number-to-string conversion
-- preserves. Once GetTime() grows large enough (any session running for a
-- while), round-tripping it through a string and back could produce a value
-- that no longer exactly equals the original, so HandlePingReply's match check
-- would silently fail even though the reply genuinely arrived on time -
-- reported as a timeout that wasn't really one. A small incrementing counter,
-- compared as a plain string, has no floating-point precision involved at all.
NW.pingNonce = 0

function NW.SendPing()
    if NW.pendingPing then return end
    if not GetGuildInfo("player") then
        if not NW.warnedNoGuild then
            NW.warnedNoGuild = true
            NW.Say("|cFFFFA500background ping paused - you're not in a guild right now.|r")
        end
        return
    end
    NW.warnedNoGuild = false

    NW.pingNonce = NW.pingNonce + 1
    local nonce = tostring(NW.pingNonce)
    local now = GetTime()
    local ok = pcall(SendAddonMessage, NW.PING_PREFIX, nonce, "GUILD")
    if ok then
        NW.pendingPing = { sentAt = now, nonce = nonce, timeout = NW.ComputePingTimeout() }
    end
end

-- One-off manual test, independent of the pingEnabled toggle - reports success or
-- failure directly rather than depending on the automatic loop to notice.
function NW.PingTest()
    if not SendAddonMessage then
        NW.Say("|cFFFF3333SendAddonMessage doesn't exist on this client at all.|r")
        return
    end
    if not GetGuildInfo("player") then
        NW.Say("|cFFFF3333you're not in a guild|r - the ping rides the GUILD addon-message channel, so it needs one.")
        return
    end
    local timeout = NW.ComputePingTimeout()
    NW.Say("sending a ping over the GUILD addon-message channel (timeout " .. string.format("%.1f", timeout) ..
        "s - invisible in chat, nothing will show up there even if this works)...")
    NW.pingNonce = NW.pingNonce + 1
    local nonce = tostring(NW.pingNonce)
    local now = GetTime()
    local ok, err = pcall(SendAddonMessage, NW.PING_PREFIX, nonce, "GUILD")
    if not ok then
        NW.Say("|cFFFF3333SendAddonMessage errored:|r " .. tostring(err))
        return
    end
    NW.pendingPing = { sentAt = now, nonce = nonce, isTest = true, timeout = timeout }
end

function NW.HandlePingReply(nonceStr)
    if not NW.pendingPing or NW.pendingPing.nonce ~= nonceStr then return end

    local rtt = math.floor((GetTime() - NW.pendingPing.sentAt) * 1000)
    local wasTest = NW.pendingPing.isTest
    NW.pendingPing = nil
    NW.lastRTT = rtt

    if wasTest then
        NW.Say("|cFF00FF7Fping test succeeded|r - round trip: " .. rtt .. "ms. Self-whisper pinging works on this server; run /wdld set ping on to enable it automatically.")
        return
    end

    if rtt >= NW.severeThreshold then
        NW.PushLog("pingsevere", rtt)
        NW.Say("|cFFFF3333chat round-trip spike: " .. rtt .. "ms|r")
    elseif rtt >= NW.warnThreshold then
        NW.PushLog("pingwarn", rtt)
    end

    NW.UpdateChatRTTDisplay()
end

-- ---------------------------------------------------------------------------------------------
-- Group latency sync
-- ---------------------------------------------------------------------------------------------

function NW.SetRosterBroadcast(enabled)
    NW.rosterBroadcast = enabled
    NW_RosterBroadcast = enabled
    if NW.settingsFrame and NW.settingsFrame.rosterCheck then
        NW.settingsFrame.rosterCheck:SetChecked(enabled)
    end
end

-- Solo: nothing to broadcast to, matching Aegis_Sync's RawSend behavior.
function NW.BroadcastRosterStatus()
    if not NW.rosterBroadcast then return end
    if not NW.lastHomeLatency or NW.lastHomeLatency <= 0 then return end

    local me = UnitName("player")
    if GetNumRaidMembers() > 0 then
        pcall(SendAddonMessage, NW.ROSTER_PREFIX, tostring(NW.lastHomeLatency), "RAID", me)
    elseif GetNumPartyMembers() > 0 then
        pcall(SendAddonMessage, NW.ROSTER_PREFIX, tostring(NW.lastHomeLatency), "PARTY", me)
    end
end

function NW.HandleRosterMessage(sender, msg)
    local ms = tonumber(msg)
    if not sender or not ms then return end
    if not NW.roster[sender] then
        table.insert(NW.rosterOrder, sender)
    end
    NW.roster[sender] = { latency = ms, time = GetTime() }
    if NW.rosterFrame and NW.rosterFrame:IsShown() then
        NW.RefreshRosterPanel()
    end
end

-- Drops anyone no longer in the group (left, or the group disbanded), so a
-- stale entry from a prior raid doesn't linger forever.
function NW.PruneRosterToGroup()
    local inGroup = {}
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            local nm = UnitName("raid" .. i)
            if nm then inGroup[nm] = true end
        end
    else
        local p = GetNumPartyMembers()
        for i = 1, p do
            local nm = UnitName("party" .. i)
            if nm then inGroup[nm] = true end
        end
    end

    local changed = false
    for i = table.getn(NW.rosterOrder), 1, -1 do
        local nm = NW.rosterOrder[i]
        if not inGroup[nm] then
            NW.roster[nm] = nil
            table.remove(NW.rosterOrder, i)
            changed = true
        end
    end
    if changed and NW.rosterFrame and NW.rosterFrame:IsShown() then
        NW.RefreshRosterPanel()
    end
end

-- ---------------------------------------------------------------------------------------------
-- Sampling
-- ---------------------------------------------------------------------------------------------
function NW.Sample()
    local bwIn, bwOut, latencyHome, latencyWorld = GetNetStats()

    -- latencyWorld is read but deliberately unused - it always comes back 0 on
    -- this server. Always update the on-screen display even with a zero/missing
    -- home reading, so the box is never left blank.
    if not latencyHome or latencyHome <= 0 then
        NW.UpdateDisplay(latencyHome)
        return
    end

    NW.lastHomeLatency = latencyHome

    table.insert(NW.history, { ms = latencyHome })
    while table.getn(NW.history) > NW.HISTORY_MAX do
        table.remove(NW.history, 1)
    end

    local avg = NW.RollingAverage()
    local newState = "normal"

    if latencyHome >= NW.severeThreshold then
        newState = "severe"
    elseif avg and avg >= NW.BASELINE_FLOOR and latencyHome >= avg * NW.SPIKE_MULTIPLIER then
        newState = "severe"
    elseif latencyHome >= NW.warnThreshold then
        newState = "warn"
    end

    if newState ~= NW.state then
        if newState == "normal" and NW.stateSince then
            local duration = math.floor(GetTime() - NW.stateSince)
            NW.PushLog("recovered", latencyHome, duration)
            NW.Say("connection back to normal (" .. latencyHome .. "ms) after " .. duration .. "s of trouble.")
        elseif newState == "warn" then
            NW.PushLog("warn", latencyHome)
            NW.Say("|cFFFFA500latency elevated: " .. latencyHome .. "ms|r")
        elseif newState == "severe" then
            NW.PushLog("severe", latencyHome)
            NW.Say("|cFFFF0000latency spike: " .. latencyHome .. "ms - possible server trouble|r")
        end

        if newState ~= "normal" then
            -- only stamp the *original* onset time - an escalation (warn -> severe)
            -- shouldn't reset the clock, or "recovered after Xs" would only count
            -- the severe portion instead of the whole incident.
            if not NW.stateSince then
                NW.stateSince = GetTime()
            end
        else
            NW.stateSince = nil
        end
        NW.state = newState
    end

    NW.UpdateDisplay(latencyHome)
end

-- ---------------------------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------------------------
function NW.CreateFrame()
    local f = CreateFrame("Frame", "NW_Frame", UIParent)
    f:SetWidth(170); f:SetHeight(58)
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -4)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.75)
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint()
        NW_FramePos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:SetScript("OnMouseUp", function()
        if arg1 == "RightButton" then NW.ToggleSettings() end
    end)
    f:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Wirebro DDOS Lag Detector")
        GameTooltip:AddLine("Left-click + drag: move", 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    title:SetJustifyH("LEFT")
    title:SetText("|cFFFF5179Lag Detector|r")
    f.title = title

    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -8)
    statusText:SetJustifyH("RIGHT")
    f.statusText = statusText

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -22)
    divider:SetTexture(1, 1, 1, 0.25)

    local homeText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    homeText:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
    homeText:SetJustifyH("LEFT")
    f.homeText = homeText

    local rttText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rttText:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -44)
    rttText:SetJustifyH("LEFT")
    f.rttText = rttText

    if NW_FramePos then
        f:ClearAllPoints()
        f:SetPoint(NW_FramePos.point or "TOPRIGHT", UIParent, NW_FramePos.relPoint or "TOPRIGHT",
            NW_FramePos.x or -200, NW_FramePos.y or -4)
    end

    NW.frame = f
end

-- Small helper so the sample-interval and ping-interval sliders (identical
-- shape, different backing value) don't duplicate this setup.
local function MakeIntervalSlider(parent, name, y, labelPrefix, initialValue, onChanged)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetWidth(160); slider:SetHeight(16)
    slider:SetPoint("TOP", parent, "TOP", 0, y)
    slider:SetMinMaxValues(0.5, 10)
    slider:SetValueStep(0.5)
    slider:SetOrientation("HORIZONTAL")
    getglobal(slider:GetName() .. "Low"):SetText("0.5s")
    getglobal(slider:GetName() .. "High"):SetText("10s")
    slider.textFS = getglobal(slider:GetName() .. "Text")
    slider.labelPrefix = labelPrefix
    slider.textFS:SetText(labelPrefix .. ": " .. initialValue .. "s")
    slider:SetValue(initialValue)
    slider:SetScript("OnValueChanged", function()
        -- snap to the nearest 0.5 - SetValueStep alone can still leave float
        -- noise (e.g. 1.4999999) depending on how the drag lands
        local v = math.floor((this:GetValue() * 2) + 0.5) / 2
        this.textFS:SetText(this.labelPrefix .. ": " .. v .. "s")
        onChanged(v)
    end)
    return slider
end

function NW.CreateSettingsFrame()
    local s = CreateFrame("Frame", "NW_SettingsFrame", UIParent)
    s:SetWidth(200); s:SetHeight(220)
    s:SetPoint("TOP", NW.frame, "BOTTOM", 0, -6)
    s:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    s:SetBackdropColor(0, 0, 0, 0.85)
    s:Hide()

    local close = CreateFrame("Button", "NW_SettingsClose", s, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", s, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() s:Hide() end)

    s.slider = MakeIntervalSlider(s, "NW_IntervalSlider", -34, "Update interval", NW.SAMPLE_INTERVAL,
        function(v)
            NW.SAMPLE_INTERVAL = v
            NW_SampleInterval = v
        end)

    local pingCheck = CreateFrame("CheckButton", "NW_PingCheck", s, "UICheckButtonTemplate")
    pingCheck:SetWidth(20); pingCheck:SetHeight(20)
    pingCheck:SetPoint("TOPLEFT", s, "TOPLEFT", 14, -66)
    pingCheck:SetChecked(NW.pingEnabled)
    pingCheck:SetScript("OnClick", function()
        NW.SetPingEnabled(this:GetChecked() and true or false)
    end)
    s.pingCheck = pingCheck

    local pingLabel = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pingLabel:SetPoint("LEFT", pingCheck, "RIGHT", 4, 0)
    pingLabel:SetText("Chat round-trip ping")
    s.pingLabel = pingLabel

    s.pingIntervalSlider = MakeIntervalSlider(s, "NW_PingIntervalSlider", -100, "Ping interval", NW.PING_INTERVAL,
        function(v)
            NW.PING_INTERVAL = v
            NW_PingInterval = v
        end)

    local rosterCheck = CreateFrame("CheckButton", "NW_RosterCheck", s, "UICheckButtonTemplate")
    rosterCheck:SetWidth(20); rosterCheck:SetHeight(20)
    rosterCheck:SetPoint("TOPLEFT", s, "TOPLEFT", 14, -132)
    rosterCheck:SetChecked(NW.rosterBroadcast)
    rosterCheck:SetScript("OnClick", function()
        NW.SetRosterBroadcast(this:GetChecked() and true or false)
    end)
    s.rosterCheck = rosterCheck

    local rosterLabel = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rosterLabel:SetPoint("LEFT", rosterCheck, "RIGHT", 4, 0)
    rosterLabel:SetText("Share my latency with group")
    s.rosterLabel = rosterLabel

    local rosterBtn = CreateFrame("Button", "NW_RosterOpenBtn", s, "UIPanelButtonTemplate")
    rosterBtn:SetWidth(140); rosterBtn:SetHeight(20)
    rosterBtn:SetPoint("TOP", s, "TOP", 0, -158)
    rosterBtn:SetText("Group Latency")
    rosterBtn:SetScript("OnClick", function() NW.ToggleRosterPanel() end)
    s.rosterBtn = rosterBtn

    NW.settingsFrame = s
end

function NW.ToggleSettings()
    if not NW.settingsFrame then NW.CreateSettingsFrame() end
    if NW.settingsFrame:IsShown() then
        NW.settingsFrame:Hide()
    else
        NW.settingsFrame.slider:SetValue(NW.SAMPLE_INTERVAL)
        NW.settingsFrame.pingCheck:SetChecked(NW.pingEnabled)
        NW.settingsFrame.pingIntervalSlider:SetValue(NW.PING_INTERVAL)
        NW.settingsFrame.rosterCheck:SetChecked(NW.rosterBroadcast)
        NW.settingsFrame:Show()
    end
end

-- ---------------------------------------------------------------------------------------------
-- Group latency panel
-- ---------------------------------------------------------------------------------------------
NW.ROSTER_PAGE_SIZE = 16
NW.rosterPage = 0

function NW.CreateRosterFrame()
    local r = CreateFrame("Frame", "NW_RosterFrame", UIParent)
    r:SetWidth(220); r:SetHeight(20 + NW.ROSTER_PAGE_SIZE * 18 + 34)
    r:SetPoint("LEFT", NW.settingsFrame, "RIGHT", 8, 0)
    r:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    r:SetBackdropColor(0, 0, 0, 0.85)
    r:Hide()

    local title = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", r, "TOP", 0, -6)
    title:SetText("Group Latency")

    local close = CreateFrame("Button", "NW_RosterClose", r, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", r, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() r:Hide() end)

    r.rows = {}
    for i = 1, NW.ROSTER_PAGE_SIZE do
        local row = CreateFrame("Frame", "NW_RosterRow" .. i, r)
        row:SetWidth(196); row:SetHeight(16)
        row:SetPoint("TOPLEFT", r, "TOPLEFT", 12, -24 - (i - 1) * 18)
        row:Hide()

        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameText:SetPoint("LEFT", row, "LEFT", 0, 0)
        nameText:SetWidth(120); nameText:SetJustifyH("LEFT")
        row.nameText = nameText

        local msText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        msText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        msText:SetJustifyH("RIGHT")
        row.msText = msText

        r.rows[i] = row
    end

    local pageLabel = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("BOTTOM", r, "BOTTOM", 0, 8)
    r.pageLabel = pageLabel

    local prevBtn = CreateFrame("Button", "NW_RosterPrev", r, "UIPanelButtonTemplate")
    prevBtn:SetWidth(60); prevBtn:SetHeight(18)
    prevBtn:SetPoint("RIGHT", pageLabel, "LEFT", -8, 0)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", function()
        if NW.rosterPage > 0 then
            NW.rosterPage = NW.rosterPage - 1
            NW.RefreshRosterPanel()
        end
    end)

    local nextBtn = CreateFrame("Button", "NW_RosterNext", r, "UIPanelButtonTemplate")
    nextBtn:SetWidth(60); nextBtn:SetHeight(18)
    nextBtn:SetPoint("LEFT", pageLabel, "RIGHT", 8, 0)
    nextBtn:SetText("Next >")
    nextBtn:SetScript("OnClick", function()
        local total = table.getn(NW.rosterOrder)
        local maxPage = math.floor((total - 1) / NW.ROSTER_PAGE_SIZE)
        if maxPage < 0 then maxPage = 0 end
        if NW.rosterPage < maxPage then
            NW.rosterPage = NW.rosterPage + 1
            NW.RefreshRosterPanel()
        end
    end)

    NW.rosterFrame = r
end

function NW.RefreshRosterPanel()
    if not NW.rosterFrame then return end

    -- sorted worst-latency-first, so who's struggling is immediately visible
    local sorted = {}
    for _, name in ipairs(NW.rosterOrder) do
        local data = NW.roster[name]
        if data then table.insert(sorted, { name = name, latency = data.latency, time = data.time }) end
    end
    table.sort(sorted, function(a, b) return a.latency > b.latency end)

    local total = table.getn(sorted)
    local maxPage = math.floor((total - 1) / NW.ROSTER_PAGE_SIZE)
    if maxPage < 0 then maxPage = 0 end
    if NW.rosterPage > maxPage then NW.rosterPage = maxPage end
    NW.rosterFrame.pageLabel:SetText("Page " .. (NW.rosterPage + 1) .. " / " .. (maxPage + 1) .. "  (" .. total .. ")")

    local startIndex = NW.rosterPage * NW.ROSTER_PAGE_SIZE
    for i = 1, NW.ROSTER_PAGE_SIZE do
        local row = NW.rosterFrame.rows[i]
        local entry = sorted[startIndex + i]
        if not entry then
            row:Hide()
        else
            local stale = (GetTime() - entry.time) > NW.ROSTER_STALE_AFTER
            if stale then
                row.nameText:SetText("|cFF666666" .. entry.name .. "|r")
                row.msText:SetText("|cFF666666" .. entry.latency .. "ms|r")
            else
                row.nameText:SetText(entry.name)
                row.msText:SetText(NW.ColorFor(entry.latency, NW.warnThreshold, NW.severeThreshold) .. entry.latency .. "ms|r")
            end
            row:Show()
        end
    end
end

function NW.ToggleRosterPanel()
    if not NW.settingsFrame then NW.CreateSettingsFrame() end
    if not NW.rosterFrame then NW.CreateRosterFrame() end
    if NW.rosterFrame:IsShown() then
        NW.rosterFrame:Hide()
    else
        NW.RefreshRosterPanel()
        NW.rosterFrame:Show()
    end
end

function NW.ColorFor(ms, warn, severe)
    if ms >= severe then return "|cFFFF3333"
    elseif ms >= warn then return "|cFFFFA500"
    else return "|cFF00FF7F" end
end

function NW.UpdateDisplay(latencyHome)
    if not NW.frame then return end

    -- default to 0 rather than leaving this nil - a nil here (e.g. right at
    -- login) would error on the >= comparisons in ColorFor and, worse, leave
    -- the box blank.
    local h = latencyHome or 0

    local homeColor = NW.ColorFor(h, NW.warnThreshold, NW.severeThreshold)
    NW.frame.homeText:SetText("Home:  " .. homeColor .. h .. "ms|r")

    local statusWord, statusColor = "Normal", "|cFF00FF7F"
    if NW.state == "severe" then
        statusWord, statusColor = "SEVERE", "|cFFFF3333"
    elseif NW.state == "warn" then
        statusWord, statusColor = "Warn", "|cFFFFA500"
    end
    NW.frame.statusText:SetText(statusColor .. statusWord .. "|r")

    NW.UpdateChatRTTDisplay()
end

-- Separate from UpdateDisplay because a ping reply can arrive independently of a
-- GetNetStats() sample tick, and shouldn't require (or overwrite) the world/home
-- values to refresh just its own line.
function NW.UpdateChatRTTDisplay()
    if not NW.frame then return end
    if not NW.pingEnabled then
        NW.frame.rttText:SetText("Chat RTT:  |cFF888888off|r")
    elseif not NW.lastRTT then
        NW.frame.rttText:SetText("Chat RTT:  |cFF888888--|r")
    else
        local color = NW.ColorFor(NW.lastRTT, NW.warnThreshold, NW.severeThreshold)
        NW.frame.rttText:SetText("Chat RTT:  " .. color .. NW.lastRTT .. "ms|r")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Log output
-- ---------------------------------------------------------------------------------------------
-- GetNetStats()'s return order is assumed as bandwidthIn, bandwidthOut, latencyHome,
-- latencyWorld (the long-stable signature across expansions), but hasn't been
-- verified live on this specific client build. If World/Home look swapped or
-- nonsensical on screen, run this and compare against what you'd expect.
function NW.Probe()
    local a, b, c, d = GetNetStats()
    NW.Say("GetNetStats() raw values:")
    DEFAULT_CHAT_FRAME:AddMessage("  1 (assumed bandwidthIn):  " .. tostring(a))
    DEFAULT_CHAT_FRAME:AddMessage("  2 (assumed bandwidthOut): " .. tostring(b))
    DEFAULT_CHAT_FRAME:AddMessage("  3 (assumed latencyHome):  " .. tostring(c))
    DEFAULT_CHAT_FRAME:AddMessage("  4 (assumed latencyWorld): " .. tostring(d))
end

function NW.PrintLog()
    if table.getn(NW.log) == 0 then
        NW.Say("no spikes logged yet.")
        return
    end
    NW.Say("recent connection events:")
    local start = table.getn(NW.log) - 24
    if start < 1 then start = 1 end
    for i = start, table.getn(NW.log) do
        local e = NW.log[i]
        if e.kind == "recovered" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFF00FF7Frecovered|r after " .. e.duration .. "s (" .. e.ms .. "ms)")
        elseif e.kind == "severe" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFF3333SEVERE|r spike: " .. e.ms .. "ms")
        elseif e.kind == "warn" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFFA500warn|r: " .. e.ms .. "ms")
        elseif e.kind == "pingtimeout" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFF3333chat ping lost|r (no reply within " .. string.format("%.1f", e.duration or 0) .. "s)")
        elseif e.kind == "pingsevere" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFF3333chat RTT spike|r: " .. e.ms .. "ms")
        elseif e.kind == "pingwarn" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFFA500chat RTT elevated|r: " .. e.ms .. "ms")
        else
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] " .. tostring(e.kind) .. ": " .. tostring(e.ms) .. "ms")
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")

ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == NW.ADDON_NAME then
        NW.log = NW_Log or {}
        NW.warnThreshold = NW_WarnThreshold or NW.warnThreshold
        NW.severeThreshold = NW_SevereThreshold or NW.severeThreshold
        if NW_PingEnabled ~= nil then NW.pingEnabled = NW_PingEnabled end
        if NW_SampleInterval and NW_SampleInterval >= 0.5 and NW_SampleInterval <= 10 then
            NW.SAMPLE_INTERVAL = NW_SampleInterval
        end
        if NW_PingInterval and NW_PingInterval >= 0.5 and NW_PingInterval <= 10 then
            NW.PING_INTERVAL = NW_PingInterval
        end
        if NW_RosterBroadcast ~= nil then NW.rosterBroadcast = NW_RosterBroadcast end
        NW.CreateFrame()
        NW.UpdateChatRTTDisplay()
    elseif event == "CHAT_MSG_ADDON" then
        -- arg1=prefix, arg2=message, arg3=channel, arg4=sender
        if arg1 == NW.PING_PREFIX and arg4 == UnitName("player") then
            NW.HandlePingReply(arg2)
        elseif arg1 == NW.ROSTER_PREFIX and arg4 ~= UnitName("player") then
            NW.HandleRosterMessage(arg4, arg2)
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        NW.PruneRosterToGroup()
    end
end)

ev:SetScript("OnUpdate", function()
    NW.sampleTimer = NW.sampleTimer + arg1
    if NW.sampleTimer >= NW.SAMPLE_INTERVAL then
        NW.sampleTimer = 0
        NW.Sample()
    end

    NW.CheckPendingPingTimeout() -- unconditional: covers manual "/wdld pingtest" too

    if NW.pingEnabled then
        NW.pingTimer = NW.pingTimer + arg1
        if NW.pingTimer >= NW.PING_INTERVAL then
            NW.pingTimer = 0
            NW.SendPing()
        end
    end

    NW.rosterBroadcastTimer = NW.rosterBroadcastTimer + arg1
    if NW.rosterBroadcastTimer >= NW.ROSTER_BROADCAST_INTERVAL then
        NW.rosterBroadcastTimer = 0
        NW.BroadcastRosterStatus()
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------------------------
-- /wdld is #1 deliberately: AddonManager's auto-discovery (and anything else that
-- scans SLASH_* globals) only picks up each addon's *1 alias, so the primary
-- command needs to be the current brand name, not a legacy alias.
SLASH_NETWATCH1 = "/wdld"
SLASH_NETWATCH2 = "/nw"
SLASH_NETWATCH3 = "/netwatch"
SlashCmdList["NETWATCH"] = function(msg)
    msg = string.lower(msg or "")
    local cmd, arg2, arg3 = "", "", ""
    local i = 1
    for word in string.gfind(msg .. " ", "([^ ]+)") do
        if i == 1 then cmd = word
        elseif i == 2 then arg2 = word
        elseif i == 3 then arg3 = word end
        i = i + 1
    end

    if cmd == "log" then
        NW.PrintLog()
    elseif cmd == "probe" then
        NW.Probe()
    elseif cmd == "pingtest" then
        NW.PingTest()
    elseif cmd == "clear" then
        NW.log = {}
        NW_Log = NW.log
        NW.Say("log cleared.")
    elseif cmd == "set" and arg2 == "warn" then
        local n = tonumber(arg3)
        if n then
            NW.warnThreshold = n
            NW_WarnThreshold = n
            NW.Say("warn threshold set to " .. n .. "ms")
        end
    elseif cmd == "set" and arg2 == "severe" then
        local n = tonumber(arg3)
        if n then
            NW.severeThreshold = n
            NW_SevereThreshold = n
            NW.Say("severe threshold set to " .. n .. "ms")
        end
    elseif cmd == "set" and arg2 == "ping" then
        if arg3 == "on" then
            NW.SetPingEnabled(true)
        elseif arg3 == "off" then
            NW.SetPingEnabled(false)
        else
            NW.Say("usage: /wdld set ping on|off")
        end
    elseif cmd == "set" and arg2 == "roster" then
        if arg3 == "on" then
            NW.SetRosterBroadcast(true)
            NW.Say("sharing your latency with the group: |cFF00FF7Fon|r.")
        elseif arg3 == "off" then
            NW.SetRosterBroadcast(false)
            NW.Say("sharing your latency with the group: |cFFFF5179off|r.")
        else
            NW.Say("usage: /wdld set roster on|off")
        end
    elseif cmd == "roster" then
        NW.ToggleRosterPanel()
    elseif cmd == "" then
        if not NW.frame then NW.CreateFrame() end
        if NW.frame:IsShown() then NW.frame:Hide() else NW.frame:Show() end
    else
        NW.Say("commands: /wdld, /wdld log, /wdld clear, /wdld set warn <ms>, /wdld set severe <ms>, /wdld probe, /wdld pingtest, /wdld set ping on|off, /wdld roster, /wdld set roster on|off")
    end
end
