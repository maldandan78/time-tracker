# Time Tracker

A small native macOS time tracker built with SwiftUI — no Xcode required, built entirely from the terminal with Swift Package Manager.

## What it does

**Projects only.** A time entry is just *project + start + end* — there are no descriptions or notes
to type. You start a timer **for a project**, and that's the whole decision.

- **Projects** (name only) live in the sidebar. The list is reorderable, and every project in it is a
  quick-launch pin: each row carries a ▶ / ⏹ button that starts or stops that project's timer.
- **Global shortcuts, assigned by position.** The **first nine** projects in the sidebar get
  `⌃⌥⌘1` … `⌃⌥⌘9` — press one from any app to start that project, press it again to stop.
  The binding follows the *position*, not the project, so **drag the list to choose which nine get a
  shortcut**. Projects past the ninth work normally, just without a hotkey.
- **A single live timer.** Starting a project stops whatever was running first. While a timer runs, a
  bar above the history shows it and lets you edit it or **Stop** it; idle, there's no bar at
  all and the history fills the pane — every way to *start* a timer already lives elsewhere.
- **Running-timer shortcuts** work globally too, so you can fix a late start without switching apps:
  - `⇧⌃⌥⌘→` — add a minute (moves the start earlier)
  - `⇧⌃⌥⌘←` — reduce a minute (never past "now")
  - `⇧⌃⌥⌘⌦` — discard the running timer entirely, recording nothing
    (that's forward-delete — `fn`+`delete` on a laptop — deliberately *not* backspace, which other
    system-wide utilities like to grab before it ever reaches us)
- **Daily goals** — per project, two kinds: work **at least** N a day (reach it) or **at most** N a
  day (stay under it), one goal of each kind per project. The **Goals** view in the sidebar shows
  live progress bars — green while the goal holds (an "at least" goal met, or an "at most" limit
  still respected), red once an "at most" limit is exceeded — and every goal row carries the same ▶
  start button as the rest of the app. The menu-bar dropdown lists each goal's status
  (`✓` satisfied, `!` over, `·` in progress). Both surfaces count the running timer as it accrues —
  the day's total keeps climbing second by second while you work. An entry counts toward the day it
  *started* (the app-wide convention), so a session running past midnight belongs wholly to
  yesterday.
- **History grouped by day**, and within each day **clustered by project**: repeated sessions on the
  same project collapse into one expandable row with a count and a combined duration. Each day has a
  subtotal, and the header above the list shows **Today** and **This week**.
- **Edit and delete** freely: change an entry's project, start, or end; re-project a whole cluster at
  once; delete a single entry, a whole group, or a project (which cascades to its entries, with a
  confirmation that tells you how many).
- **Search** the history by project name, with a small boolean syntax — `&` (also implied by a
  space), `|`, `!`, and parentheses, e.g. `client | !internal`.
- **Menu-bar extra** showing the live elapsed time (optionally with the project name), a Stop button,
  and every project as a one-click start/stop row with its shortcut label.
- Data is stored as readable JSON at `~/Library/Application Support/TimeTracker/data.json`, written
  atomically on every change. **Export** from the sidebar drops a timestamped copy in `~/Downloads`.
  (Goals live in the same file under a `goals` key; a pre-goals build opens such a file fine but
  strips the key on its first save — the same accepted tradeoff as other legacy keys.)
- A running timer survives quitting/relaunching — it resumes counting from its original start time.

## Requirements

- macOS 14+ (built and tested on macOS 26, Apple Silicon).
- Xcode Command Line Tools only (`xcode-select --install`). No full Xcode needed.

## Build & run

```bash
# Build "Time Tracker.app" into the project folder
./Scripts/build.sh
open "Time Tracker.app"

# …or build and install into /Applications
./Scripts/install.sh
```

For fast iteration during development you can also run the raw binary:

```bash
swift run
```

## Project layout

```
Sources/TimeTracker/
├── TimeTrackerApp.swift          # @main App + AppDelegate, hotkey wiring
├── HotKeyManager.swift           # Carbon global hotkeys: ⌃⌥⌘1…9 + the ⇧⌃⌥⌘ commands
├── SearchQuery.swift             # tiny boolean search language for the history filter
├── Models/Models.swift           # Project, TimeEntry, Goal, AppData, duration formatting
├── Store/DataStore.swift         # @Observable state + JSON persistence + export
└── Views/
    ├── ContentView.swift         # NavigationSplitView shell
    ├── SidebarView.swift         # project list (= the shortcut list), editor sheet, export
    ├── TrackerBar.swift          # running-timer bar (renders nothing while idle)
    ├── EntryListView.swift       # day groups, project clusters, subtotals, summary header
    ├── EntryEditorSheet.swift    # single-entry and group editors
    ├── GoalsView.swift           # daily goals: progress rows + goal editor sheet
    └── MenuBar.swift             # menu-bar extra
Scripts/
├── build.sh                      # compile + assemble .app bundle (ad-hoc signed)
└── install.sh                    # build + copy to /Applications
```
