# Code map — AutoClick

Branch: `develop`

This map divides the current implementation into stable responsibilities. Make changes in the owning module first; update callers and tests only where the interface changes.

## Main runtime file: `AutoClick.mm`

| Region | Current approximate lines | Responsibility | Edit here when… |
|---|---:|---|---|
| 01. Imports and shared declarations | 1–223 | Framework imports, `Config`, `TrackedTarget`, `BotState`, global state, `ConfigStorage` | Adding a setting, target metadata, or state shared across modules |
| 02. Touch engine | 224–578 | Synthetic touch dispatch, tap/swipe helpers, combo sequences | Changing gesture coordinates, touch timing, or C1/C2/C3 sequences |
| 03. Vision engine | 579–907 | Metal readback, frame processing, segmentation invocation, tracking, lock selection | Changing frame ingestion, target tracking, or selection policy |
| 04. Metal hooks | 908–938 | `CAMetalLayer` hook and drawable capture entry point | Changing when/how frames are captured |
| 05. Overlay UI | 939–1348 | Passthrough window, ImGui controller, menu, buttons, sliders | Changing visible controls or overlay behavior |
| 06. Bootstrap | 1349–end | Window setup and dylib constructor | Changing initialization order or hook installation |

Line numbers are approximate and will move as code changes. Use the named symbol/section as the stable anchor.

## Vision and health-bar modules

| File | Single responsibility |
|---|---|
| `HealthBarDetector.hpp` | Per-pixel color classification: red hero HP, yellow tower HP, shield colors |
| `HealthBarSegmenter.hpp` | Group classified pixels into horizontal bar observations; estimate geometry and call downstream analyzers |
| `HPAnalyzer.hpp` | Convert the red fill/track geometry into HP percentage and confidence |
| `LevelRecognizer.hpp` / `LevelRecognizer.mm` | Recognize the numeric level badge using Apple Vision OCR and image preprocessing |
| `TargetClassifier.hpp` | Combine color, geometry, Level OCR evidence, and confidence into hero/tower/unknown |
| `AutoClick.mm → VisionEngine` | Consume observations, associate observations with tracked targets, maintain lock and choose a target |

## Tests

| Test file | What it protects |
|---|---|
| `tests/HPAnalyzerTests.cpp` | HP percentage calculation and edge cases |
| `tests/LevelRecognizerTests.cpp` | Level parsing/recognition helpers |
| `tests/TargetClassifierTests.cpp` | Hero/tower/unknown classification rules |
| `tests/ReferenceImageOCR.mm` | OCR and segmenter diagnostics against `Picture.zip` reference images |

## Safe edit order

1. Change the smallest owning module.
2. Add/update a focused test for that module.
3. Run the relevant test in GitHub Actions.
4. Update the caller in `AutoClick.mm` only if the module interface changed.
5. Run the full build and all reference-image tests.
6. Review the diff before merging to `main`.

## Important boundaries

- Do not put OCR implementation inside `AutoClick.mm`; keep it in `LevelRecognizer`.
- Do not put HP percentage arithmetic inside the overlay or touch engine; keep it in `HPAnalyzer`.
- Do not let yellow tower bars enter the enemy-hero tracker.
- Shield pixels (purple/gray) must not increase or decrease the red HP percentage.
- Keep target-selection policy separate from raw pixel segmentation. Segmentation answers “what bars are visible”; tracking answers “which observation belongs to which target”; selection answers “which target should be prioritized”.
- Avoid moving the large Objective-C++ runtime classes into separate translation units until shared globals and interfaces are formalized. First stabilize module boundaries and tests.
