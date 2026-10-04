--[[ test_background.lua -- what this addon reports while its window is in the
     background. Run from the repo root:
       lua tools/test_background.lua [path/to/addon.lua]

     The addon's whole job is telling you when the SERVER is in trouble. While
     you are alt-tabbed to another box, WoW throttles this window to a handful
     of frames a second, and that throttle looks exactly like trouble from the
     inside:

       - an addon message is handed to Lua during a frame, not when the packet
         lands, so a reply that arrived instantly is only noticed up to a whole
         frame later and the round trip reads that much longer;
       - with the default 1s ping timeout and one frame in that second, the
         reply had nowhere to be noticed at all and the ping is called lost;
       - broadcasts from the other box land in frames we never ran, so it looks
         like it stopped talking.

     None of that is the network. These checks pin the discounting that keeps
     the addon from blaming the server for this client being asleep. ]]

local Stub = dofile("tools/wow_stub.lua")
local ADDON_PATH = arg[1] or "WiredbroLagDetector.lua"

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) ..
            ", wanted " .. tostring(want))
    end
end

local NOW = 1000
local said = {}

local function freshWorld()
    Stub.Reset()
    GetNetStats = function() return 0, 0, 42, 0 end
    SendAddonMessage = function() end
    GetCVar = function() return "N'Zoth" end
    GetRealmName = function() return "N'Zoth" end
    GetGuildInfo = function() return "A Guild" end
    date = function() return "12:00:00" end
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
    GetTime = function() return NOW end
    Stub.SetRoster({ player = "Salahaja", party = {} })

    said = {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(said, m) end }
    ChatFrame1 = DEFAULT_CHAT_FRAME

    NW = nil
    dofile(ADDON_PATH)
    return NW
end

local function heard(text)
    for i = 1, table.getn(said) do
        if string.find(said[i], text, 1, true) then return true end
    end
    return false
end

--- Pretend the window has been rendering at this many frames a second.
local function framesAt(nw, fps, count)
    local gap = 1 / fps
    for _ = 1, (count or nw.FRAME_GAP_KEEP) do
        nw.NoteFrame(gap)
    end
    return gap
end

print("\nWDLD: what it reports while alt-tabbed away\n")

----------------------------------------------------------------------
-- the error bar itself
----------------------------------------------------------------------
local nw = freshWorld()
framesAt(nw, 60)
check("a foreground client has a negligible frame gap", nw.FrameGap() < 0.05, true)
check("and is not considered starved", nw.FrameStarved(), false)

framesAt(nw, 5)
check("a background client's gap is large", nw.FrameGap() >= 0.19, true)
check("and it knows it was not looking", nw.FrameStarved(), true)

--[[ The worst of the recent frames, not the mean. This is an error bound: a
     reply could have waited out the longest frame, and averaging would quietly
     understate that. ]]
nw.frameGaps = {}
nw.NoteFrame(0.016)
nw.NoteFrame(0.9)
nw.NoteFrame(0.016)
check("one long frame among short ones still counts", nw.FrameGap(), 0.9)

----------------------------------------------------------------------
-- a ping that was answered on time
----------------------------------------------------------------------
--[[ A warn-level round trip announces nothing in chat -- it only writes to the
     log -- so the log is what has to be checked. Asserting on chat text here
     passed with the discount removed, which is to say it tested nothing. ]]
local function logged(nw, kind)
    for i = 1, table.getn(nw.log or {}) do
        if nw.log[i].kind == kind then return true end
    end
    return false
end

--[[ The same 600ms round trip, judged twice.

     At 5fps, 200ms of it is this client not looking, leaving 400ms of network
     -- under the 500ms threshold, so nothing is recorded against the server.
     In the foreground the same figure is almost all network and is. ]]
nw = freshWorld()
framesAt(nw, 5)
nw.warnThreshold, nw.severeThreshold = 500, 1500
nw.log = {}
nw.pendingPing = { sentAt = NOW, nonce = "1", timeout = 1 }
NOW = NOW + 0.6
nw.HandlePingReply("1")
check("the round trip is still reported as what it took", nw.lastRTT, 600)
check("but it is not logged as elevated", logged(nw, "pingwarn"), false)
check("nor as a spike", logged(nw, "pingsevere"), false)

-- The same figure with the window in front IS the network, and must be logged.
nw = freshWorld()
framesAt(nw, 60)
nw.warnThreshold, nw.severeThreshold = 500, 1500
nw.log = {}
nw.pendingPing = { sentAt = NOW, nonce = "1", timeout = 1 }
NOW = NOW + 0.6
nw.HandlePingReply("1")
check("the same 600ms in the foreground is logged as elevated",
    logged(nw, "pingwarn"), true)

--[[ And a spike big enough to survive the discount must still get through
     while backgrounded, or the addon goes deaf exactly when a real outage
     starts during a long alt-tab. ]]
nw = freshWorld()
framesAt(nw, 5)
nw.warnThreshold, nw.severeThreshold = 500, 1500
nw.log = {}
said = {}
nw.pendingPing = { sentAt = NOW, nonce = "1", timeout = 1 }
NOW = NOW + 3.0
nw.HandlePingReply("1")
check("a spike larger than the frame gap still gets through",
    logged(nw, "pingsevere"), true)
check("and is still announced", heard("ping spike"), true)

----------------------------------------------------------------------
-- a ping that had nowhere to be noticed
----------------------------------------------------------------------
--[[ The one that fired every second while alt-tabbed. The default timeout is
     1s; at 5fps the reply may simply not have reached a frame yet, and calling
     it lost reports message loss that never happened. ]]
--[[ A window rendering about once a second has had one look, however long the
     timeout. Counting looks rather than seconds is the point: at five frames a
     second there is ample chance inside one second and the timeout is fair. ]]
nw = freshWorld()
nw.NoteFrame(1.0)
nw.pendingPing = { sentAt = NOW, nonce = "1", timeout = 1,
                   frameAt = nw.frameCount }
NOW = NOW + 1.1
said = {}
nw.NoteFrame(1.0)                    -- one look since it went out
nw.CheckPendingPingTimeout()
check("a ping is not called lost after a single look",
    nw.pendingPing ~= nil, true)
check("and nothing is said about message loss", heard("no reply"), false)

-- Once we have genuinely looked and it still is not there, it is lost.
NOW = NOW + 5
nw.NoteFrame(1.0)
nw.NoteFrame(1.0)
nw.CheckPendingPingTimeout()
check("but a reply that never comes is still called lost", nw.pendingPing, nil)
check("and the streak counted", nw.pingMissStreak, 1)

-- A foreground client has looked plenty of times and times out on schedule.
nw = freshWorld()
framesAt(nw, 60, 200)
nw.pendingPing = { sentAt = NOW, nonce = "1", timeout = 1, frameAt = 0 }
NOW = NOW + 1.1
nw.CheckPendingPingTimeout()
check("a foreground client still times out on schedule", nw.pendingPing, nil)

----------------------------------------------------------------------
-- the other box going quiet
----------------------------------------------------------------------
--[[ Alt-tab away and this client stops running the frames the other box's
     broadcasts would arrive in. Marking it "--" blames the box that was still
     talking. ]]
nw = freshWorld()
framesAt(nw, 60)
local stale = { latency = 50, time = NOW - (nw.ROSTER_BROADCAST_INTERVAL * 4) }
check("a member genuinely quiet for four intervals is counted missing",
    nw.RosterMissedCount(stale) >= nw.ROSTER_MISS_LIMIT, true)

framesAt(nw, 5)
check("but not while this client was the one not listening",
    nw.RosterMissedCount(stale), 0)

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
