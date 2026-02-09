# Saiman

A macOS desktop AI chat app with a Spotlight-style floating window. Press **Option+Space** from anywhere to start a conversation with Claude.

Built with Swift/AppKit. Uses Claude Opus 4.6 via AWS Bedrock.

## Features

- **Spotlight-style interface** — floating panel that appears above all windows
- **Web search** — search the web and fetch page contents via Exa
- **Reddit integration** — search and read Reddit threads
- **Image attachments** — paste or drag images into the chat (JPEG, PNG, GIF, WebP, HEIC)
- **Extended thinking** — adaptive thinking with high effort for complex questions
- **Conversation history** — SQLite-backed history with full-text search
- **Menu bar** — quick access to recent conversations from the menu bar

## Tools

The agent has access to four tools:

| Tool | Description |
|------|-------------|
| `web_search` | Search the web using Exa |
| `get_page_contents` | Fetch and extract content from a URL |
| `reddit_search` | Search Reddit posts |
| `reddit_read` | Read a full Reddit thread |

## Setup

Create `~/.saiman/.env` with:

```
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
EXA_API_KEY=...
```

AWS credentials need access to Amazon Bedrock with Claude models enabled.

Optional variables:
- `SAIMAN_BEDROCK_MODEL` — override the default model
- `SAIMAN_STALE_TIMEOUT_MINUTES` — conversation stale timeout (default: 15)

## Build & Run

```bash
./release.sh
```

This quits any running instance, builds, installs to `/Applications`, and relaunches.

## Testing

```bash
./test eval
```

Runs the eval suite which tests tool usage, search behavior, and response quality.
