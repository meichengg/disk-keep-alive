# Changelog

## 1.2.0

### What's New
- About window: View current version and changelog
- Auto update checker: Checks on startup and every 6 hours, notifies when new version available
- GitHub link: Quick access to repository from About window

### Improvements
- Build script now reads version from source code automatically
- Use CHANGELOG.md instead of GitHub API to avoid rate limiting

## 1.1.0

### What's New
- Auto-restore on startup: Remembers which volumes were active and automatically restarts them when the app launches
- Launch at Login: New menu bar option to start app automatically on system boot
- Live volume detection: Instantly detects and starts saved volumes as soon as they mount (no polling delay)
- Persistent settings: Interval and active volumes are saved between sessions

### Fixes
- Slider now only updates interval when mouse is released (no more timer restarts while dragging)

## 1.0.0

- Initial release
- Menu bar app to prevent external HDDs from spinning down
- Per-volume toggle control
- Configurable ping interval (5-120 seconds)
- Visual status indicators
- Storage usage bar
- One-click eject
