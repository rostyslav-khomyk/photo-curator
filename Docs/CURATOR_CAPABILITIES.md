# Curator Capability Check

Chunk 1 checkpoint, 2026-09-07. No Photos library was read or changed.

## Verified Locally

- Installed OS: macOS 26.6.2 (25G83), Apple silicon.
- Active SDK: Xcode MacOSX.sdk. Its FoundationModels Swift interface exposes text Prompt
  construction, but no image attachment input found. Do not assume the newer online
  multimodal documentation describes this installed SDK.
- SystemLanguageModel.default.availability returned available. This is a runtime capability
  check, not a quality benchmark or proof that availability will remain unchanged.
- Vision face, feature-print similarity, and aesthetics requests report supported revisions.
  No image inference performed. Detection accuracy/performance still needs fixture testing.
- OSXPhotos is not installed in the project virtual environment. Nothing was installed.

Reproduce runtime checks: `swift Tools/check_curator_capabilities.swift`.

## Implementation Decisions

- First implementation: Vision image observations plus metadata as structured input to
  the local text model. No cloud model fallback and no OS upgrade requirement.
- Check capability at runtime; keep deterministic date/location titles if the model is
  unavailable. Never interpret an unavailable face detector as permission to upload.
- App minimum remains macOS 13: gate aesthetics/model APIs and preserve basic sync.
- Treat model-generated identity, location and context as hypotheses, not evidence.
- Named-people import remains optional and read-only. OSXPhotos upstream reports limited
  macOS 26 support and known gaps. Exact compatibility with this library is unverified;
  evaluate a pinned version against controlled fixtures before an approved real snapshot.
  No direct database writes and no dependence on this adapter for privacy clearance.
- Google Lens's consumer workflow is not a verified automation integration. Image research
  remains disabled until a supported provider and policy enforcement are implemented.

## Grounding and Limits

- https://github.com/RhetTbull/osxphotos/blob/main/README.rst
- https://developer.apple.com/documentation/vision
- https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting

Chunk 1 delivers capability evidence and fallback decisions, not a completed people-reader
integration. Next chunk: durable versioned analysis queue with synthetic restart tests.
