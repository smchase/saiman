# Saiman

macOS desktop AI chat app with a Spotlight-style floating window.

## Rules

1. **Always restart the app after finishing changes.** Run the built app so changes can be tested immediately.

2. **Only fix issues when the root cause is definitively identified.** When investigating bugs, do not attempt speculative fixes. If uncertain about the cause or solution, report findings and ask for guidance rather than implementing something that might not work. This avoids accumulating tech debt from guesswork.

## Build & Run

```bash
xcodebuild -scheme Saiman -configuration Debug build
```

## Environment

Required in `.env` at project root:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `EXA_API_KEY`

## Logging

Logs are written to `~/.saiman/logs/saiman-YYYY-MM-DD.log`. To view recent logs:

```bash
tail -100 ~/.saiman/logs/saiman-$(date +%Y-%m-%d).log
```

Logs include API requests/responses, tool calls, and errors. Use `Logger.shared.debug/info/error()` to add logs.

## Releasing a New Version

After making code changes, run the release script:

```bash
./release.sh
```

This quits the running app, builds a release version, installs to /Applications, and relaunches. Uses incremental builds for speed.

**Build issues?** If you encounter strange behavior after renaming/deleting files, stale build artifacts may be the cause. Run a clean build:
```bash
xcodebuild -scheme Saiman -configuration Release clean build
```

**Login Item**: Saiman is set to auto-start on login. If this gets removed, re-add it with:
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Saiman.app", hidden:false}'
```

## Behavior Notes

- **Scroll behavior**: Chat always opens scrolled to bottom. Auto-scrolls as agent types only if user is already at bottom. If user scrolls up, don't force scroll. When reopening a conversation (within 15-min window), always scroll to bottom.
