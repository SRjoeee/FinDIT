# Review Notes — Pipeline & Watcher Fixes (2026-02-09)

## Scope

This round fixes four high-priority issues in pipeline correctness and runtime responsiveness:

1. Orphaned same-path restore could silently reuse stale index data.
2. Cancellation intent was not propagated consistently across long pipeline stages.
3. File watcher event handling performed blocking DB/file I/O on `@MainActor`.
4. File watcher callbacks could interleave across suspension points and reorder events.

Changed files:

- `Sources/FindItCore/Pipeline/PipelineManager.swift`
- `Sources/FindItApp/FileWatcherManager.swift`
- `Tests/FindItCoreTests/PipelineManagerTests.swift`

---

## 1) Orphaned same-path restore correctness

### Why this was needed

For videos in `orphaned` state, the old flow did not validate content hash for same-path restores.
If a different file appeared at the same path, old clips/transcript/vision metadata could be reused incorrectly.

### What changed

In `PipelineManager.processVideo(...)`:

- Added explicit `orphaned` branch before normal pending flow.
- If `storedHash == currentHash`:
  - mark video back to `completed`
  - clear `orphaned_at`
  - return fast with `requiresForceSync` semantics preserved
  - non-parallel path performs `SyncEngine.sync(... force: true)`
- If hash missing/mismatched:
  - reset to `pending`
  - clear `last_processed_clip`
  - clear stale `file_hash`
  - continue full rebuild pipeline

### Review focus

- `Sources/FindItCore/Pipeline/PipelineManager.swift` around:
  - orphaned branch insertion
  - `requiresForceSync`/`force: true` handling

---

## 2) Cancellation propagation in pipeline stages

### Why this was needed

User-facing cancel should stop work as soon as practical.
Previously, some long loops/stages could continue because cancellation was not explicitly checked or was swallowed by generic `catch`.

### What changed

In `PipelineManager.processVideo(...)`:

- Added `try Task.checkCancellation()` at key boundaries:
  - function entry
  - hash-heavy paths
  - scene/keyframe stage
  - local vision loop
  - STT stage
  - remote/local VLM vision loop
  - embedding batch/fallback loop
  - pre-sync stage
- Added `catch is CancellationError` branches to rethrow cancellation (instead of downgrading to non-fatal stage failure paths).

### Review focus

- `Sources/FindItCore/Pipeline/PipelineManager.swift`:
  - `catch is CancellationError { throw CancellationError() }`
  - cancellation checks inside loops

---

## 3) FileWatcher main-thread I/O pressure

### Why this was needed

`FileWatcherManager` runs on `@MainActor`.
Opening DB and batch delete/update during event storms can block UI responsiveness.

### What changed

In `FileWatcherManager`:

- Converted event handling path to async (`handleEvents` / `processEvents`).
- Added `runBlockingIO(...)` helper (utility queue + continuation).
- Moved blocking operations off main actor:
  - open folder DB
  - orphan mark batch
  - hard delete batch

Main-actor responsibilities remain:

- queueing into `IndexingManager`
- `reloadFolders()`
- vector cache invalidation signaling

### Review focus

- `Sources/FindItApp/FileWatcherManager.swift`:
  - callback entry and async flow
  - `runBlockingIO` usage boundaries

---

## 4) FileWatcher event ordering correctness

### Why this was needed

After moving work to async, each callback spawned an independent task.
At `await` suspension points, later callbacks could run first, causing add/remove batches for the same file to be applied out of order.

### What changed

In `FileWatcherManager`:

- Added a serialized event queue:
  - `pendingEvents` + `eventDrainTask`
  - `enqueueEvents(...)` for callback and deferred replay paths
  - single `drainEventQueue()` to process batches in callback order
- `stopWatching()` now cancels the drain task and clears queued events.
- `unwatchFolder()` now drops queued events for that folder.
- Added `guard isWatching` in `handleEvents` to avoid processing stale callbacks after stop.

### Review focus

- `Sources/FindItApp/FileWatcherManager.swift`:
  - `enqueueEvents(...)`
  - `drainEventQueue()`
  - `stopWatching()` / `unwatchFolder()` queue cleanup

---

## Tests added

`Tests/FindItCoreTests/PipelineManagerTests.swift`:

- `testProcessVideo_reindexesAfterOrphanedFileContentChange`
- `testProcessVideo_orphanedSamePathHashMatchFastRecovers`

These cover:

- mismatch -> rebuild path
- hash match -> fast recover + force-sync signaling path

---

## Validation run

- `swift test --filter PipelineManagerTests` ✅
- `swift build --target FindItApp` ✅
- `swift test` (full suite, 714 tests) ✅
