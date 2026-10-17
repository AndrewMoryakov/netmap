# netmap — a network map for Windows

**English** · [Русский](README.ru.md)

**▶ [Try the live demo in your browser](https://andrewmoryakov.github.io/netmap/)** — no install, made-up data, a ready-made incident to rewind.

A local, read-only web page that shows **which program talks through which network interface (VPN, TUN and proxy tunnels included) and where its traffic goes** — and helps you work out why several VPNs on one machine get in each other's way. Its party trick is a **time machine**: drag a slider and the whole map rewinds to the moment a flaky VPN dropped, so you can *see* an incident that never reproduces while you watch.

![netmap screenshot](docs/screenshot.png)

```
processes  →  interfaces (metric, DNS, throughput)  →  where the traffic goes
```

*The screenshots use made-up demo data.*

## Time machine

Every snapshot the page receives is kept. The timeline at the bottom scrubs the entire UI — map, side panel, every tab — back to any moment. Warning and error events are marked on the timeline, `⚠◀` / `▶⚠` jump between incidents, arrow keys step, Space plays, End returns to live.

![rewinding an incident](docs/rewind.gif)

![time machine screenshot](docs/time-machine.png)

In the demo above Cisco AnyConnect starts reconnecting, the adapter with metric 1 stays first in the DNS list and goes silent, names stop resolving, and NetBird loses its management server because its own domain falls under an NRPT rule — all visible, frame by frame, on one map.

## Share without leaking

The **Share** button creates, entirely in the page (nothing is uploaded):

- a **PNG of the map** exactly as you see it, or
- the **whole recording as one HTML file** that opens in any browser with no install and no server, with the time slider intact — a replay you can attach to a bug report or publish in an article.

By default everything is **anonymised**: IP addresses, domain names, computer / peer / adapter names and unusual process names are replaced by consistent aliases (the same real value always gets the same alias; hosts of one /24 stay in one /24; private ranges stay private). The dialog shows exactly what was replaced, visible only to you. Review the result before publishing: free-form texts may contain something the program did not recognise.

## Features

- **Process → interface → destination map**: adapters, routes, DNS, local proxies, per-process connections (line width = number of connections).
- **Aware of** Happ, Clash Verge, Cisco AnyConnect, Tailscale and NetBird (each has its own data collector). WARP, GlobalProtect, FortiClient, ZeroTier, OpenVPN, WireGuard, WSL and Hyper-V are shown as generic kinds. The list, names and colours live in `netmap.config.json`.
- **Node health**: a coloured dot in every node header (ok / warning / problem / off) and a list of findings at the top, such as "two TUN VPNs at once", "DNS is hijacked", "the NetBird server name falls under an NRPT rule".
- **Live traffic**: ↓/↑ throughput per adapter with a sparkline, and running dashes along the "interface → destination" lines (faster dashes = more traffic).
- **Change highlighting**: a node or line glows for 8 seconds when something changes (an adapter goes up or down, a process switches interface, AnyConnect changes state…). The tooltip says what changed.
- **Monitor and journal**: background DNS / ping probes and an event log (`events.jsonl`).
- **On-demand checks**: query every DNS server, find the external IP (directly and through the local proxies), trace the path to a domain or IP.
- **"Plan…"**: builds a *plan* for sending an address, a subnet or a program through a different interface (drag a node onto an interface). It produces apply and rollback scripts but **never applies anything itself**.
- **"Links"**: a registry of your own routing intentions (`netmap.links.json`) with statuses (planned / active / marked manually / drifted) and a classification of routes (default at start / appeared after start / mine).
- **All processes**: by default the map shows the 14 busiest processes and folds the rest into one node; the "all processes" checkbox (or the button in the folded node's side panel) shows every one of them.
- **English and Russian**: the language follows the browser; the `RU` / `EN` button switches it, `?lang=en` forces it. Server messages follow the page (`-Lang ru|en` sets the default for the console).

## Safety model

- **Read-only.** netmap changes nothing on the system: no routes, no `hosts`, no VPN settings. Every change is a script from "Plan…" that you copy and run yourself.
- It listens on **`127.0.0.1` only** (port 47900, or the next free one up to 47909) and sends nothing out. The only exceptions are the on-demand checks (a request to `cloudflare.com` for the external IP, and DNS probes), which run only when you press the button.
- The local API checks the `Host` header, requires an `X-NetMap` header (a plain cross-site request is rejected), and accepts writes only as `POST` with `Content-Type: application/json`.
- Addresses and subnets you type are validated; subnets wider than `/8` are rejected.
- The recorded history lives only in the open page (a reload starts a new one) until you export it.

## Requirements

- Windows 10 / 11.
- **PowerShell 7** (`pwsh`). If started from Windows PowerShell 5.1, the script relaunches itself in `pwsh` when it is installed.
- A modern web browser.
- No administrator rights are needed for the map. They are needed only to run the route scripts that "Plan…" produces.

## Run

```
netmap.cmd
```

or

```
pwsh -NoProfile -ExecutionPolicy Bypass -File netmap.ps1 [-Port 47900] [-NoBrowser] [-Lang en]
```

Then open `http://127.0.0.1:47900/` (it opens automatically unless `-NoBrowser` is given). Close the console window or press Ctrl+C to stop.

The first data collection takes up to 20 seconds; after that the page refreshes every 5 seconds (untick "auto" to stop).

**No Windows at hand?** Open `index.html` straight from disk (or the [live demo](https://andrewmoryakov.github.io/netmap/)): without a server the page switches to demo mode with a synthetic network. `?demo=1` forces it, `?demo=0` disables it.

## Configuration

Everything netmap recognises is described in `netmap.config.json`. Edit it without touching the code and restart the map:

- `adapterKinds` — adapter kinds: regular expressions for the adapter name / description, colour, label, TUN/VPN flags. Order matters: the first match wins.
- `processes` — regular expressions for proxy, Happ and Clash processes.
- `paths` — where to find Happ's `routing.json`, the Clash Verge settings, AnyConnect's `vpncli`, `tailscale.exe`.
- `localProxyPorts`, `hotspotGatewayRx`, `skipDnsServersRx`, `probes`.

The config is validated at startup; a broken JSON file, an invalid regular expression, a duplicate or a reserved name is reported with a clear message.

## Files

| File | Purpose |
|---|---|
| `netmap.ps1` | server (HTTP on loopback), data collection, plans and the links registry |
| `netmap-monitor.ps1` | background monitor (DNS, ping, events) |
| `index.html` | the whole UI: map, tabs, "Plan…", "Links", time machine, share, demo |
| `netmap.config.json` | settings |
| `netmap.cmd` | double-click launcher |

Created at runtime next to the scripts and ignored by git: `netmap.log`, `events.jsonl`, `netmap.links.json`.

## Limitations

- Windows + PowerShell 7 only for live data (the demo and replays run anywhere); little tested on other machines and setups.
- For programs outside the config (no dedicated collector) the map shows the adapter, its routes and a destination node, but no data from the program itself.
- Throughput is measured per adapter, not per process (Windows does not expose that without ETW).
- A connection is assigned to an interface by the socket's local address; UDP/QUIC chains are less visible than TCP.
- Applying routes from the UI with an automatic rollback is not implemented yet — you copy the scripts.
- The time machine keeps up to about 80 minutes of 5-second snapshots in memory.

## License

MIT — see [LICENSE](LICENSE).
