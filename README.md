# Curatez

A native macOS SwiftUI visual library with system-wide capture support.

## Run

```bash
swift run Curatez
```

You can also open `Package.swift` directly in Xcode and run the `Curatez` scheme.

Requires macOS 14 or newer.

## Model menu

The model menu beside **Run** reads `~/.fx/settings.json` for compatibility with
existing local configuration. Model identifiers are passed to Curatez's bundled
agent runtime as `provider/model`. For example:

```json
{
  "defaultModel": "deepseek/deepseek-v4-flash",
  "models": [
    "deepseek/deepseek-v4-flash",
    {
      "provider": "bailian",
      "model": "qwen3.7-max",
      "name": "Qwen 3.7 Max"
    },
    {
      "spec": "anthropic/claude-sonnet",
      "name": "Claude Sonnet"
    }
  ]
}
```

Choose **重新读取模型配置** at the bottom of the menu after editing the file.
The configured `defaultModel` is used when the notebook remains on
**default model**. Provider credentials are resolved inside Curatez's runtime
from environment variables and `~/.pi/agent/models.json`; secrets are never
written into a Session.

## Agent runtime and Sessions

Curatez owns the runtime under `Runtime/` and packages its compiled JavaScript,
locked dependencies, model registry, agent loop integration, Tool registry,
progressive Skill loading, Subagent isolation/forking, events, usage, and resume
support inside `Curatez.app`. It does not execute code from `~/repos/fx`.

A saved Session contains `session.md`, `notebook.json`, `runtime-output.json`,
`messages.json`, `events.json`, `rounds.json`, and (when reported by the
provider) `usage.json`. Appending another Query resumes from the persisted pi
message history rather than replaying earlier Query cells.

## Capture mode

- `⌘D`: turn capture mode on or off.
- Select accessible text in another app, or copy text/link/image content, to show the save tooltip at the pointer.
- Copied `http(s)` URLs and complete bare web addresses are recognized and saved as openable link cards; other copied strings are saved as text.
- `⌥⌘S`: save the most recently used browser window snapshot and its current URL.
- The toolbar target button toggles capture mode.

The top bar represents real collection folders. Use its `+` button to bind an existing folder; the active tab is the destination for new captures. Every capture is stored in its own subfolder:

```text
Selected collection folder/
└── Item title-1234ABCD/
    ├── metadata.json
    ├── content.txt, image.png, or video.mov
    ├── cover.png or cover-video.mov (optional)
    └── Notes.md and other detail-tab files (optional)
```

Folder tabs can be renamed, which renames the backing folder. Deleting a folder tab moves the folder and all of its items to the Trash after confirmation. Item details support image/video covers, title, tags, description, and additional editable Markdown or text tabs.

The library also accepts local movie files and direct `mp4`, `mov`, `m4v`, or `m3u8` URLs. Local movies are copied into the active collection item folder and receive a generated poster image; direct video URLs can be played inside their gallery card.

Text selection requires Accessibility permission. Browser snapshots require Screen Recording permission. Reading a Safari/Chrome/Arc/Edge/Brave URL may request Automation permission.

Browser snapshots capture the currently visible browser window. Capturing a complete page beyond its scrollable viewport requires a browser extension or an automated scroll-and-stitch workflow.

## Island avatar

The left side of the collapsed island contains a native, animated bloub avatar
rendered as a compact light-on-dark icon.
Its expression is driven by separate task-kind and lifecycle-status models, so
new workflows can reuse the same idle, ready, processing, success, attention,
failure, and paused visual language. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for attribution.

## Build a stable macOS app bundle

For system permissions to remain attached to a stable bundle identifier, build and run the `.app` bundle:

```bash
zsh scripts/build-app.sh
open build/Curatez.app
```
