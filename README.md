# Wiredbro's DDOS Lag Detector (v1.0.5)

A connection-stability monitor for WoW 1.12 (vanilla) clients — tracks latency spikes and stalls, does a real round-trip ping, and optionally shares latency with your party/raid so you can tell whether a rough patch is just you or the whole server.

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
- Opt-in: run `/wdld pingtest` once to confirm it works before turning on the automatic background version.
- Timeout is adaptive (2x your last real round trip, or 3x current home latency before any round trip has completed) rather than a fixed guess.
- Reply-matching uses a small incrementing counter, not a raw timestamp — round-tripping a float with many decimal digits through `tostring()`/`tonumber()` can lose enough precision once `GetTime()` is large that an exact-equality check fails even for a reply that arrived on time, which looked like frequent phantom timeouts before this was fixed.

### Group Latency sync
- Broadcasts your own latency to PARTY/RAID (same addon-message mechanism, different prefix) every 5s, and listens for the same from anyone else in the group running this addon.
- A "Group Latency" panel shows everyone's, worst first, so you can see at a glance whether an issue is isolated to you.
- On by default (opt-out, not opt-in) — unlike the ping, there's no "does this even work" uncertainty here, since it's the exact PARTY/RAID addon-message channel other addons on this server (e.g. Aegis_RallyPower's sync module) already use successfully.

## Slash commands

All equivalent: `/wdld`, `/nw`, `/netwatch`

```
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
```

Right-click the monitor to open settings: update interval, ping interval (both 0.5s–10s sliders), the ping on/off checkbox, the roster-share checkbox, and a button to open the Group Latency panel.

## Installation

The client identifies an addon by its folder name, which must contain a matching `.toc` file — this repo's name, folder, `.toc`, and `.lua` are all `WiredbroLagDetector`, so no renaming is needed at any step.

1. Clone this repo into `Interface\AddOns\` (or download and copy the folder in).
2. You should end up with `Interface\AddOns\WiredbroLagDetector\WiredbroLagDetector.toc`.
3. Restart the client (not just `/reloadui`, if this is a fresh install).

## Known limitations

- **Requires a guild for the round-trip ping specifically.** The Group Latency sync (PARTY/RAID) doesn't need one.
- **`GetNetStats()`'s exact field order isn't independently verified on every client build.** Run `/wdld probe` if the displayed numbers look wrong.
- **Packet loss is inferred, not measured.** There's no API for a true loss percentage — latency spikes and ping timeouts are the closest available proxy.

## Author

Built for [Salahaja](https://github.com/Salahaja).
