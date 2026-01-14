# Disk Keep Alive

A macOS menu bar app that prevents external HDDs from spinning down by generating periodic disk I/O activity.

## The Problem

External HDD docks (Orico, Sabrent, etc.) using JMicron chips (JMS567, JMS578) or ASMedia chips (ASM1153, ASM1351) have a **hardware-level idle timer** that spins down drives after ~10 minutes of inactivity - regardless of macOS power settings.

When you access the drive again, you have to wait 5-30 seconds for it to spin back up. Extremely annoying when working with large projects stored on external drives.

### Why macOS settings don't work

The spin-down is controlled by the dock's firmware, not the OS. Tools like `pmset` or "Prevent disks from sleeping" in Energy Saver have no effect on these hardware timers.

### The firmware mod approach

Some users have successfully [modified JMicron firmware](https://www.station-drivers.com/index.php?option=com_kunena&view=topic&catid=15&id=3636&Itemid=888&lang=en) to disable the idle timer. However, this requires:
- Finding the correct firmware for your specific chip
- Risk of bricking the dock
- Technical knowledge to flash firmware

## The Solution

This tool takes a simpler approach: **generate actual disk I/O at regular intervals** to reset the idle timer before it triggers spin-down.

### How it works

1. Writes 64KB of random data to a temp file
2. Forces sync to physical disk via `F_FULLFSYNC`
3. Reads the data back to verify
4. Reads from random existing files on the disk
5. Cleans up temp file

This creates real disk activity that the dock's controller recognizes, keeping the drive spinning.

## Features

- Native macOS menu bar app (no Electron bloat)
- Per-volume toggle control
- Configurable ping interval (5-120 seconds)
- Visual status indicators (green = active, orange = failed)
- Storage usage bar for each volume
- One-click eject
- Runs in background with Cmd+Q (quit via menu bar)
- IOKit power assertion to prevent Mac sleep while active

## Installation

### Homebrew (recommended)

```bash
brew install --cask meichengg/tap/disk-keep-alive
```

### From DMG

Download the latest `.dmg` from [Releases](../../releases), open it, and drag to Applications.

### Build from source

Requires Xcode Command Line Tools:

```bash
xcode-select --install
```

Build:

```bash
./build.sh              # Development build
./build-release.sh      # Release DMG
```

## Usage

1. Launch the app - it appears in the menu bar
2. Click the menu bar icon → Show Window
3. Toggle on the volumes you want to keep alive
4. Adjust interval if needed (default 30s, recommended 5-30s for aggressive docks)
5. Cmd+Q to hide window (app keeps running)
6. Menu bar → Quit to fully exit

## Recommended Settings

| Dock Type | Interval |
|-----------|----------|
| Orico (JMicron) | 5-10s |
| Generic USB 3.0 | 30s |
| Thunderbolt | 60s |

## Compatibility

- macOS 12.0+ (Monterey and later)
- Works with any external disk (HDD, SSD, USB drives)
- Tested with Orico docks using JMicron JMS578 chipset

## License

MIT
