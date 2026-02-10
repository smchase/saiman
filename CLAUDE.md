# Saiman

macOS desktop AI chat app with a Spotlight-style floating window.

## Rules

1. **Always restart the app after finishing changes.** Run the built app so changes can be tested immediately.

2. **Only fix issues when the root cause is definitively identified.** When investigating bugs, do not attempt speculative fixes. If uncertain about the cause or solution, report findings and ask for guidance rather than implementing something that might not work. This avoids accumulating tech debt from guesswork.

## Build & Run

Always use the release script to build and test:
```bash
./release.sh
```

Do not run manual `xcodebuild` commands for testing. The release script handles everything (quit, build, install, relaunch) and uses fast incremental builds.

## Environment

Required in `~/.saiman/.env`:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `EXA_API_KEY`

## Database

Conversations and messages are stored in SQLite at:
```
~/Library/Application Support/Saiman/saiman.db
```

Useful queries for debugging:

```bash
# Last 5 conversations
sqlite3 ~/Library/Application\ Support/Saiman/saiman.db \
  "SELECT id, title, datetime(updated_at, 'unixepoch', 'localtime') FROM conversations ORDER BY updated_at DESC LIMIT 5;"

# Last agent message from most recent conversation (raw content)
sqlite3 ~/Library/Application\ Support/Saiman/saiman.db \
  "SELECT content FROM messages WHERE conversation_id = (SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1) AND role = 'assistant' ORDER BY created_at DESC LIMIT 1;"

# All messages from most recent conversation
sqlite3 -json ~/Library/Application\ Support/Saiman/saiman.db \
  "SELECT role, content, tool_calls FROM messages WHERE conversation_id = (SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1) ORDER BY created_at ASC;"
```

## Logging

Logs are written to `~/.saiman/logs/saiman-YYYY-MM-DD.log`. To view recent logs:

```bash
tail -100 ~/.saiman/logs/saiman-$(date +%Y-%m-%d).log
```

Logs include API requests/responses, tool calls, and errors. Use `Logger.shared.debug/info/error()` to add logs.

## MarkdownUI Fork (Submodule)

`Packages/swift-markdown-ui/` is a **git submodule** pointing to a fork of [gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui). It's maintained solely for this app.

### How it works

- The fork adds LaTeX math rendering (`$...$` and `$$...$$`) on top of the upstream MarkdownUI library.
- It uses **MathJaxSwift** (MathJax 3.2.2 via JavaScriptCore) to render LaTeX to SVG, then **SwiftDraw** to rasterize to images.
- A **MathPreprocessor** runs before cmark-gfm to protect math expressions from cmark's backslash escaping. It replaces math with base64-encoded placeholders, which the extraction step decodes after parsing.

### Making changes to the fork

Edit files directly in `Packages/swift-markdown-ui/`. Then **commit and push within the submodule** before building:

```bash
cd Packages/swift-markdown-ui
git add -A && git commit -m "description" && git push
cd ../..
```

After pushing, update the submodule pointer in the main repo:

```bash
git add Packages/swift-markdown-ui && git commit -m "Update submodule"
```

The release script uses incremental builds. If the fork's changes don't take effect, clear derived data:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Saiman-*
```

### Key files in the fork

- `Parser/MathPreprocessor.swift` — Pre-processes raw markdown to protect `$`/`$$` math from cmark
- `Parser/BlockNode+Math.swift` — Extracts `$$MATH_BLOCK:base64$$` placeholders into `.mathBlock` nodes
- `Parser/InlineNode+Math.swift` — Extracts `$MATH:base64$` placeholders into `.math` nodes
- `Parser/MarkdownParser.swift` — Hooks preprocessor before `cmark_parser_feed`
- `Renderer/MathRenderer.swift` — MathJax rendering (loads all TeX packages via `Packages.all`)
- `Views/Blocks/MathBlockView.swift` — SwiftUI view for block math
- `Renderer/TextInlineRenderer.swift` — Renders inline math as images in Text

## Troubleshooting

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
