# Time Tracker

A small native macOS time tracker built with SwiftUI — no Xcode required, built entirely from the terminal with Swift Package Manager.

## What it does

- **Projects** (name only) you create in the sidebar.
- A single **live timer** — pick a project, type a description, hit **Start**. Starting a new timer stops the running one.
- Entries are **description + project**, grouped **by day** with per-day subtotals and a live **Today** total.
- Delete a single entry, or delete a project (which removes its entries). No editing of past entries.
- Data is stored as readable JSON at `~/Library/Application Support/TimeTracker/data.json`.
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
├── TimeTrackerApp.swift     # @main App + AppDelegate
├── Models/Models.swift      # Project, TimeEntry, AppData, formatting
├── Store/DataStore.swift    # @Observable state + JSON persistence
└── Views/                   # ContentView, SidebarView, TrackerBar, EntryListView
Scripts/
├── build.sh                 # compile + assemble .app bundle (ad-hoc signed)
└── install.sh               # build + copy to /Applications
```
