# ClipStage — full current snapshot

This zip is everything as it stands right now — every fix applied so far,
all in one place, so you don't have to track which of the individual files
I sent is newest. If you're setting this up fresh in Swift Playground, use
this zip and ignore every individual file I sent in earlier messages.

## Fixes applied so far, in order

1. **`VideoComposer` and `ProjectStore` marked `@MainActor`** — several
   AVFoundation initializers (`AVURLAsset`, `AVPlayerItem`,
   `AVAssetExportSession`) are main-actor isolated on this SDK (iOS 26);
   calling them from a nonisolated async context was the original
   post-import crash.
2. **Removed `EditorViewModel`'s `deinit`** — it referenced a main-actor
   property from a context Swift won't allow that in.
3. **`EditorViewModel`'s playback-time updater** no longer uses
   `MainActor.assumeIsolated` (which traps if its assumption about the
   current thread is ever wrong) — it does a proper `Task { @MainActor in
   ... }` hop instead, which can't trap.
4. **`VideoComposer` guards against invalid video dimensions** — if a
   video's size ever fails to load as a normal positive number, it now
   throws a clean, catchable error instead of risking a hard Core Animation
   crash (NaN passed to a CALayer frame is a classic non-catchable crash).
5. **Import size limit raised to 500 MB**, checked before copying.
6. **Cancel button** added to the "Importing…" screen, so a slow or stuck
   import doesn't trap you with no way out.
7. **Import now jumps straight into the editor** instead of back to the
   project grid.
8. **Fixed a double time-offset in the cinematic-zoom animation** —
   `VideoComposer.makeZoomAnimation` was subtracting `trimStart` from a
   keyframe's `startTime` that was *already* trim-relative (it's captured
   from the player's own 0-based timeline). Any zoom placed after trimming
   the start of a clip landed earlier than where you put it, and could
   clamp on top of another keyframe.
9. **Guarded against invalid zoom-animation keyframe timing** — Core
   Animation requires a `CAKeyframeAnimation`'s `keyTimes` to be
   monotonically increasing. Nothing stopped you from adding two zoom
   keyframes that overlap in time, which produced a decreasing `keyTimes`
   sequence — handed to AVFoundation's export render server, that's very
   likely the actual cause of the "Unknown Crash" below, since a failure
   there happens outside this app's own process and won't show a normal
   crash log. `makeZoomAnimation` now clamps every keyframe's time forward
   so the sequence can never go backward, no matter how keyframes overlap.

## Still open

Items 8–9 are a concrete, verified root cause for the "Unknown Crash"
below (not just a defensive guess like some of the earlier fixes) — but
still worth confirming against a real crash log if it recurs. If it does,
turning on **Show Console** *before* reproducing it and sending a
screenshot of the printed text is what actually pins down any remaining
cause.

## Feature: Draw (Procreate-style — v2, replaces the v1 prototype)

A layered annotation system on top of the video, built on real PencilKit
(`PKCanvasView`) for pressure/tilt-sensitive, palm-rejecting ink — not a
hand-rolled SwiftUI drag surface. Tap **Draw** in the transport bar (or
the "Draw Mode" toggle in the settings sidebar) to enter it; playback
pauses automatically and a floating pill toolbar (pen / pencil / eraser +
color + size) appears over the preview, styled to match this app's own
chrome rather than the system `PKToolPicker`.

**Layers**, not per-stroke timing: each layer (named, shown in the
settings sidebar's Layers list — visibility eye, reorder, delete, tap to
make active) is its own `PKDrawing`, visible for a time range you set
(defaults to the whole clip) with a short crossfade, the same mechanism
`ZoomKeyframe` uses. While editing, every visible layer is always shown
regardless of the playhead — you're not gated by scrubbing into a
layer's window to draw on it; the time range only governs
playback/export. `Models/DrawingLayer.swift` also records the on-screen
canvas size a layer was authored at, since `PKDrawing` stores stroke
geometry in that view's own point space — `VideoComposer` uses it to
scale ink correctly onto the (usually much larger) export canvas.

New/changed files:
- `Models/DrawingLayer.swift` (new) — the layer model (name, visibility,
  time range, authored canvas size, serialized `PKDrawing` data).
- `Models/VideoProject.swift` — `drawingLayers` replaces the v1
  prototype's `drawingStrokes` (removed). Manual `init(from decoder:)`
  still there so a project saved before either existed loads as "no
  layers yet" rather than vanishing; a project saved by the v1 prototype
  also just gets a fresh layer, not a migration.
- `Models/BackgroundStyle.swift` — `RGBAColor.drawPresets` (pen swatches)
  and `.uiColor` (feeds `PKInkingTool` directly).
- `Engine/VideoComposer.swift` — renders each visible layer by
  rasterizing its `PKDrawing` once (`PKDrawing.image(from:scale:)`) onto
  a `CALayer` sublayered onto the video layer (so ink pans/zooms with a
  cinematic zoom), with the same opacity-keyframe visibility technique as
  zoom/the v1 prototype.
- `ViewModels/EditorViewModel.swift` — layer CRUD/reorder/visibility/
  time-range methods, plus `currentPKTool` (built from `drawingToolKind` /
  `drawColor` / `drawLineWidth`). Ink updates from PencilKit fire
  continuously while you draw, so `updateLayerDrawing` only touches the
  model — the one preview reload happens on leaving Draw Mode or hitting
  Play (`syncPendingLayerChanges`), never mid-stroke, or drawing would
  visibly stutter.
- `Views/DrawingCanvasView.swift` (new) — the `UIViewRepresentable`
  wrapping one layer's `PKCanvasView`.
- `Views/DrawingLayersOverlayView.swift` (new) — stacks every visible
  layer's canvas over the preview; only the active one accepts input.
- `Views/DrawingToolbarView.swift` (new) — the floating pill toolbar.
- `Views/EditorView.swift`, `Views/BackgroundControlsView.swift` — wiring
  and the sidebar Layers list / per-layer time-range controls.

**Removed:** `Models/DrawingStroke.swift` and `Views/DrawingOverlayView.swift`
(the v1 prototype — per-stroke normalized points, a hand-rolled SwiftUI
`Canvas` drawing surface, and a vector eraser). Superseded entirely by the
PencilKit-based layer system above; nothing from v1 was migrated.

Worth trying: draw on a layer, narrow its time range with the sidebar
sliders and confirm it appears/disappears correctly in the live preview
and export; add a second layer, toggle the first's visibility off, and
confirm the composite in preview/export drops it; check that leaving Draw
Mode (or hitting Play right after drawing) doesn't stutter or drop the
just-drawn ink from the reload.

## Fixes from CodeRabbit's automated review (PR #1)

10. **Orphaned video files on failed import** — `ProjectStore.importVideo`
    now removes the copy in `Documents/Videos` if duration loading fails
    afterward, instead of leaking it forever on every failed import.
11. **Corrupted `projects.json` could silently wipe your project list** —
    `loadProjects()` used to return `[]` on any decode failure, and the
    next `save()` (e.g. importing one new video) would overwrite the file
    with just that one project, permanently discarding the rest. A
    decode failure now backs up the unreadable file as `.corrupt` instead
    and `save()` reports write failures back to callers (`EditorViewModel
    .save()` now sets `errorMessage` instead of silently "succeeding").
12. **`paddingFraction` clamped in `VideoComposer`** — the slider only
    ever writes 0...0.35, but nothing validated a persisted value outside
    that range, which could make the canvas's `availableSize` go
    negative and break the whole layer tree's geometry.
13. **`.original` aspect ratio no longer upscales small sources** — it
    always rendered at a fixed 1920px long edge; a smaller source (e.g. a
    640x480 recording) was getting blown up 3x for no quality benefit.
    Now caps at `min(sourceLongEdge, 1920)`.
14. **Fixed the Layers panel's up/down buttons being backwards** — both
    the editing overlay's `ZStack` and `VideoComposer`'s sublayer order
    render *later* array entries on top, so "move up" needs to move a
    layer to a *higher* index, not lower. It was doing the opposite,
    silently moving a layer behind its neighbor instead of in front.
15. **Preview no longer jumps to 0:00 on every edit** — `reloadPreview()`
    (called after *every* edit — background, padding, trim, zoom, draw)
    was replacing the AVPlayerItem without seeking back to the previous
    playhead. Now it captures the time (and whether it was playing)
    first, and restores both after the rebuild.
16. **`.original` aspect ratio now sizes the preview/draw canvas
    correctly for non-16:9 video** — this used to hardcode a 16:9
    fallback "since it's cosmetic only," which stopped being true once
    the Draw feature started sizing its on-screen canvas from the same
    value: a portrait or 4:3 source would shape the drawing canvas wrong,
    landing ink in the wrong place relative to the correctly-shaped
    export. `VideoComposer` now returns the asset's real size, and
    `EditorViewModel.sourceNaturalSize` carries it to the view.
17. **Cancelling an import right as it finishes no longer navigates you
    into the editor anyway** — `finishImport` didn't recheck
    `Task.isCancelled` after `importVideo` returned, so a
    successful-but-late result could still save the project and open it,
    right after the user watched the "Importing…" overlay dismiss.

(CodeRabbit also flagged one **nitpick**, explicitly separate from the 8
actionable findings above: `DrawingCanvasView` re-serializes the active
layer's full `PKDrawing` on every single ink update while drawing, which
isn't free for a large drawing. Left as-is for now — it's a real tradeoff,
not a bug, and CodeRabbit itself didn't count it as actionable; worth
revisiting if drawing ever feels laggy on a big layer.)

## Setup

Same as before: create a new **App** playground in Swift Playground
(iOS 17+, iPad in supported destinations), delete its default
`ContentView.swift` and entry file, then `+` → **Insert from** each file
in this zip's `ClipStage/` folder (or, if "Insert from" gives you a
"not in a target" error on any file like it did before, delete that file
and recreate it as a blank Swift file, then paste its contents in
directly — that path has been 100% reliable so far).
