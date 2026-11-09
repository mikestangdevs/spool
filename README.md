<p align="center"><img src="assets/icon.png" width="128" alt="Spool icon"></p>

# Spool

A scrolling window manager for macOS. Windows sit side by side on one horizontal strip per
display. Each keeps its width, the strip runs past the edge of the screen, and you scroll
along it instead of shrinking everything to fit.

Swift, no dependencies. It needs the Accessibility permission and nothing else: SIP stays on.

The idea comes from [niri](https://github.com/YaLTeR/niri) and
[PaperWM](https://github.com/paperwm/PaperWM), and the feature set follows
[Ribbon](https://meetribbon.app). Spool shares no code with any of them.

## Install

Requires macOS 14 or later and the Swift toolchain (Xcode, or `xcode-select --install`).

```sh
git clone https://github.com/mikestangdevs/spool && cd spool
make run
```

Grant Accessibility when macOS asks (System Settings → Privacy & Security → Accessibility)
and Spool starts arranging windows. It lives in the menu bar. Quitting it, or turning it
off from the menu, puts every window back where it was.

`make install` copies it to `/Applications`. `make test` runs the unit tests.

### Signing

macOS ties the Accessibility permission to an app's signature, so an unsigned build would
lose it on every rebuild. The first build therefore creates a self-signed certificate,
"Spool Local Signing", in its own keychain and signs every build with it. It needs no Apple
developer account, leaves your login keychain alone, and only works for your own builds on
your own Mac.

- Use your own identity: `SIGN_ID="Developer ID Application: Name (TEAMID)" make run`
- Sign ad-hoc instead: `SIGN_ID=- make run`
- Remove the certificate: `security delete-keychain ~/Library/Keychains/spool-signing.keychain-db`

## How it behaves

- A new window opens in its own column beside the focused one. Other columns keep their widths.
- Closing a window closes the gap.
- Focusing a window that is out of view scrolls the strip just far enough to show it.
- Drag a window's edge to set its column's width. Drag a window to reorder the strip, or
  drop it on another display to move it there.
- Each display, and each Space on it, has its own strip.
- Sheets, dialogs, full-screen windows and windows that cannot be resized are left alone.

## Shortcuts

Every chord can be re-recorded in Settings → Shortcuts, which also offers H J K L, Option
and Command-Option styles.

| Action | Chord |
| --- | --- |
| Focus left / right / up / down | ⌃⌥ ← → ↑ ↓ |
| Swap column left / right, move up / down in a stack | ⌃⌥⇧ ← → ↑ ↓ |
| Cycle width: third, half, two thirds, full | ⌃⌥R |
| Full width | ⌃⌥F |
| Match other columns to the focused width | ⌃⌥B |
| Stack into the column on the left / unstack | ⌃⌥S / ⌃⌥⇧S |
| Turn a stack into tabs and back | ⌃⌥T |
| Even out a stack | ⌃⌥0 |
| Toggle floating | ⌃⌥Space |
| Send to the next display | ⌃⌥N |
| Focus column 1–9, first, last | ⌃⌥1 … ⌃⌥9, ⌃⌥[, ⌃⌥] |
| Centre the column | ⌃⌥C |
| Layouts: 2, 3, 4, 5, 6 windows | ⌘⌃2 … ⌘⌃6 |
| Layouts: 2 + 1, 1 + 2 | ⌘⌃← ⌘⌃→ |
| Chain: every window back in its own column | ⌘⌃\ |
| Overview | ⌃⌥O |
| Mark this window / jump to a mark, then a letter | ⌃⌥M / ⌃⌥' |
| Peek left / right while held | ⌃⌥, / ⌃⌥. |

## Gestures

- **Three-finger swipe** slides the strip under the pointer and focuses the column it lands
  on. macOS uses the same swipe for Spaces: turn off “Swipe between full-screen
  applications” in System Settings → Trackpad → More Gestures, or move it to four fingers.
- **⌥ + scroll** does the same and needs no setup.

## Features

- **Overview**: the whole strip shrunk to fit the screen. Click, use the arrows and Return,
  or press a column's number. Window pictures are optional and need Screen Recording.
- **Minimap**: a small map of the strip appears while it moves.
- **Marks**: pin a letter to a window and jump back to it from anywhere.
- **Peek**: hold a key to slide a neighbour into view; let go and it slides back.
- **Named strips**: Menu → Strips saves which apps sit in which columns, and rebuilds that
  arrangement later, opening any apps that are closed.
- **App rules**: Settings → Apps makes an app float, open at a set width, or stack under
  the focused window.
- **Focus border** and a brief **width readout** when a width changes.
- **Session restore**: columns, stacks and widths come back when Spool restarts.

## Command line

Every action is a `spool://` URL, and `spoolctl` wraps them:

```sh
ln -s /Applications/Spool.app/Contents/MacOS/spoolctl /usr/local/bin/spoolctl

spoolctl focus east
spoolctl width 1/3
spoolctl layout 2+1
spoolctl save coding
spoolctl load coding
spoolctl help

open -g "spool://focus?direction=east"
```

## Code

- `Sources/SpoolCore`: the strip model and layout maths. No AppKit; covered by `swift test`.
- `Sources/Spool`: the app. Window tracking is in `WindowManager.swift`.
- `Sources/spoolctl`: the command line wrapper.
- `scripts/make-icon.swift` draws the app icon.

Spool uses three private, read-only APIs, so it cannot go on the Mac App Store:
`_AXUIElementGetWindow` (window IDs), `CGSManagedDisplayGetCurrentSpace` (one strip per
Space) and `MultitouchSupport` (the finger swipe).

## Known limits

- macOS does not allow a window fully off screen, so a window scrolled out of view waits
  at the screen edge with one point showing. Where two displays share that edge it is
  hidden at another edge instead, and appears without sliding.
- The 5-window layout is two stacked pairs and one tall window.
- Windows on another Space are picked up when that Space is shown.

## Licence

MIT. See `LICENSE`.
