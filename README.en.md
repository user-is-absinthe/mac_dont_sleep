# Don't sleep

[🇷🇺 Русская версия](README.md)

![Coffee cup app icon](Resources/AppIcon.png)

A small native macOS app that keeps your Mac awake for a selected amount of time. It provides a friendly interface for the built-in [`caffeinate`](https://ss64.com/mac/caffeinate.html) utility—no background services, Homebrew packages, or third-party notification tools required.

## Features

- Set any positive whole-number duration, with 15, 30, 60, and 120 minute shortcuts.
- Live countdown and a precise local end time.
- Keep the Mac awake while letting the display sleep (`caffeinate -i`), or keep both the Mac and display awake (`caffeinate -di`).
- Cancel the timer at any time.
- Safely stop the underlying `caffeinate` process when quitting with <kbd>⌘Q</kbd>.
- Native macOS notification when the timer ends.
- Universal binary for Apple Silicon and Intel Macs.

## Requirements

- macOS 13 Ventura or newer
- Apple Command Line Tools (`xcode-select --install`)

## Download

Prebuilt binaries are available on the [Releases](https://github.com/user-is-absinthe/mac_dont_sleep/releases) page. Open the downloaded DMG image and drag the app onto the **Applications** link next to it—it will be installed into your Applications folder. No need to build the project yourself.

The app is ad-hoc signed (no Apple Developer ID), so macOS may show a Gatekeeper warning the first time you open a downloaded copy. Remove the quarantine flag with:

```zsh
xattr -cr "/Applications/Don't sleep.app"
```

## Build and run

1. Clone or download this repository.
2. In Finder, double-click [`build_app.command`](build_app.command), or run:

   ```zsh
   ./build_app.command
   ```

3. Open the generated application:

   ```text
   build/Don't sleep.app
   ```

The first time a timer starts, macOS asks for permission to send notifications. Declining that permission does not affect the wake lock or countdown; it only disables the completion notification.

## How it works

The app launches Apple's built-in `caffeinate` command with a timeout. The **Keep display on** switch controls the command flags:

| Setting | Command flags | Effect |
| --- | --- | --- |
| Off | `-i` | Prevents idle system sleep; the display may sleep normally. |
| On | `-di` | Prevents both idle system sleep and display sleep. |

The app owns the child process. Cancelling the timer or quitting the app terminates it immediately, returning macOS to its normal power settings.

## Project layout

```text
Sources/                  SwiftUI application source
Resources/                App icon, Info.plist, and source artwork
legacy/                   Original Terminal-based script
scripts/                  Utilities: ICNS icon creation and DMG packaging
build_app.command         Builds and signs the local universal .app bundle
```

Build products and Swift compiler caches are ignored by Git.

## Icon attribution

The coffee-cup outline in `Resources/CoffeeCup.svg` is adapted from the Coffee icon in [Feather Icons](https://github.com/feathericons/feather), licensed under MIT. The full attribution and license text are in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
