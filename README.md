# Meeting Chat Scroller

A tiny macOS menu bar app that keeps a chat window scrolling for you.

Every 3 seconds it presses **Page Down** (fn + ↓), sending the key to whichever window is in front. It pauses the moment you move the mouse, click, scroll or type, and resumes after 3 seconds of no mouse or keyboard use.

## Install

Download the `.pkg` (or build it yourself, below) and double-click it. Because the app isn't signed with an Apple Developer ID, macOS will block it the first time:

1. Click **Done** on the warning.
2. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Finish the installer. The app installs to `/Applications` and opens automatically.

Then allow it under **System Settings → Privacy & Security → Accessibility**. If the menu bar icon still shows a warning with the switch on, choose **Reset permission & relaunch** from the menu bar icon.

Requires macOS 13 or newer.

## Using it

- **Open the panel:** click the ↑↓ menu bar icon.
- **Pause / resume:** **Enabled** in that panel, or the Dock icon’s right-click menu.
- **Quit:** panel → **Quit**, Dock icon right-click → **Quit**, or ⌘Q.
- **Help:** panel → **How to use**.

| Menu bar icon | Meaning |
|---|---|
| ↑↓ | Running |
| ❚❚ | Paused because you're using the mouse or keyboard |
| ↑↓ faded | Turned off |
| ⚠ | Needs Accessibility permission |

## Build

Needs the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh      # builds a universal app and installs it to ~/Applications
./package.sh    # builds dist/MeetingChatScroller-1.1.pkg
```

Timing is a pair of constants at the top of `main.swift`. The panel is set in Geist, bundled under `fonts/` and licensed under the SIL Open Font License (`fonts/OFL.txt`).

Each rebuild is ad-hoc signed, so macOS treats it as a new app and asks for Accessibility permission again.
