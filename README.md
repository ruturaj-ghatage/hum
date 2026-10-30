<p align="center">
  <img src="docs/icon.png" width="128" alt="Hum icon">
</p>

<h1 align="center">Hum</h1>

<p align="center">Your MacBook's notch, now playing.</p>

Hum is a tiny menu bar app that turns the notch into a live music player for **Spotify** and **Apple Music**.

<p align="center">
  <img src="docs/compact.png" width="600" alt="Hum compact mode">
</p>

<p align="center">
  <img src="docs/expanded.png" width="600" alt="Hum expanded player">
</p>

## Features

### Music
- **Compact mode:** while music plays, the notch grows just enough to show the album art on one side and live bars on the other.
- **Moves to the beat:** the bars follow the real audio (bass, mids, highs), and the notch bulges with every kick drum.
- **Hover to expand:** shows the title, artist and album, a progress bar you can drag to seek, and previous / play-pause / next.
- **Physics:** pull the expanded player down and it springs back, fling it sideways to skip tracks, or flick it up to tuck it away.
- **Peek:** when a new song starts, the new cover drips in and the player drops down for 3 seconds.
- **Adaptive color and ambient glow:** everything picks up the album's most vivid color, including a faint light around your screen edges that breathes with the bass.

### Focus Guardian
- Start a 25, 50 or 90 minute focus session from the menu bar. A thin bar along the bottom of the notch fills up as time passes.
- If you open a distracting app (Discord, Telegram…) or site (YouTube, X, Reddit…), the notch shakes and tells you to get back to work.

### Claude Code and build status
- While Claude Code is working, the notch glows **orange**. It turns **blue** when Claude needs your permission and ripples **green** when Claude is done.
- Wrap any command with `hum-run` to get the same treatment: `hum-run npm test`.

### Notifications from the notch
Any script can slide a notification out of the notch:

```bash
open -g "hum://notify?title=Deploy%20done&body=api%20is%20live&symbol=checkmark.circle.fill&color=green"
```

### Settings
Hover the notch and click ⚙️ to switch each feature on or off. The same switches are in the menu bar, along with **Launch at Login**.

## Install

### Build from source (recommended)

You need macOS 14 or later and Apple's command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/ruturaj-ghatage/hum.git
cd hum
./build.sh install
open ~/Applications/Hum.app
```

### Download a release

Download `Hum.zip` from [Releases](https://github.com/ruturaj-ghatage/hum/releases), unzip it and move `Hum.app` to Applications.

Hum isn't notarized yet, so macOS blocks it the first time. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Hum.app
```

### Claude Code status (optional)

```bash
./scripts/install-claude-hooks.sh
```

This adds Hum's hooks to `~/.claude/settings.json`. It keeps any hooks you already have and makes a backup first.

### hum-run (optional)

```bash
ln -s ~/Applications/Hum.app/Contents/Resources/hum-run /usr/local/bin/hum-run
```

### First launch

macOS asks a few things the first time each feature is used:
- **Control Spotify / Music:** reads artwork and position, and sends play/pause/skip.
- **System audio recording:** lets the notch move to the beat. Nothing is recorded or saved.
- **Control your browser** (only during Focus): checks which site you're on.

## How it works

- Spotify and Music post a distributed notification (`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`) on every play, pause or track change, so Hum doesn't poll.
- AppleScript fetches the artwork and position and sends playback controls. Hum only talks to a player that is already running, so it never launches one.
- The notch is a borderless `NSPanel` above the menu bar, drawn with SwiftUI. Its size comes from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. On a display without a notch, Hum draws a matching one.

| File | What it does |
|---|---|
| `Sources/Hum/NowPlaying.swift` | Player state, notifications, AppleScript, artwork tint |
| `Sources/Hum/NotchController.swift` | Window placement, hover tracking, peek timer |
| `Sources/Hum/NotchView.swift` | Notch shape, compact/expanded/settings views, effects |
| `Sources/Hum/AudioLevels.swift` | System audio tap and frequency bands |
| `Sources/Hum/FocusGuardian.swift` | Focus timer and distraction detection |
| `Sources/Hum/ActivityTracker.swift` | Claude Code sessions and `hum-run` tasks |
| `scripts/claude-hook.sh`, `scripts/hum-run` | Send events to Hum over `hum://` |
| `scripts/make-icon.swift` | Draws the app icon |
| `build.sh` | Builds `build/Hum.app` (`./build.sh install` copies it to `~/Applications`) |
| `release.sh` | Tags a version (e.g. `./release.sh 0.2.0`) for a minor or major release |

Every push to `main` that changes the app is built by GitHub Actions and published as a new patch release automatically.

## Roadmap

- [ ] Synced lyrics
- [ ] Signed and notarized releases, plus a Homebrew cask

## License

[MIT](LICENSE)
