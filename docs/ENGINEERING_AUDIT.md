# AutoClick — Engineering Audit (R&D)

Date: 2026-11-22
Branch: develop
Base: main (commit ac7fc0318475)

## Scope

This audit intentionally excludes App Store policy and release-readiness work, per project direction. It focuses on stability, maintainability, diagnostics, image-processing reliability, configuration, and iOS 26 runtime testing.

This is a source-level review, not proof of runtime behavior on a device.

## Current structure observed

- Main implementation is concentrated in `AutoClick.mm` (approximately 1,359 lines at the time of review).
- Build configuration exists in `Makefile`.
- GitHub Actions workflow exists at `.github/workflows/build.yml`.
- Dear ImGui is fetched during CI from its upstream repository without a pinned commit in the workflow.
- UI, configuration storage, Metal integration, image processing, and state management are substantially co-located in the main Objective-C++ source.
- Configuration is persisted as JSON.
- Vision processing uses Metal texture readback and CPU-side pixel analysis.
- Target state and processing state are shared across asynchronous work; synchronization and resource lifetime deserve a focused review.
- Target queue-related configuration fields exist, but the reviewed source does not show a complete queue feature.
- A stealth-related configuration field exists; the prior secure-view mechanism was removed in the ImGui stability change, so the field should not be treated as an implemented feature.

## Risks and follow-up investigations

### P1 — Concurrency and state ownership
Review all reads and writes of shared configuration and target state across the main thread, Vision queue, and asynchronous callbacks. Define ownership rules and synchronization before refactoring.

### P1 — Metal readback lifecycle
Review command queue/buffer creation, shared readback buffer reuse, completion-handler lifetime, texture dimensions/stride, and behavior when the app backgrounds or the renderer is recreated.

### P1 — Vision input correctness
Validate pixel format, channel ordering, ROI bounds, screen scale, orientation, and coordinate conversion using recorded test frames. Add deterministic test fixtures before changing detection thresholds or algorithms.

### P2 — Diagnostics
Add structured logs for initialization, renderer state, frame processing duration, dropped frames, invalid input frames, and recoverable failures. Avoid logging sensitive user content.

### P2 — Dependency reproducibility
Pin Dear ImGui to a known tag or commit and record the version used by CI.

### P2 — Modularization
Refactor incrementally behind stable interfaces. Suggested first extraction order:
1. Configuration model and persistence
2. Diagnostics/logging
3. Vision image-processing utilities (with offline fixtures)
4. Metal capture/readback lifecycle
5. UI and overlay presentation

Do not perform a large rewrite in one change.

### P2 — Automated checks
Add compile-time checks and unit tests for pure helpers, configuration encode/decode, ROI calculations, coordinate transforms, and image-processing fixtures where feasible.

## Recommended test matrix

- iOS 26 device, portrait and landscape if supported
- App launch, background/foreground, interruption, and renderer recreation
- Multiple display scales and supported resolutions
- Repeated menu open/close and floating UI interactions
- Long-duration run with memory and thermal observation
- Missing/invalid Metal drawable and command-buffer failure paths
- Configuration save/load and malformed or older JSON

## Change-control rules

- Keep `main` as the known-good baseline.
- Develop on `develop` or short-lived feature branches.
- One concern per pull request.
- Build and inspect the diff before merging.
- Do not claim runtime success based on a successful CI build alone.

## Explicitly out of scope for this phase

App Store policy and release compliance review.

## Metal capture review — 2026-11-22

A focused source review of `VisionEngine::SubmitMetalTextureAsync` identified failure paths after the processing gate was acquired. Previously, failures to create the command queue, readback buffer, command buffer, or blit encoder could leave the processing flag set, preventing subsequent frames from entering the pipeline.

A focused change is proposed in PR #2:
- Validate texture dimensions and readback-size arithmetic before allocation.
- Release the processing gate on resource-creation and GPU-completion failures.
- Recreate the blit queue if the source Metal device changes.
- Capture the specific readback buffer in the completion handler rather than looking up a mutable global buffer.
- Emit diagnostic messages for recoverable capture failures.

PR: https://github.com/lenguyenvulnv95/Autoclick/pull/2

The change does not alter image classification, ROI definitions, target tracking/selection, or touch/combo behavior. It has been reviewed at source-diff level only; a successful iOS build and on-device lifecycle test are still outstanding.
