--[[
    Addon:       WiredbroLagDetector (folder/internal name - ADDON_LOADED and
                 SavedVariables key off this, matching the folder/.toc/.lua
                 names; the internal Lua table is still NW for historical
                 reasons, and it displays in-game as "Wiredbro's DDOS Lag Detector")
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

                 Also broadcasts your own round-trip ping (not GetNetStats() home
                 latency - that's just your own link to the server and stays fine
                 during exactly the kind of trouble this addon exists to catch) to
                 PARTY/RAID (same addon-message mechanism, different prefix) every
                 5s, and listens for the same from anyone else in the group running
                 this addon - a "Group Ping" panel shows everyone's, worst first,
                 so you can see at a glance whether an issue is just you or
                 everyone. Sharing is on by default, but since it rides the ping
                 there's nothing to actually send until the ping itself is turned
                 on (opt-in, needs a guild).

                 Also stamps each party member's ping onto their default party
                 frame (PartyMemberFrame1-4) - or, if pfUI is running (which
                 hides Blizzard's own party frames entirely), onto its pfGroup0-4
                 instead. Vanilla's own default UI has no per-member frames for
                 raid at all, but ShaguTweaks-extras' raid module
                 (ShaguTweaksRaidUnitFrame1-40) and pfUI's (pfRaid1-40) both fill
                 that gap for this server's players, so raid gets the same
                 treatment there too (see RefreshShaguRaidFrameLabels/
                 RefreshPfuiRaidFrameLabels). For anyone with neither addon,
                 raid instead gets the Group Ping panel auto-opened once when
                 you join one (and auto-closed on leaving, unless you'd
                 opened/closed it yourself in the meantime - see
                 HandleGroupTransition).

                 A groupmate's last known ping doesn't just sit there once
                 they go quiet: 3 missed broadcasts in a row (~15s, see
                 ROSTER_MISS_LIMIT) shows their value as a red "--" instead,
                 and 5 missed in a row also fires a one-time chat warning that
                 they've likely lagged out or disconnected (see
                 CheckRosterMissingMembers).

                 A minimap button (see CreateMinimapButton) mirrors the HUD's
                 own left-click-toggle/right-click-settings split.

                 Every ping label's default position can be off depending on
                 which unit-frame addon (if any) someone runs and how they've
                 sized/skinned it - "Unlock ping label position" in settings
                 makes every label draggable (with a visible border, and a
                 mouseover tooltip naming whose label it is - handy in a
                 packed raid grid) so it can be nudged into a clear spot; the
                 nudge is shared across all of them and saved, since dragging
                 is meant as a one-time whole-addon fix, not a per-member
                 layout tool (see CreatePingLabel / SetPingLabelsUnlocked). A
                 "Reset Label Position" button clears it back to 0,0.

                 BETA: "Detect activity (beta)" in settings turns on
                 NW.RecordPassiveActivity - vanilla predates
                 RegisterAddonMessagePrefix, so CHAT_MSG_ADDON fires for every
                 addon's messages, not just this one's, meaning a groupmate's
                 OWN boss mod/threat meter/etc. firing at all is visible as a
                 "still around" signal even if they don't have WDLD. Only
                 fills in where there's no real ping number (see
                 FormatPingLabel), off by default, and not proof of good
                 latency - just that something of theirs got through recently.

    Slash Commands (all equivalent - /wdld, /nw, /netwatch):
        /wdld                  toggle the on-screen monitor
        /wdld hide             hide it explicitly (unlike the toggle, safe to
                               put in a macro regardless of current state)
        /wdld show             show it again
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
        /wdld roster           opens the Group Ping panel
        /wdld set roster on    shares your ping with party/raid (default - still
                               needs the ping itself turned on to have anything to share)
        /wdld set roster off   stops sharing (you can still see others')

    Right-click the monitor to open settings: update interval, ping interval
    (both 0.5s-10s sliders), the ping on/off checkbox, the roster share checkbox,
    and a button to open the Group Ping panel. Ping timeout is computed
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
NW.PING_INTERVAL = 1  -- seconds between automatic background pings (slider-adjustable, 0.5-10s) -
                       -- a few-byte payload, so there's no need to sit near RallyPower's 1-3s
                       -- throttle floor meant for its much larger sync messages
NW.PING_STARTUP_DELAY = 10 -- seconds to hold off the first automatic ping after a reload/login -
                            -- if pingEnabled was already on from a saved setting, firing right away
                            -- adds network/CPU work on top of the reload spike everything else is
                            -- already causing, which is exactly when you'd notice the extra lag most
NW.pingEnabled   = false
NW.pendingPing   = nil -- { sentAt = GetTime(), timeout = seconds, isTest = bool }
NW.pingTimer     = 0
NW.lastRTT       = nil -- ms, nil until we get at least one reply
NW.warnedNoGuild = false -- so the "not in a guild" notice fires once, not every ping cycle
NW.pingMissStreak = 0 -- consecutive timed-out pings; gates chat alerts so one miss doesn't spam - see CheckPendingPingTimeout

-- Group latency sync: broadcasts your own round-trip ping (not home latency -
-- see BroadcastRosterStatus for why) to PARTY/RAID (same addon-message
-- mechanism, proven by Aegis_RallyPower on this exact channel - see
-- Aegis_Sync.lua's RawSend). A separate prefix from the ping so a received
-- roster broadcast (sender = someone else, or your own echoing back) can never
-- be mistaken for a ping reply.
NW.ROSTER_PREFIX            = "WIREDBROLAGRC"
NW.ROSTER_BROADCAST_INTERVAL = 5   -- seconds between broadcasts, independent of the sample interval
NW.ROSTER_MISS_LIMIT        = 3    -- missed broadcast intervals (elapsed time / ROSTER_BROADCAST_INTERVAL,
                                    -- since there's no per-member counter, just a shared fixed interval)
                                    -- before showing red "--" instead of their last known number - mirrors
                                    -- the same "don't trust a stale number" treatment as your own Ping line
NW.rosterBroadcast          = true -- on by default, but actually broadcasting also needs
                                    -- pingEnabled (opt-in, needs a guild) - see BroadcastRosterStatus
NW.rosterBroadcastTimer     = 0
NW.warnedNoPingForRoster    = false -- so the "turn ping on to share" notice fires once, not every broadcast cycle
NW.lastHomeLatency          = nil  -- cached from the most recent Sample(), for the HUD's Home line and for
                                    -- the first ping's timeout estimate (see ComputePingTimeout)
NW.roster        = {}  -- [name] = { latency = ms, time = GetTime() }
NW.rosterOrder   = {}  -- insertion-ordered names, for stable row layout
NW.raidAutoShowDone = false -- so entering a raid auto-opens the Group Ping panel once per
                             -- raid, not every roster update while it's open
NW.rosterAutoShown  = false -- true only while the panel is open because WE opened it (not
                             -- the player) - lets us auto-close it on leaving raid without
                             -- yanking it away from someone who opened it themselves

-- BETA: vanilla 1.12 predates RegisterAddonMessagePrefix (added in a later
-- expansion to cut down on spam), so CHAT_MSG_ADDON fires for every addon
-- message from anyone in range, on any prefix, not just ones this addon
-- knows about. That means a groupmate's OWN boss mod, threat meter, raid
-- sync addon etc. firing at all is visible to us as evidence their client is
-- alive - a free "still around" signal for people who don't have WDLD
-- themselves. It only ever fills in where there's no real ping number (see
-- FormatPingLabel) and it's not proof of good latency, just that something
-- of theirs got through recently - see RecordPassiveActivity.
NW.passiveActivity        = {} -- [name] = GetTime() of the last addon message seen from them, any prefix
NW.passiveActivityEnabled = false
NW.PASSIVE_ACTIVITY_STALE_AFTER = 30 -- seconds before we stop treating them as recently active

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
function NW.Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5179Wiredbro's DDOS Lag Detector|r: " .. msg)
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
        NW.Say("background pinging |cFF00FF7Fon|r - every " .. NW.PING_INTERVAL .. "s.")
    else
        NW.pendingPing = nil
        NW.Say("background pinging |cFFFF5179off|r.")
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
        NW.pingMissStreak = NW.pingMissStreak + 1

        if NW.pingMissStreak >= 2 then
            NW.lastRTT = nil
            NW.UpdateChatRTTDisplay()
        end

        -- A single miss isn't an alarm - stay quiet on the first one, speak up
        -- at 2, then only every 5th after that (5, 10, 15...) so a sustained
        -- outage doesn't spam chat once per ping interval forever. 20+ in a row
        -- escalates the wording - that's no longer "possible message loss", it's
        -- a real disconnect.
        if NW.pingMissStreak == 2 or (NW.pingMissStreak > 2 and math.mod(NW.pingMissStreak, 5) == 0) then
            if NW.pingMissStreak >= 20 then
                NW.Say("|cFFFF3333likely disconnected from the server|r - " .. NW.pingMissStreak ..
                    " pings in a row with no reply")
            else
                NW.Say("|cFFFF3333ping got no reply " .. NW.pingMissStreak .. " times in a row|r (" ..
                    string.format("%.1f", timeout) .. "s timeout) - possible message loss")
            end
        end
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
        "s - invisible, nothing will show up even if this works)...")
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
        NW.Say("|cFFFF3333ping spike: " .. rtt .. "ms|r")
    elseif rtt >= NW.warnThreshold then
        NW.PushLog("pingwarn", rtt)
    end

    if NW.pingMissStreak >= 2 then
        NW.Say("|cFF00FF7Fping back to normal|r (" .. rtt .. "ms) after " .. NW.pingMissStreak .. " missed in a row.")
    end
    NW.pingMissStreak = 0

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
-- Shares the round-trip ping, not GetNetStats()'s home latency - home latency
-- is just your own link to the server and stays fine during exactly the kind
-- of trouble (server-side backup, message loss) this addon exists to catch,
-- so it told the group nothing useful. The ping is opt-in and needs a guild
-- (see SetPingEnabled), so there's nothing to share until that's on and has
-- produced at least one real round trip.
function NW.BroadcastRosterStatus()
    if not NW.rosterBroadcast then return end
    if not NW.pingEnabled or not NW.lastRTT or NW.lastRTT <= 0 then
        if NW.pingEnabled == false and not NW.warnedNoPingForRoster then
            NW.warnedNoPingForRoster = true
            NW.Say("|cFFFFA500sharing your ping with the group needs the round-trip ping turned on|r - run /wdld set ping on.")
        end
        return
    end
    NW.warnedNoPingForRoster = false

    local me = UnitName("player")
    if GetNumRaidMembers() > 0 then
        pcall(SendAddonMessage, NW.ROSTER_PREFIX, tostring(NW.lastRTT), "RAID", me)
    elseif GetNumPartyMembers() > 0 then
        pcall(SendAddonMessage, NW.ROSTER_PREFIX, tostring(NW.lastRTT), "PARTY", me)
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
    NW.RefreshPartyFrameLabels()
    NW.RefreshShaguRaidFrameLabels()
    NW.RefreshPfuiPartyFrameLabels()
    NW.RefreshPfuiRaidFrameLabels()
end

-- Runs every ROSTER_BROADCAST_INTERVAL tick (not just when a message arrives -
-- a groupmate gone quiet produces no messages at all, which is exactly the
-- case this needs to catch). data.alertedMissing gates it to fire once per
-- miss streak rather than every tick past 5 - it's cleared for free the next
-- time HandleRosterMessage replaces that entry with a fresh one.
function NW.CheckRosterMissingMembers()
    for _, name in ipairs(NW.rosterOrder) do
        local data = NW.roster[name]
        if data then
            if NW.RosterMissedCount(data) >= 5 then
                if not data.alertedMissing then
                    data.alertedMissing = true
                    NW.Say("|cFFFF3333" .. name .. " has missed 5+ pings in a row|r - might be lagging or disconnected.")
                end
            end
        end
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

local function IsInMyGroup(name)
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            if UnitName("raid" .. i) == name then return true end
        end
        return false
    end
    local p = GetNumPartyMembers()
    for i = 1, p do
        if UnitName("party" .. i) == name then return true end
    end
    return false
end

-- BETA - see the header note on NW.passiveActivity. Fires for every addon
-- message seen from a groupmate, any prefix, so this can get called a lot
-- during combat (threat meters, boss mods etc. can all fire several times a
-- second) - the display-refresh side of it is debounced to once a second per
-- person so that traffic doesn't turn into 40-frame refresh spam.
function NW.RecordPassiveActivity(name)
    if not name or name == UnitName("player") then return end
    if NW.roster[name] then return end -- real WDLD ping data already covers them
    if not IsInMyGroup(name) then return end

    local last = NW.passiveActivity[name]
    NW.passiveActivity[name] = GetTime()
    if last and (GetTime() - last) < 1 then return end

    NW.RefreshPartyFrameLabels()
    NW.RefreshShaguRaidFrameLabels()
    NW.RefreshPfuiPartyFrameLabels()
    NW.RefreshPfuiRaidFrameLabels()
end

function NW.SetPassiveActivityDetection(enabled)
    NW.passiveActivityEnabled = enabled
    NW_PassiveActivity = enabled
    if not enabled then NW.passiveActivity = {} end
    if NW.settingsFrame and NW.settingsFrame.passiveCheck then
        NW.settingsFrame.passiveCheck:SetChecked(enabled)
    end
end

-- Shared by every per-member ping display (party/raid frame labels, the
-- Group Ping panel) so the missed-broadcast logic only lives in one place.
function NW.RosterMissedCount(data)
    return math.floor((GetTime() - data.time) / NW.ROSTER_BROADCAST_INTERVAL)
end

local function FormatPingLabel(name)
    local data = name and NW.roster[name]
    if data then
        if NW.RosterMissedCount(data) >= NW.ROSTER_MISS_LIMIT then
            return "|cFFFF3333--|r"
        end
        return NW.ColorFor(data.latency, NW.warnThreshold, NW.severeThreshold) .. data.latency .. "ms|r"
    end

    -- BETA fallback: no real ping number for them (no WDLD, or they haven't
    -- turned their own ping on), but something of theirs got through
    -- recently - see NW.passiveActivity. Deliberately NOT a color/threshold
    -- like a real ping, since it isn't measuring the same thing.
    if NW.passiveActivityEnabled and name then
        local seen = NW.passiveActivity[name]
        if seen and (GetTime() - seen) <= NW.PASSIVE_ACTIVITY_STALE_AFTER then
            return "|cFF00FF7Factive|r"
        end
    end

    return ""
end

-- Every ping label (across every unit-frame addon this file supports) lives
-- in this list so the unlock/drag/offset system below can act on all of them
-- at once, regardless of which addon actually created the underlying frame.
NW.pingLabelHolders   = {}
NW.pingLabelsUnlocked = false -- edit mode - not persisted, always starts locked after a reload
NW.pingLabelOffsetX   = 0     -- shared nudge applied on top of every label's own default position -
NW.pingLabelOffsetY   = 0     -- see settings: "Unlock ping label position"

-- Builds one ping label consistently: a small holder frame (needed both for
-- FrameLevel elevation on the densely-layered addons, and now for drag
-- support) plus the FontString itself. basePoint/baseRelPoint/baseX/baseY is
-- that label's own default position for this frame type - the shared offset
-- is added on top of it, never replaces it, so unlocking and dragging never
-- loses track of a sane fallback position.
local function CreatePingLabel(frame, basePoint, baseRelPoint, baseX, baseY, justify, tinyFont)
    local holder = CreateFrame("Frame", nil, frame)
    holder:SetWidth(60); holder:SetHeight(14)
    holder:SetFrameLevel(200)
    holder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 8, edgeSize = 8
    })
    holder:SetBackdropBorderColor(1, 0.82, 0, 0) -- invisible until unlocked - see SetPingLabelsUnlocked
    holder.basePoint, holder.baseRelPoint, holder.baseX, holder.baseY = basePoint, baseRelPoint, baseX, baseY

    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if tinyFont then fs:SetFont((fs:GetFont()), 8, "THINOUTLINE") end
    fs:SetAllPoints(holder)
    fs:SetJustifyH(justify)
    holder.text = fs

    -- Only shown while unlocked - with up to 40 tiny, densely-packed raid
    -- labels, it's not always obvious which one belongs to who while you're
    -- repositioning them. holder.memberName is kept current by whichever
    -- Refresh*FrameLabels function owns this label.
    holder:SetScript("OnEnter", function()
        if not NW.pingLabelsUnlocked then return end
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText(this.memberName or "(empty)")
        GameTooltip:Show()
    end)
    holder:SetScript("OnLeave", function() GameTooltip:Hide() end)

    holder:SetMovable(true)
    holder:RegisterForDrag("LeftButton")
    holder:SetScript("OnDragStart", function()
        if not NW.pingLabelsUnlocked then return end
        this:StartMoving()
        -- StartMoving()/StopMovingOrSizing() re-anchors the frame relative to
        -- UIParent in screen-absolute pixels, discarding its original
        -- frame-relative anchor - so GetPoint() after the drag can't be
        -- compared against this holder's tiny frame-relative baseX/baseY
        -- (that produced a huge bogus offset, moving everything ~1/10 of the
        -- screen). Tracking the actual cursor movement instead and adding
        -- that delta to whatever the offset already was keeps everything in
        -- the same, small, frame-relative coordinate space.
        this.dragStartCursorX, this.dragStartCursorY = GetCursorPosition()
        this.dragStartOffsetX, this.dragStartOffsetY = NW.pingLabelOffsetX, NW.pingLabelOffsetY
    end)
    holder:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        if this.dragStartCursorX then
            local px, py = GetCursorPosition()
            local scale = this:GetEffectiveScale()
            NW.pingLabelOffsetX = this.dragStartOffsetX + (px - this.dragStartCursorX) / scale
            NW.pingLabelOffsetY = this.dragStartOffsetY + (py - this.dragStartCursorY) / scale
            NW_PingLabelOffsetX = NW.pingLabelOffsetX
            NW_PingLabelOffsetY = NW.pingLabelOffsetY
        end
        NW.RepositionPingLabels() -- re-anchor every label (including this one) using the corrected offset
    end)

    table.insert(NW.pingLabelHolders, holder)
    NW.RepositionPingLabel(holder)
    return holder
end

function NW.RepositionPingLabel(holder)
    holder:ClearAllPoints()
    holder:SetPoint(holder.basePoint, holder:GetParent(), holder.baseRelPoint,
        holder.baseX + NW.pingLabelOffsetX, holder.baseY + NW.pingLabelOffsetY)
end

function NW.RepositionPingLabels()
    for _, holder in ipairs(NW.pingLabelHolders) do
        NW.RepositionPingLabel(holder)
    end
end

-- Toggled from settings: while unlocked, every label becomes draggable (with
-- a visible border so there's something to actually grab) instead of passing
-- clicks through to the unit frame underneath.
function NW.SetPingLabelsUnlocked(unlocked)
    NW.pingLabelsUnlocked = unlocked
    for _, holder in ipairs(NW.pingLabelHolders) do
        holder:EnableMouse(unlocked)
        if unlocked then
            holder:SetBackdropBorderColor(1, 0.82, 0, 1)
        else
            holder:SetBackdropBorderColor(1, 0.82, 0, 0)
        end
    end
end

-- Vanilla's default UI only gives per-member unit frames for PARTY
-- (PartyMemberFrame1-4, always exist, just hidden when unused) - raid has no
-- default per-member frames at all, that's a later-expansion feature. So this
-- can only stamp ping onto the party frames; see RefreshShaguRaidFrameLabels
-- and HandleGroupTransition for how raid is covered instead.
function NW.RefreshPartyFrameLabels()
    for i = 1, 4 do
        local frame = getglobal("PartyMemberFrame" .. i)
        if frame then
            local unit = "party" .. i
            local holder = frame.wdldPingHolder
            if UnitExists(unit) then
                if not holder then
                    holder = CreatePingLabel(frame, "TOPLEFT", "TOPLEFT", 4, 4, "LEFT", false)
                    frame.wdldPingHolder = holder
                end
                local name = UnitName(unit)
                holder.memberName = name
                holder.text:SetText(FormatPingLabel(name))
            elseif holder then
                holder.memberName = nil
                holder.text:SetText("")
            end
        end
    end
end

-- ShaguTweaks-extras' raid frames (mods\raid.lua) are what this server's
-- players actually use for raid, since vanilla's own default UI has none at
-- all. Its unit buttons are named ShaguTweaksRaidUnitFrame1-40, but unlike
-- PartyMemberFrameN they're NOT fixed to a raid index - frame.unitstr gets
-- reassigned as the roster/subgroups change (see that file's CreateUnitFrame/
-- module.enable), so it has to be read fresh each time rather than assumed
-- from the frame's own number. No-ops harmlessly if that addon isn't
-- installed/enabled - ShaguTweaksRaidUnitFrame1 simply won't exist.
function NW.RefreshShaguRaidFrameLabels()
    for i = 1, 40 do
        local frame = getglobal("ShaguTweaksRaidUnitFrame" .. i)
        if frame then
            local unit = frame.unitstr
            local holder = frame.wdldPingHolder
            if unit and UnitExists(unit) then
                if not holder then
                    -- Can't just create the FontString straight on `frame` - its
                    -- border/highlight decorations are separate child FRAMES with
                    -- their own explicit FrameLevel (32/128), which render above
                    -- anything at the button's own (lower) level regardless of
                    -- draw layer. CreatePingLabel's holder (elevated to 200) is
                    -- what makes the label actually visible instead of hidden
                    -- underneath them.
                    holder = CreatePingLabel(frame, "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 1, "RIGHT", true)
                    frame.wdldPingHolder = holder
                end
                local name = UnitName(unit)
                holder.memberName = name
                holder.text:SetText(FormatPingLabel(name))
            elseif holder then
                holder.memberName = nil
                holder.text:SetText("")
            end
        end
    end
end

-- pfUI (modules\group.lua) replaces Blizzard's party frames entirely - it
-- explicitly hides and neutralizes PartyMemberFrame1-4 - so RefreshPartyFrameLabels
-- has nothing to attach to for anyone running it. pfUI names its own party
-- buttons pfGroup0 (yourself) through pfGroup4 (party1-4), fixed to those slots
-- (not reassigned like raid), per modules\group.lua and api\unitframes.lua's
-- CreateUnitFrame (fname = "Group"..id for a "Party"-type frame).
function NW.RefreshPfuiPartyFrameLabels()
    for i = 0, 4 do
        local frame = getglobal("pfGroup" .. i)
        if frame then
            local unit = frame.label and frame.id and (frame.label .. frame.id) or nil
            local holder = frame.wdldPingHolder
            if unit and unit ~= "player" and UnitExists(unit) then
                if not holder then
                    -- Same reasoning as the Shagu raid frames: pfUI's frames are
                    -- densely layered with icon/glow child frames at their own
                    -- explicit FrameLevels (up to 48). Floated above the frame's
                    -- top edge entirely (rather than tucked in a corner) since
                    -- party frames here have generous vertical spacing (75px).
                    holder = CreatePingLabel(frame, "BOTTOMRIGHT", "TOPRIGHT", -1, 4, "RIGHT", true)
                    frame.wdldPingHolder = holder
                end
                local name = UnitName(unit)
                holder.memberName = name
                holder.text:SetText(FormatPingLabel(name))
            elseif holder then
                holder.memberName = nil
                holder.text:SetText("")
            end
        end
    end
end

-- pfUI (modules\raid.lua) names its raid buttons pfRaid1-40, and like Shagu's
-- (and vanilla raid rosters generally) they're NOT fixed to a raid index -
-- frame.id gets reassigned as subgroups/roster change (see that file's
-- SetRaidIndex), so the unit ("raid"..id, from frame.label..frame.id per
-- api\unitframes.lua's own convention used throughout that file) has to be
-- read fresh each refresh.
function NW.RefreshPfuiRaidFrameLabels()
    for i = 1, 40 do
        local frame = getglobal("pfRaid" .. i)
        if frame then
            local unit = frame.label and frame.id and (frame.label .. frame.id) or nil
            local holder = frame.wdldPingHolder
            if unit and UnitExists(unit) then
                if not holder then
                    -- Raised above the frame's top edge rather than tucked in the
                    -- corner - it was sitting right on the border art and getting
                    -- visually clipped by it. Kept modest (not a full float-above
                    -- like the party version): raid.lua stacks these only 1px
                    -- apart vertically, so going too far risks overlapping the
                    -- frame above it in a dense raid instead.
                    holder = CreatePingLabel(frame, "TOPRIGHT", "TOPRIGHT", -1, 4, "RIGHT", true)
                    frame.wdldPingHolder = holder
                end
                local name = UnitName(unit)
                holder.memberName = name
                holder.text:SetText(FormatPingLabel(name))
            elseif holder then
                holder.memberName = nil
                holder.text:SetText("")
            end
        end
    end
end

-- Vanilla's own default UI has no per-member raid frames at all to stamp ping
-- onto - but ShaguTweaks-extras' and pfUI's raid modules (see
-- RefreshShaguRaidFrameLabels/RefreshPfuiRaidFrameLabels) fill that gap for
-- anyone running either, which covers this server's players. For anyone with
-- NEITHER, the next best thing is auto-popping the Group Ping panel once per
-- raid you join. NW.rosterAutoShown tracks whether WE opened it, so if the
-- player closes it (or opens/closes it themselves via /wdld roster) we leave
-- it alone for the rest of that raid instead of yanking it back open or shut.
function NW.HandleGroupTransition()
    if GetNumRaidMembers() > 0 then
        if not NW.raidAutoShowDone then
            NW.raidAutoShowDone = true
            if not getglobal("ShaguTweaksRaidUnitFrame1") and not getglobal("pfRaid1") then
                if not NW.settingsFrame then NW.CreateSettingsFrame() end
                if not NW.rosterFrame then NW.CreateRosterFrame() end
                if not NW.rosterFrame:IsShown() then
                    NW.RefreshRosterPanel()
                    NW.rosterFrame:Show()
                    NW.rosterAutoShown = true
                end
            end
        end
    else
        NW.raidAutoShowDone = false
        if NW.rosterAutoShown and NW.rosterFrame and NW.rosterFrame:IsShown() then
            NW.rosterFrame:Hide()
        end
        NW.rosterAutoShown = false
    end

    NW.RefreshPartyFrameLabels()
    NW.RefreshShaguRaidFrameLabels()
    NW.RefreshPfuiPartyFrameLabels()
    NW.RefreshPfuiRaidFrameLabels()
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
    f:SetWidth(170); f:SetHeight(72) -- rttText sits at y=-44; the old 58 left only 14px below it, clipping descenders against the border
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -4)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.75)

    -- Tinting the backdrop's own bgFile with SetBackdropColor multiplies against
    -- that texture's (fairly dark) baked-in art, so an amber/red alarm tint there
    -- barely reads as different from the default black fill. A flat solid-color
    -- texture layered on top, alpha-controlled separately from the backdrop, gives
    -- a real visible wash instead - see UpdateChatRTTDisplay.
    local alarmTex = f:CreateTexture(nil, "BORDER")
    alarmTex:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -5)
    alarmTex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
    alarmTex:SetTexture(0, 0, 0, 0)
    f.alarmTex = alarmTex

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
        GameTooltip:SetText("Wiredbro's DDOS Lag Detector")
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

-- Standard drag-around-the-minimap-edge button, positioned by angle rather
-- than x/y so it stays glued to the ring regardless of minimap size/scale.
-- Left-click toggles the HUD, right-click opens settings - same split as
-- right-clicking the HUD itself, so both entry points behave the same way.
function NW.CreateMinimapButton()
    local btn = CreateFrame("Button", "NW_MinimapButton", Minimap)
    btn:SetWidth(31); btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetToplevel(true)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    btn.icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(54); border:SetHeight(54)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            NW.ToggleSettings()
        else
            if not NW.frame then NW.CreateFrame() end
            if NW.frame:IsShown() then NW.frame:Hide() else NW.frame:Show() end
        end
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Wiredbro's DDOS Lag Detector")
        GameTooltip:AddLine("Left-click: show/hide the monitor", 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function() this.dragging = true end)
    btn:SetScript("OnDragStop", function() this.dragging = false end)
    btn:SetScript("OnUpdate", function()
        if not this.dragging then return end
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        NW.minimapAngle = math.atan2(py - my, px - mx)
        NW.PositionMinimapButton()
        NW_MinimapAngle = NW.minimapAngle
    end)

    NW.minimapButton = btn
    NW.PositionMinimapButton()
end

function NW.PositionMinimapButton()
    if not NW.minimapButton then return end
    local angle = NW.minimapAngle or math.rad(215) -- default: bottom-left of the ring
    local radius = 80
    NW.minimapButton:ClearAllPoints()
    NW.minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
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

-- Makes a frame drag-to-move (same behavior as the main HUD) and persists its
-- position under a SavedVariable, addressed here by plain global name via _G,
-- so it survives reloads - see NW_FramePos on the main HUD for the original
-- version of this pattern. applyDefaultPoint only runs the first time there's
-- no saved position yet; once the user drags it, their spot always wins after.
local function MakeMovable(frame, posVarName, applyDefaultPoint)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        _G[posVarName] = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    local saved = _G[posVarName]
    if saved then
        frame:ClearAllPoints()
        frame:SetPoint(saved.point or "CENTER", UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
    else
        applyDefaultPoint()
    end
end

function NW.CreateSettingsFrame()
    local s = CreateFrame("Frame", "NW_SettingsFrame", UIParent)
    s:SetWidth(200); s:SetHeight(292)
    s:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    s:SetBackdropColor(0, 0, 0, 0.85)

    -- Default position tucks the panel below the main HUD, but if the HUD sits
    -- low enough on screen that there's no room below it, this opens the panel
    -- above the HUD instead - previously it always opened below and could end
    -- up entirely off the bottom of the screen when the HUD was parked low.
    MakeMovable(s, "NW_SettingsPos", function()
        s:ClearAllPoints()
        local roomBelow = (NW.frame:GetBottom() or 0) - 6
        if roomBelow >= 292 then
            s:SetPoint("TOP", NW.frame, "BOTTOM", 0, -6)
        else
            s:SetPoint("BOTTOM", NW.frame, "TOP", 0, 6)
        end
    end)

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
    pingLabel:SetText("Round-trip ping")
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
    rosterLabel:SetText("Share my ping with group")
    s.rosterLabel = rosterLabel

    local rosterBtn = CreateFrame("Button", "NW_RosterOpenBtn", s, "UIPanelButtonTemplate")
    rosterBtn:SetWidth(140); rosterBtn:SetHeight(20)
    rosterBtn:SetPoint("TOP", s, "TOP", 0, -158)
    rosterBtn:SetText("Group Ping")
    rosterBtn:SetScript("OnClick", function() NW.ToggleRosterPanel() end)
    s.rosterBtn = rosterBtn

    local unlockCheck = CreateFrame("CheckButton", "NW_UnlockPingLabelsCheck", s, "UICheckButtonTemplate")
    unlockCheck:SetWidth(20); unlockCheck:SetHeight(20)
    unlockCheck:SetPoint("TOPLEFT", s, "TOPLEFT", 14, -190)
    unlockCheck:SetChecked(NW.pingLabelsUnlocked)
    unlockCheck:SetScript("OnClick", function()
        NW.SetPingLabelsUnlocked(this:GetChecked() and true or false)
    end)
    s.unlockCheck = unlockCheck

    local unlockLabel = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    unlockLabel:SetPoint("LEFT", unlockCheck, "RIGHT", 4, 0)
    unlockLabel:SetText("Unlock ping label position")
    s.unlockLabel = unlockLabel

    local resetBtn = CreateFrame("Button", "NW_ResetPingLabelsBtn", s, "UIPanelButtonTemplate")
    resetBtn:SetWidth(140); resetBtn:SetHeight(18)
    resetBtn:SetPoint("TOP", s, "TOP", 0, -216)
    resetBtn:SetText("Reset Label Position")
    resetBtn:SetScript("OnClick", function()
        NW.pingLabelOffsetX, NW.pingLabelOffsetY = 0, 0
        NW_PingLabelOffsetX, NW_PingLabelOffsetY = 0, 0
        NW.RepositionPingLabels()
        NW.Say("ping label position reset to default.")
    end)
    s.resetBtn = resetBtn

    local passiveCheck = CreateFrame("CheckButton", "NW_PassiveActivityCheck", s, "UICheckButtonTemplate")
    passiveCheck:SetWidth(20); passiveCheck:SetHeight(20)
    passiveCheck:SetPoint("TOPLEFT", s, "TOPLEFT", 14, -244)
    passiveCheck:SetChecked(NW.passiveActivityEnabled)
    passiveCheck:SetScript("OnClick", function()
        NW.SetPassiveActivityDetection(this:GetChecked() and true or false)
    end)
    passiveCheck:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Beta: detect activity from other addons", 1, 1, 1)
        GameTooltip:AddLine("Vanilla lets any addon see any other addon's", 1, 1, 1, true)
        GameTooltip:AddLine("messages, so this shows groupmates as |cFF00FF7Factive|r", 1, 1, 1, true)
        GameTooltip:AddLine("if their OWN addons (boss mods, threat meters,", 1, 1, 1, true)
        GameTooltip:AddLine("etc.) fire recently - works even if they don't", 1, 1, 1, true)
        GameTooltip:AddLine("have WDLD. Only fills in where there's no real", 1, 1, 1, true)
        GameTooltip:AddLine("ping number, and mostly needs combat to see", 1, 1, 1, true)
        GameTooltip:AddLine("anything - it's not proof of good latency.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passiveCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    s.passiveCheck = passiveCheck

    local passiveLabel = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    passiveLabel:SetPoint("LEFT", passiveCheck, "RIGHT", 4, 0)
    passiveLabel:SetText("Detect activity (beta)")
    s.passiveLabel = passiveLabel

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
        NW.settingsFrame.unlockCheck:SetChecked(NW.pingLabelsUnlocked)
        NW.settingsFrame.passiveCheck:SetChecked(NW.passiveActivityEnabled)
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
    r:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    r:SetBackdropColor(0, 0, 0, 0.85)

    -- Same off-screen problem as the settings panel, just sideways: this used
    -- to always open to the right of the settings panel, which can run off the
    -- edge of the screen depending on where settings ended up. Top edges are
    -- aligned rather than vertically centered since this panel is much taller
    -- than the settings one, to reduce the chance of it also running off top.
    MakeMovable(r, "NW_RosterPos", function()
        r:ClearAllPoints()
        local roomRight = (UIParent:GetWidth() or 0) - (NW.settingsFrame:GetRight() or 0) - 8
        if roomRight >= 220 then
            r:SetPoint("TOPLEFT", NW.settingsFrame, "TOPRIGHT", 8, 0)
        else
            r:SetPoint("TOPRIGHT", NW.settingsFrame, "TOPLEFT", -8, 0)
        end
    end)

    r:Hide()

    local title = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", r, "TOP", 0, -6)
    title:SetText("Group Ping")

    local close = CreateFrame("Button", "NW_RosterClose", r, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", r, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        NW.rosterAutoShown = false -- player closed it themselves, don't treat as our auto-show anymore
        r:Hide()
    end)

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
            row.nameText:SetText(entry.name)
            if NW.RosterMissedCount(entry) >= NW.ROSTER_MISS_LIMIT then
                row.msText:SetText("|cFFFF3333--|r")
            else
                row.msText:SetText(NW.ColorFor(entry.latency, NW.warnThreshold, NW.severeThreshold) .. entry.latency .. "ms|r")
            end
            row:Show()
        end
    end
end

function NW.ToggleRosterPanel()
    if not NW.settingsFrame then NW.CreateSettingsFrame() end
    if not NW.rosterFrame then NW.CreateRosterFrame() end
    NW.rosterAutoShown = false -- the player is driving this now, not our raid auto-show/hide
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

-- Ping used to be colored against the same fixed warn/severe thresholds as
-- Home latency, but the two measure different things (a message-level round
-- trip vs GetNetStats()'s own reading) - someone with a consistently slow but
-- stable connection would sit permanently yellow/red for no real reason.
-- Comparing ping against your OWN current home latency instead flags when the
-- round trip is disproportionately worse than your baseline, which is the
-- actual signal something's wrong (1.5x home = yellow, 2.5x home = red).
function NW.ColorForPing(rtt)
    if NW.lastHomeLatency and NW.lastHomeLatency > 0 then
        local ratio = rtt / NW.lastHomeLatency
        if ratio >= 2.5 then return "|cFFFF3333"
        elseif ratio >= 1.5 then return "|cFFFFA500"
        else return "|cFF00FF7F" end
    end
    return NW.ColorFor(rtt, NW.warnThreshold, NW.severeThreshold)
end

function NW.UpdateDisplay(latencyHome)
    if not NW.frame then return end

    -- default to 0 rather than leaving this nil - a nil here (e.g. right at
    -- login) would error on the >= comparisons in ColorFor and, worse, leave
    -- the box blank.
    local h = latencyHome or 0

    local homeColor = NW.ColorFor(h, NW.warnThreshold, NW.severeThreshold)
    NW.frame.homeText:SetText("Home:  " .. homeColor .. h .. "ms|r")

    NW.UpdateStatusText()
    NW.UpdateChatRTTDisplay()
end

-- The top-right status word used to reflect NW.state (the GetNetStats() latency
-- reading) only, so it kept saying "Normal" even while the chat round-trip ping
-- was actively timing out - latencyHome can look fine while message delivery
-- itself is failing. A live miss streak now takes priority over the latency
-- state, since a sustained ping failure is a stronger signal of real trouble.
function NW.UpdateStatusText()
    if not NW.frame then return end

    -- "Likely Disconnected from server" (the full phrase used in the chat alert -
    -- see CheckPendingPingTimeout) doesn't fit this compact top-right label at
    -- any reasonable font size without overlapping the title, so this stays
    -- short; the escalation still reads clearly against "Likely DC".
    local statusWord, statusColor = "Normal", "|cFF00FF7F"
    if NW.pingMissStreak >= 20 then
        statusWord, statusColor = "Disconnected?", "|cFFFF3333"
    elseif NW.pingMissStreak >= 5 then
        statusWord, statusColor = "Likely DC", "|cFFFF3333"
    elseif NW.pingMissStreak >= 2 then
        statusWord, statusColor = "Degraded", "|cFFFFA500"
    elseif NW.state == "severe" then
        statusWord, statusColor = "SEVERE", "|cFFFF3333"
    elseif NW.state == "warn" then
        statusWord, statusColor = "Warn", "|cFFFFA500"
    end
    NW.frame.statusText:SetText(statusColor .. statusWord .. "|r")
end

-- Separate from UpdateDisplay because a ping reply can arrive independently of a
-- GetNetStats() sample tick, and shouldn't require (or overwrite) the world/home
-- values to refresh just its own line.
function NW.UpdateChatRTTDisplay()
    if not NW.frame then return end
    if not NW.pingEnabled then
        NW.frame.rttText:SetText("Ping:  |cFF888888off|r")
    elseif not NW.lastRTT then
        NW.frame.rttText:SetText("Ping:  |cFF888888--|r")
    else
        local color = NW.ColorForPing(NW.lastRTT)
        NW.frame.rttText:SetText("Ping:  " .. color .. NW.lastRTT .. "ms|r")
    end

    -- 2+ misses in a row washes the window amber (still recoverable, matches the
    -- chat alert threshold), 5+ escalates to red for a sustained outage. Driven
    -- through f.alarmTex (a flat solid-color overlay, see CreateFrame) rather than
    -- SetBackdropColor, since tinting the backdrop's own dark bgFile art barely
    -- showed up. Text colors (white title, grey/green/orange/red status text)
    -- still hold up fine against these alpha levels.
    if NW.pingMissStreak >= 5 then
        NW.frame.alarmTex:SetTexture(0.85, 0.05, 0.05, 0.6)
        NW.frame:SetBackdropBorderColor(1, 0.2, 0.2, 1)
    elseif NW.pingMissStreak >= 2 then
        NW.frame.alarmTex:SetTexture(0.95, 0.65, 0, 0.6)
        NW.frame:SetBackdropBorderColor(1, 0.82, 0, 1)
    else
        NW.frame.alarmTex:SetTexture(0, 0, 0, 0)
        NW.frame:SetBackdropBorderColor(1, 1, 1, 1)
    end

    NW.UpdateStatusText()
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
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFF3333ping lost|r (no reply within " .. string.format("%.1f", e.duration or 0) .. "s)")
        elseif e.kind == "pingsevere" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFF3333ping spike|r: " .. e.ms .. "ms")
        elseif e.kind == "pingwarn" then
            DEFAULT_CHAT_FRAME:AddMessage("  [" .. e.time .. "] |cFFFFA500ping elevated|r: " .. e.ms .. "ms")
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
        if NW.pingEnabled then
            -- Coming back from a saved "on" state, not a fresh manual enable -
            -- see PING_STARTUP_DELAY. SetPingEnabled's own "fire almost
            -- immediately" behavior is untouched for an explicit /wdld set ping on.
            NW.pingTimer = -NW.PING_STARTUP_DELAY
        end
        if NW_SampleInterval and NW_SampleInterval >= 0.5 and NW_SampleInterval <= 10 then
            NW.SAMPLE_INTERVAL = NW_SampleInterval
        end
        if NW_PingInterval and NW_PingInterval >= 0.5 and NW_PingInterval <= 10 then
            NW.PING_INTERVAL = NW_PingInterval
        end
        if NW_RosterBroadcast ~= nil then NW.rosterBroadcast = NW_RosterBroadcast end
        if NW_PassiveActivity ~= nil then NW.passiveActivityEnabled = NW_PassiveActivity end
        if NW_PingLabelOffsetX then NW.pingLabelOffsetX = NW_PingLabelOffsetX end
        if NW_PingLabelOffsetY then NW.pingLabelOffsetY = NW_PingLabelOffsetY end
        if NW_MinimapAngle then NW.minimapAngle = NW_MinimapAngle end
        NW.CreateFrame()
        NW.CreateMinimapButton()
        NW.UpdateChatRTTDisplay()
    elseif event == "CHAT_MSG_ADDON" then
        -- arg1=prefix, arg2=message, arg3=channel, arg4=sender
        if arg1 == NW.PING_PREFIX and arg4 == UnitName("player") then
            NW.HandlePingReply(arg2)
        elseif arg1 == NW.ROSTER_PREFIX and arg4 ~= UnitName("player") then
            NW.HandleRosterMessage(arg4, arg2)
        end
        if NW.passiveActivityEnabled then
            NW.RecordPassiveActivity(arg4)
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        NW.PruneRosterToGroup()
        NW.HandleGroupTransition()
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
        NW.CheckRosterMissingMembers()
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
            NW.Say("sharing your ping with the group: |cFF00FF7Fon|r.")
        elseif arg3 == "off" then
            NW.SetRosterBroadcast(false)
            NW.Say("sharing your ping with the group: |cFFFF5179off|r.")
        else
            NW.Say("usage: /wdld set roster on|off")
        end
    elseif cmd == "roster" then
        NW.ToggleRosterPanel()
    elseif cmd == "hide" then
        if not NW.frame then NW.CreateFrame() end
        NW.frame:Hide()
    elseif cmd == "show" then
        if not NW.frame then NW.CreateFrame() end
        NW.frame:Show()
    elseif cmd == "" then
        if not NW.frame then NW.CreateFrame() end
        if NW.frame:IsShown() then NW.frame:Hide() else NW.frame:Show() end
    else
        NW.Say("commands: /wdld, /wdld hide, /wdld show, /wdld log, /wdld clear, /wdld set warn <ms>, /wdld set severe <ms>, /wdld probe, /wdld pingtest, /wdld set ping on|off, /wdld roster, /wdld set roster on|off")
    end
end
