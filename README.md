# Wiredbro's DDOS Lag Detector (v1.1.0)

A connection-stability monitor for WoW 1.12 (vanilla) clients — tracks latency spikes and stalls, does a real round-trip ping, and optionally shares that ping with your party/raid so you can tell whether a rough patch is just you or the whole server.

## Why this exists

Every group has that one person who calls out "I lagged" every time something goes wrong — a missed interrupt, a death, a wipe. Sometimes they're right and the server really is having a moment. Sometimes it's just them. Without a number, there's no way to tell which, and it turns into an argument nobody can actually settle.

This addon puts an actual number on it. Turn on Group Ping sync and everyone's round-trip time shows up on their party/raid frame (or the Group Ping panel), worst first. If they're genuinely spiking while everyone else reads normal, now you know it's really them — and if everyone's ping jumps together, now you know it's the server, and the "I lagged" callout was right after all.

## Why latency, not "world" latency

Vanilla's `GetNetStats()` API exposes `latencyHome` and `latencyWorld`, but `latencyWorld` turned out to always read `0` on this server. The entire monitor runs on `latencyHome` instead — this isn't just a display choice, since the spike/warn/severe detection is built around whichever value it tracks.

There's also no true packet-loss percentage exposed to addons at all — that's simply not part of vanilla's API. What this addon does instead is track latency spikes and stalls (which is what packet loss/timeouts actually look like from the client's side) and log them with timestamps so you can correlate rough patches with server attacks after the fact.

## Features

### Latency monitor
- Small always-on HUD (drag to move) showing current home latency, color-coded green/yellow/red against configurable thresholds.
- Rolling-average-based spike detection: flags a "warn"/"severe" state either from an absolute threshold or from a relative jump (3x your own recent average), so it adapts to your actual baseline instead of one hardcoded number.
- Persisted, timestamped log (`/wdld log`) of every spike and recovery, survives reloads/relogs.

### Round-trip ping
- Sends a tiny addon message to yourself over the **GUILD** channel (invisible — `WHISPER` is rejected outright by this client's `SendAddonMessage`, confirmed via testing, so GUILD is used instead; requires being in a guild) and times how long it takes to come back.
- This measures actual message-level round trip through the server, which can diverge from `GetNetStats()`'s latency number when the server itself is backed up rather than the network path.
- **This is a round trip, not a one-way ping.** The message has to travel to the server, get relayed back down to you, and get read by the client before the timer stops — so the number will normally read noticeably higher than a one-way network ping (think traceroute-style hop times), because it's actually measuring "there and back" plus whatever the server itself takes to relay it. That's expected, not a bug - it's also arguably the more honest number, since it's what actually happens every time you cast a spell or send a chat message, not just a raw network figure.
- Opt-in: run `/wdld pingtest` once to confirm it works before turning on the automatic background version.
- Timeout is adaptive (2x your last real round trip, or 3x current home latency before any round trip has completed) rather than a fixed guess.
- Reply-matching uses a small incrementing counter, not a raw timestamp — round-tripping a float with many decimal digits through `tostring()`/`tonumber()` can lose enough precision once `GetTime()` is large that an exact-equality check fails even for a reply that arrived on time, which looked like frequent phantom timeouts before this was fixed.

### Group Ping sync
- Broadcasts your own round-trip ping (not `GetNetStats()` home latency - that's just your own link to the server and stays normal during exactly the kind of trouble this addon exists to catch, so it told the group nothing useful) to PARTY/RAID (same addon-message mechanism, different prefix) every 5s, and listens for the same from anyone else in the group running this addon.
- A "Group Ping" panel shows everyone's, worst first, so you can see at a glance whether an issue is isolated to you.
- Sharing is on by default, but since it rides the round-trip ping, there's nothing to actually send until the ping itself is turned on (see above - opt-in, needs a guild).
- **In a party**, each member's ping is stamped directly onto their default party frame (`PartyMemberFrame1`-`4`) - no panel needed. If you're running [pfUI](https://github.com/shagu/pfUI) (which hides Blizzard's own party frames), it stamps onto pfUI's `pfGroup0`-`4` instead.
- **In a raid**, vanilla's own default UI has no per-member frames to stamp onto at all (that's a later-expansion feature) - but if you're running [ShaguTweaks-extras](https://github.com/shagu/ShaguTweaks-extras)' raid frames module or [pfUI](https://github.com/shagu/pfUI)'s, ping gets stamped onto those the same way. Without either addon, the Group Ping panel auto-opens once when you join a raid instead, and auto-closes when you leave it - unless you opened or closed it yourself in the meantime, in which case it leaves your choice alone for the rest of that raid.
- If a groupmate goes quiet, their last number doesn't just sit there looking current: after missing 3 broadcasts in a row (~15s) their value shows as a red `--` instead, on their frame and in the panel. Miss 5 in a row and you also get a chat warning that they've likely lagged out or disconnected.

## Slash commands

All equivalent: `/wdld`, `/nw`, `/netwatch`

```
/wdld                  toggle the on-screen monitor
/wdld hide             hide it explicitly (safe in a macro regardless of
                       current state, unlike the toggle)
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
/wdld set roster on    shares your ping with party/raid (default - still needs
                       the ping itself turned on to have anything to share)
/wdld set roster off   stops sharing (you can still see others')
```

Right-click the monitor to open settings: update interval, ping interval (both 0.5s–10s sliders), the ping on/off checkbox, the roster-share checkbox, an "Unlock ping label position" checkbox with a "Reset Label Position" button, a "Detect activity (beta)" checkbox (see below), and a button to open the Group Ping panel.

A minimap button (drag it around the ring to reposition) gives the same two actions without a slash command: left-click shows/hides the monitor, right-click opens settings.

### Repositioning the ping labels

The default spot for each ping label is a best guess, and it can land somewhere awkward depending on which unit-frame addon you run and how it's sized or skinned (see the ShaguTweaks/pfUI raid frame notes above - both needed real tweaking to look right). Rather than guess forever, check "Unlock ping label position" in settings: every label gets a visible border and becomes draggable, and hovering one shows a tooltip naming whose label it is (handy in a packed raid frame grid). **Drag just one of them** - the nudge you make is shared across every label (party, raid, whichever addon), so dragging a second one moves everything again rather than adding a second independent position. Uncheck the box to lock it back down, or hit "Reset Label Position" to return everything to its default spot.

### Beta: detecting activity from other addons

Vanilla predates `RegisterAddonMessagePrefix` (added in a later expansion to cut down on spam), so `CHAT_MSG_ADDON` fires for every addon's messages here, not just ones this addon recognizes. That means a groupmate's own boss mod, threat meter, or other chatty addon firing at all is visible as evidence their client is still alive - a free "still around" signal for someone who doesn't have WDLD themselves.

Turn it on with "Detect activity (beta)" in settings. It only ever fills in where there's no real ping number, showing `active` in green instead of a blank space. Two things worth knowing:
- It mostly needs **combat** to see anything - boss mods and threat meters are the chattiest sources, and they're quiet outside a fight.
- It's **not proof of good latency**, just that something of theirs got through recently. A laggy client can still eventually deliver a queued message late.

Treat it as "at least they weren't fully disconnected as of a moment ago," not a real measurement.

## Installation

The client identifies an addon by its folder name, which must contain a matching `.toc` file — this repo's name, folder, `.toc`, and `.lua` are all `WiredbroLagDetector`, so no renaming is needed at any step.

1. Clone this repo into `Interface\AddOns\` (or download and copy the folder in).
2. You should end up with `Interface\AddOns\WiredbroLagDetector\WiredbroLagDetector.toc`.
3. Restart the client (not just `/reloadui`, if this is a fresh install).

## Known limitations

- **Requires a guild for the round-trip ping.** Group Ping sync (PARTY/RAID) rides that same ping, so it also needs the ping turned on and a guild - only the always-on Home latency line on the HUD needs neither.
- **`GetNetStats()`'s exact field order isn't independently verified on every client build.** Run `/wdld probe` if the displayed numbers look wrong.
- **Packet loss is inferred, not measured.** There's no API for a true loss percentage — latency spikes and ping timeouts are the closest available proxy.

## Author

Built for [Salahaja](https://github.com/Salahaja).
