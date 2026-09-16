# Engineering review and optimization

Review date: 2026-09-05. Scope: the native macOS application, bundled agent runtime, persistence formats, resources, tests, and build/packaging scripts.

## Outcome and limits

This pass implements targeted reductions in repeated work, stronger cancellation and resource ownership, and fixes for stale asynchronous file-operation results. It does not introduce a new architecture, change product controls, replace the text engine, change animation durations, alter model/tool configuration, or migrate stored data.

Debug and release builds pass, including a release build with Swift warnings treated as errors. The TypeScript suite passes all 30 tests. A new offline Swift regression harness exercises actual application implementations, temporary libraries, deliberate persistence failures, and real Swift-to-Node subprocess cancellation.

This is not certification of visual equivalence or a measured whole-application speedup. Full Xcode, XCTest, Instruments, GUI automation, and permission-dependent capture validation were unavailable. The application was not launched against the user's library, and the existing signed `build/Fx.app` was not replaced. The remaining validation and important unresolved finding are below.

There is no Git repository in this workspace. A pre-edit source/test/script snapshot was retained at `/private/tmp/fx-engineering-baseline.jnI75Y`; it is temporary storage, not a durable backup.

## System and ownership map

The application is a single SwiftPM executable, not an Xcode project. `Package.swift` uses Swift tools 6.0, Swift 6 language checking, and a macOS 26.2 deployment target. There are no third-party Swift package dependencies. The bundle script compiles TypeScript and copies the runtime and resources into the app before signing.

| Boundary | State and execution ownership | Important lifetime/data path |
| --- | --- | --- |
| App bootstrap | `FxApp` owns `AppServices` through `@StateObject`; services own store, capture coordinator, and island activity | Configuration, legacy migration, selected-library metadata, and bundled declarations load before normal interaction |
| Windows and island | MainActor `AppDelegate` / `FxIslandWindowController`, AppKit windows and panels | Existing reopen routing, key-window behavior, positioning, snapshot/Metal transition, and reduced-motion fallback remain intact |
| Library | MainActor `CaptureStore`, published records/collections/selection | Each record is a folder with atomic metadata writes; externally editable content and detail files remain authoritative under the existing fallback rules |
| Gallery | Store-derived presentation snapshots; SwiftUI cards and custom `Layout` | UUID identity, original order, space/trash filtering, aspect ratios, and masonry equations are unchanged |
| Detail | Local editable SwiftUI state; immutable text-source descriptor | One keyed view task reads text away from MainActor and rejects superseded results before publishing |
| Notebook editor | Local notebook state, UUID-based row bindings, native `NSTextView` bridge | Editing, selection, undo handling, drag/drop, focus, scroll targeting, and save/close workflow remain in the existing implementation |
| Agent run | Editor retains the explicit run task and cancellation handle until completion | MainActor captures referenced descriptors; a nonactor async operation prepares files/transcript and runs Node; compact events cross back to MainActor |
| Runtime process | `ContextPiRunner` owns process, pipe, handles, temporary files, and structured stdout child | Stop/parent-task cancellation signals the process; stream delivery is joined on exit; cancellation references and file handles are released |
| Node agent | Per-run pi Agent, subscription, abort listener, fork snapshots | Tool opt-in, model selection, subagent semantics, stream backpressure, output schema, and timeouts remain unchanged |
| Artifacts | MainActor tree model, configuration revision and per-directory request identity | Shallow nonactor scans; only current results publish; manual/run-triggered refresh retains its existing triggers |
| Capture integration | App-scoped coordinator, hotkeys, workspace observer, global mouse monitor, pasteboard timer | Capture-mode observation starts/stops with the mode; app termination explicitly tears down registrations |
| Drawing and caches | Visibility-controlled avatar/Metal drawing; bounded image/Markdown caches | Existing frame cadence, decode dimensions, render styling, and cache limits are retained |

Nonisolated async work uses the generic executor with this package's current settings. `NonisolatedNonsendingByDefault` and default MainActor isolation are not enabled. Revisit these boundaries if enabling Approachable Concurrency later; do not assume these execution semantics survive a build-setting change.

## Implemented changes

### Gallery and rendering

- `CaptureStore.gallerySnapshot(in:)` reuses the filtered/mapped gallery and its layout signature until records, collections, or selection change. Previously unrelated parent updates rebuilt URL-backed presentation values and rehashed the entire gallery. The cache is private, nonpublished, and bounded by the finite set of capture spaces.
- `ContentView` consumes that snapshot; count-only filtering no longer creates a temporary array. Masonry retains its exact placement calculation, with reserved frame capacity and removal of unused cached aspect-ratio storage.
- Query attachment rendering has an equatable leaf keyed by unchanged attachment bytes, avoiding `NSImage(data:)` recreation during unrelated prompt edits. Size, clipping, fallback image, and remove button remain unchanged.
- `ContextFastTextEditor` avoids assigning an unchanged AppKit font/color and invalidates measurements when typography or sizing inputs actually change. The native editor, selection restoration, and undo behavior are retained.
- The already-present UUID binding helper is now used by notebook rows. Reads/writes resolve the current UUID instead of retaining an obsolete array index during deletion/reordering.
- Avatar sampling no longer computes a discarded previous frame after a transition has completed or duplicates base sampling during an idle hold. A zero-deformation circular profile is reused. Expression timing, random decisions, sample count, pointer tracking, and frame cadence are unchanged. These are algebraically redundant calculations, not a lower-quality rendering mode; screenshot/motion comparison is still required.

### File reads, startup, and persistence

- A bootstrap-only metadata cache shares unchanged directory scans between initial loading and bundled declaration checks. Metadata writes invalidate the relevant folder. The cache is discarded before initialization returns, so later explicit reloads still observe external edits.
- `CaptureTextSource` replaces duplicate detail/context serialization. It captures immutable record/file locations on MainActor, preserves source/tag/tab ordering and empty-file fallbacks, and can load details without retaining the store. It is not a persistent file-content cache.
- Run preparation previously built contexts for every available record on MainActor. It now reads only referenced context records whose notebook cell needs the live-text fallback, plus the applicable continuation transcript, away from MainActor. Frozen cell content and referenced media remain unchanged. The unused all-records payload field was removed.
- Detail refresh uses a single `.task(id:)` keyed by record and refresh revision. Cancellation, revision, record equality, and original file location are checked before applying a result. Save-and-copy waits for the accepted refresh; activation/tab/save refresh triggers remain present.
- Cover and detail-file imports capture their original destination before suspension and resolve the latest record by UUID and folder afterward. An insertion, edit, or collection switch no longer commits through a stale index or overwrites unrelated metadata. New asynchronous captures publish only into their original destination collection.
- Cover replacement/removal commits metadata before deleting previous cover files. Failed synchronous and asynchronous replacements clean up newly created media, retaining the old usable cover and visible metadata. These changes preserve normal successful output while protecting failure paths.

### Concurrency, teardown, and resource use

- `ContextPiRunner` now propagates cancellation of its Swift task to its registered process, including the pre-launch race. Its stdout reader is a structured child, joined on success and error, and reuses one decoder. Pipe/log handles, termination callback, and cancellation ownership are cleaned up on exit.
- Image decode and artifact/text reads no longer need detached wrapper tasks where nonactor async execution suffices. Cooperative cancellation prevents obsolete work from starting/publishing; an already-running synchronous ImageIO or filesystem call is not forcibly interruptible.
- Artifact configuration and per-directory request generations prevent old scans from overwriting newer exclusions or refreshed content, including same-root reconfiguration. Refresh builds a result and publishes once when changed. Cancellation cleans up loading ownership. Filesystem order, hidden/symlink handling, and shallow expansion semantics remain unchanged.
- The repeating pasteboard timer weakly captures its coordinator. Capture shutdown removes its event monitor and workspace observer, cancels inspection/status tasks, unregisters hotkeys, and closes the tooltip.
- The modifier chord latch is now only accessed by its polling queue; shutdown no longer races a main-thread latch reset against polling. The 50 ms interval and 2 ms leeway are unchanged. Poller destruction also cancels the timer.
- Editor disappearance clears the scroll cache callback, breaking its retained closure/state cycle. It does **not** introduce cancellation based on window visibility: an agent run must not be cancelled merely because the window folds into the island. Normal editor closing already refuses while running; the explicit operation task is retained until completion.
- Node runs remove abort listeners and agent subscriptions in `finally`, clear fork snapshots, avoid cloning transcripts for non-forking delegations, and release a fork snapshot when its child takes ownership. Reverse-copy searching was replaced by `findLast`.
- Search and agent execution check already-aborted signals before provider work, including cancellation while resolving credentials or delivering a round-start callback. Existing request deadlines, endpoint parameters, tool opt-in, and normal result/error formats remain intact.
- Image cache cost now uses decoded row bytes × height instead of assuming four bytes per pixel. Its existing 160-item / 256 MiB advisory limits remain unchanged.

### Packaging

`scripts/build-app.sh` uses the lockfile through `npm ci` when dependencies are absent. It prunes development-only dependencies from the **copied bundle tree**, offline and without lifecycle scripts, before signing. Workspace development dependencies and pinned production versions remain intact.

In a temporary packaging stage, `du -sh` reported 115 MB for the original dependency tree and 92 MB after pruning. The staged compiled CLI successfully inspected the smoke notebook. This is approximately 23 MB less copied dependency storage, not a measured resident-memory reduction. Node itself is still an external runtime requirement; packaging it or changing the dependency graph would be a separate distribution decision.

## Validation performed

Environment: Apple Silicon, macOS 26.2 (25C56), Swift 6.3.3, macOS SDK 26.5, Node 26.7.0, Command Line Tools selected.

| Check | Result |
| --- | --- |
| Swift debug application build | Passed |
| Swift release build with `-Xswiftc -warnings-as-errors` | Passed; no Swift source/concurrency diagnostics |
| `npm run check --prefix Runtime` | TypeScript checking and all 30 tests passed |
| `npm run build --prefix Runtime` | Passed; compiled runtime refreshed |
| `zsh scripts/check-engineering.sh` | Passed against real debug application object files |
| Shell syntax checks for build/check scripts | Passed |
| Offline production-dependency pruning and staged CLI inspection | Passed |
| Full `swift test` | Blocked by `no such module 'XCTest'` in the installed CLT environment |
| Full signed app build, live provider/capture testing, UI comparison, Instruments | Not performed |

SwiftPM also reports that its user-level configuration/security cache directories are inaccessible under this environment's restrictions. Local build/module caches permit successful builds; these are not Swift source warnings.

The offline Swift checks cover:

- Exact context strings, UTF-8 content, empty-file fallback, external edits, builtin formatting, and media context consistency.
- Byte-for-byte runtime JSON comparison between selective preparation and the previous all-record projection for the fixture; frozen context does not request live text.
- Builtin declaration idempotence, identity-preserving updates, and disk reloads after an external metadata edit.
- Gallery backing-array reuse and invalidation after metadata, space, trash, and collection changes.
- Deterministically interleaved record insertion, collection switching, and title editing while file operations suspend.
- Deliberate metadata commit failure during synchronous/asynchronous cover replacement and removal: old media and metadata survive, new files do not leak.
- Artifact sort/hidden/filter rules, overlapping configurations, refresh cleanup, and cancellation.
- Pre-cancelled preparation/scanning/runs; real Node stdout with 128 Unicode deltas; complete event delivery; repeated stderr failures; Swift task cancellation terminating a waiting process before its fixture timeout.

`EngineeringChecks.swift` is shared by a normal XCTest entry point and a CLT-compatible command-line harness. The harness links the application's actual debug objects without its GUI entry point; it does not mock XCTest or replace the existing test suite. All fixture files are temporary and removed by the harness. Live providers and credentials are not used.

One debug diagnostic measured 100 gallery reads with 200 fixture records (199 eligible after mutation): approximately 134 ms rebuilding the original filtered/mapped projection versus 22 microseconds reading the warm cached snapshot. This measures only repeated projection access, excludes real SwiftUI layout/painting, and is not a release benchmark or an application-wide speedup claim. The correctness assertion is backing-array reuse and correct invalidation, not an unstable timing threshold.

## Important unresolved finding

**Session continuation launch condition needs a focused functional regression investigation.** In `ContextPiRunner.execute`, `--continue` is appended only if an output cell contains nonempty `run.messages`. The editor's `compactInMemoryRunState()` removes those embedded messages after persistence. `prepareRuntime` loads `messages.json`, and `previousRuntimeOutput` embeds those continuation messages into the temporary runtime notebook, but the launch condition does not consult that payload. `Runtime/src/notebook.ts` resumes only when the CLI's continue option is true.

Consequently, a compacted/reloaded session can have a persisted transcript available yet launch without continuation. This is an existing cross-layer inconsistency identified by source inspection, not a live-provider reproduction. The runtime's own continuation tests pass when the continue option is explicitly supplied; they do not cover this Swift CLI-argument decision. This pass leaves the condition unchanged because changing which history and queries reach a model is a functional/data-semantic change, not a transparent performance optimization. Verify the intended resume contract with a focused Swift-to-CLI fixture before fixing it.

## Costs retained deliberately and next profiling targets

| Area | Remaining cost / risk | Why not rewritten here |
| --- | --- | --- |
| Cold startup / collection switches | Initial metadata scan and decode still run synchronously on MainActor | Async loading changes first-frame/loading and selection ordering; shared scans reduce duplication without introducing those changes |
| Session saves and synchronous capture commands | JSON/content serialization and atomic writes can block MainActor on large data or slow volumes; multiple session files are not a cross-file transaction | Preserve commit/error ordering and existing formats; profile large transcripts and slow disks before designing a serialized persistence boundary |
| Library context previews / copy | Empty-body referenced previews and explicit copy paths still perform synchronous reads | Persistent caching or asynchronous placeholder rendering changes external-edit freshness/loading behavior; normal inserted notebook contexts already hold frozen bodies |
| Gallery | Masonry eagerly hosts all cards; image cache keys do not include file modification dates; identical concurrent misses are not coalesced | Virtualization can alter measured heights, scroll offsets, animations, and view lifetimes; freshness/coalescing needs a defined file invalidation policy |
| Long output | Cold Markdown, JSON, and diff presentation may still parse on MainActor; complete transcripts/events remain large | Existing caches and incremental stream batching are retained; truncation, lossy history, or a different Markdown engine would change the product |
| Capture IPC | Accessibility queries, pasteboard/image decoding, and browser automation can stall MainActor when another application is slow | Moving AppKit/AX/automation work needs specific thread-safety and permission tests; adding timeouts could change capture results |
| Idle power | Modifier-only chord polls at 20 Hz; visible avatar renders at its original cadence | Alternative input monitors may change permissions/shortcut semantics; lowering cadence changes motion. Existing hidden-avatar pause and transition display-link stop remain in place |
| Metal startup | Synchronous shader/pipeline prewarm remains | Moving it could trade first-frame latency for a first-transition hitch; requires launch and transition measurements together |
| Bounded user actions | Some awaited detached file-copy/encode/trash operations and brief focus/feedback tasks remain | File transactions intentionally finish once begun; indiscriminate cancellation could leave incomplete data. No claim is made that every task is now structured |
| Build/dependencies | Production Node tree is still substantial; no dependency upgrade, Swift Observation migration, compatibility-format removal, or renderer replacement | None had evidence of a safe equivalent payoff large enough to justify migration risk |

No new filesystem watcher, periodic refresh, analytics, profiler dependency, logging of user content, or network request was introduced. Error strings, localization, keyboard shortcuts, capture permissions, model defaults, network endpoints, cache resolution, and persistence versions were not intentionally changed.

## Final on-device validation checklist

Use a disposable library and a separately retained baseline app, with matching signing identity and permissions. Compare release builds on the same display, scale factor, and window size.

1. Record cold/warm startup and first usable frame; switch small and large collections. Use Time Profiler and File Activity to separate metadata work from Metal prewarm. Repeat on a slow/external volume.
2. Scroll mixed-media galleries, resize the window, move the column slider, switch spaces, open/close details, and add/remove covers. Use SwiftUI Instruments cause/effect and long-body tracks, Core Animation frame timing, and screenshot comparison. Check image orientation and text wrapping.
3. Type and paste long Unicode text, use IME, undo/redo, delete/reorder the focused row, drag/drop, switch tabs, and restore focus. Verify the NSTextView bridge and UUID binding during removal transitions.
4. Compare detail Save, Save-and-copy, empty text, external file edits followed by activation, tab add/delete, errors, and feedback timing. Exercise collection switches and deletion while large video/image imports are in flight.
5. Run streaming, tool-heavy, forked, failed, and cancelled sessions. Fold/unfold the island mid-run and verify continuation separately. Inspect saved notebook, transcript, events, usage, and artifact files without exposing credentials.
6. Exercise manual artifact refresh, rapid expand/collapse, same-root exclusion changes, symlinks, externally deleted folders, and Trash. Check that obsolete work cannot restore stale rows.
7. Verify Dock/Finder reopen, multi-display positioning, key-window/responder behavior, global shortcuts, capture mode, pointer tooltip, pasteboard changes, Accessibility/Screen Recording/Automation permission failures, reduced motion, appearance, and accessibility labels.
8. Use Allocations/Leaks and System Trace over repeated runs and view open/close cycles. Watch process/pipe handles, event listeners, image/Markdown cache pressure, retained view state, and idle wakeups with capture enabled/disabled and island visible/hidden. Run Thread Sanitizer and the complete XCTest suite under full Xcode.

Do not claim whole-app responsiveness or energy improvements until these representative workloads have before/after measurements. In particular, cache microbenchmarks do not establish scroll smoothness, startup latency, memory high-water marks, or visual parity.

## Primary engineering references

- Apple's [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance) informed the focus on actual body/update dependencies and the recommendation to verify cause/effect with Instruments.
- The [Swift concurrency guide](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), [SE-0338 executor semantics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md), and [Swift 6 data-race safety guidance](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/) informed structured child ownership, cancellation propagation, and explicit executor assumptions.
- [Nuke's image pipeline source](https://github.com/kean/Nuke/blob/main/Sources/Nuke/Pipeline/ImagePipeline.swift) was reviewed as a primary-source reference for request ownership/cancellation and image pipeline design. It was not added as a dependency; more elaborate coalescing is deferred until needed and compatible with Fx's file semantics.
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) was reviewed as a native macOS editor reference. Its specialized editor scope supports caution about replacing Fx's existing general-purpose `NSTextView` bridge: performance patterns are not evidence of complete interaction parity.

These references informed local engineering judgments; no external implementation was copied into the project.
