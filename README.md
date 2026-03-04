# File Sorter Mac (Swift)

Native macOS rewrite scaffold using SwiftUI/AppKit conventions.

## What this version currently includes

- Single-window split view layout (preview + controls)
- Choose folder with `NSOpenPanel`
- Empty preview state is clickable to open folder picker
- Recursive toggle
- Recent source folders menu (last 5), select to reopen
- Recent destination folders menu (last 5), select to reuse destination override
- People mode for face/similarity batches:
  - tag individual photos/videos with a person name
  - tag per-card during person review (alongside Yes/No quick review)
  - track/delete known people in sidebar
  - click a person in sidebar to search the current folder for likely matches for that person
  - get person-specific likely-match batches after tagging, weighted toward face matches
  - always includes unassigned review batches (clustered when possible) so unmatched files can still be reviewed and tagged
  - one-click batch tagging for non-review People batches
- Native `Recent Sources` and `Recent Destinations` command menus
- No automatic reopen of last folder on launch
- Destination override supported (sort into folder different from source)
- Session navigation: Move / Next / Previous
- Close current folder/session to clear preview
- Conflict-safe move behavior (`moved` / `duplicate` / `renamed`)
  - `Remove Duplicates` live toggle in main window (next to `Recursive`)
  - Settings controls the default duplicate behavior on app launch
  - when disabled: asks for confirmation before removing each duplicate
  - duplicate removals are counted in completion summary and shown with toast feedback
- Browser context opening from current file:
  - opens one Google search tab (not direct source URLs)
  - search query uses extracted filename vectors (prefers stable IDs, avoids overly specific tokens)
  - adds a base-domain hint (`site:example.com`) from source metadata when available
  - browser selection: `System Default` or installed browser list
  - private-mode flag options
  - source URLs are shown in-file within the app
- Finder integration:
  - reveal current file in Finder
- Seek controls:
  - configurable seek seconds
  - on-screen seek buttons
  - keyboard shortcuts
  - per-file remembered seek position across navigation
- Native preview:
  - images via `NSImage`
  - video/audio via `AVPlayer` + `AVPlayerView`
  - autoplay when advancing to the next media file
- Current file info strip:
  - native Finder file icon
  - size + modified timestamp
  - media metadata (duration + codec label when available)
  - source links (where-from metadata) when available
- macOS-native UI polish:
  - window toolbar for primary actions
  - searchable folder list
  - SF Symbols action labels and command-menu integration
  - default action button (`Move`) and row double-click-to-move
  - native destructive confirmation sheet for clearing recent folders
    - native destructive confirmation sheets for clearing recent source/destination lists
  - native warning sheets (`NSAlert`) for move/context/recent-folder failures
  - dedicated bottom status bar for non-error feedback
- Settings stored in macOS Application Support

## Config location

The app writes config outside the repo to:

- `~/Library/Application Support/File Sorter Swift/config.json`
- `~/Library/Application Support/File Sorter Swift/people-recognition.sqlite`

People recognition memory now uses SQLite. On first launch after this change, any legacy people data found in `config.json` is imported into `people-recognition.sqlite`, then removed from future JSON writes.

This is not part of git commits in this workspace.

## Build and run

From this folder:

```bash
swift run
```

Or open in Xcode:

1. Open `swift-app/Package.swift`
2. Select target `FileSorterMac`
3. Run (`⌘R`)

## Notes

- This is a native baseline intended to replace the Electron prototype incrementally.
- Current implementation already includes browser-context opening and metadata URL extraction.

## Keyboard shortcuts

- `⌘M` toggle recursive/top-level mode
- `⌘G` open browser context for current file
- `⌘O` open folder
- `Space` play/pause current media (only when not typing in text/search fields)
- `⇧⌘R` reveal current file in Finder
- `←` previous file
- `→` next file
- `Enter` move file
- `⌥←` seek backward
- `⌥→` seek forward

## Native Settings

The app includes a native macOS Settings window (standard app Settings scene):

- default recursive mode
- default remove duplicates automatically toggle
- seek step seconds
- browser app/private settings
  - browser chooser supports `System Default` + detected installed apps
- people recognition controls
- recent source/destination management
