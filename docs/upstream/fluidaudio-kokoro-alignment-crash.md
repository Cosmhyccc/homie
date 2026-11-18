# Posted: https://github.com/FluidInference/FluidAudio/issues/1172 (Nov 17, 2026)

**Title:** Kokoro ANE v3: deterministic SIGTRAP in libBNNS (Alignment stage, CPU fallback) for ~5% of English sentences on M5 / macOS 26.7.2

**Setup:** FluidAudio main @ 16780f0 (Nov 14), `KokoroAneManager(version: .v3)`, default compute units (`aneTailGpu` on OS 26), voice `af_heart`, speed 1.0. Apple M5 (8-core GPU), 16 GB, macOS 26.7.2. Release build, SwiftPM.

**Repro:** `try await manager.synthesizeDetailed(text: "Your next meeting is the design review at four.", voice: "af_heart")` crashes every time on a fresh process. Also: "Lunch with Sam moves to three, so plan ahead." and "Your next meeting is the design review at four!". Same words with a comma moved ("…design review, at four.") synthesize fine. 8 of 153 short calendar-style sentences crashed.

**Crash:** EXC_BREAKPOINT (SIGTRAP) in libBNNS → BNNSGraphContextExecute_v2 → E5RT BnnsCpuInferenceOperation::ExecuteSync → MLModel prediction from `KokoroAneV3Pipeline.run(inputIds:style:speed:pauses:)` at the `predict("Alignment", …)` call (KokoroAneV3Pipeline.swift:188).

**Tried:** v3 rejects non-default routings ("ANE-v3 supports the default, aneTailGpu or aneTailCpu routing only"), so Alignment can't be moved off the ANE/CPU-fallback route from the app side.

**Workaround we ship:** restart the helper process and retry with a comma moved before the last two words.
