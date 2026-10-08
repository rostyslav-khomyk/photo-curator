# Photo Curator working guide

Photo Curator is a native macOS app. Its central product is explainable family
photo curation: Story -> Moment -> Highlight. Preserve user decisions and distinguish
algorithm improvements from UI exposure of existing results.

## Read before changing curation

- [Living algorithm map](Docs/CURATION_ALGORITHM.md): current flow, production
  entry points, implementation status, limitations and UI dependencies.
- [Resume checkpoint](Docs/PROJECT_STATE.md): recorded state and next work.
- Phase documents supply design history; verify their claims against callers.

Update the living map in the same change when altering algorithm behavior,
thresholds, integration or status. Keep Mermaid diagrams consistent with production
calls. Tested helpers are not shipping features until connected. UI-only work
updates the UI dependency table when needed, not the algorithm's claimed status.

## Safety and verification

- Preserve existing worktree changes. Do not reset the library or modify Photos
  albums to test documentation or algorithm changes.
- Use isolated copies or synthetic fixtures for catalog evaluation. External
  publication, destructive reset and user decisions require their explicit flows.
- Keep SQLite transactions synchronous; gather asynchronous evidence beforehand.
- Keep costly analysis off the main actor and use bounded work and revision checks.
- Run relevant Swift tests for behavioral changes (`swift test --filter NAME`).
  Full qualification uses `./Scripts/qualify_alpha.sh preflight`; builds use
  `./Scripts/build_app.sh`. Documentation-only changes require link and diagram
  checks, not a new app build.
- Prefer existing components and native APIs. Add agent roles, hooks or dependencies
  only to address a demonstrated need.
- Overnight / clean-room soak monitoring: [Docs/SOAK_AGENT.md](Docs/SOAK_AGENT.md)
  (local loop + telemetry watch + Photos full-access clicker; fix log in
  [Docs/SOAK_FIX_LOG.md](Docs/SOAK_FIX_LOG.md)).

## Cursor Cloud specific instructions

Cloud Agent machines are Linux. The app targets macOS 13 and uses AppKit, SwiftUI, PhotoKit, and codesign, so `swift test`, `./Scripts/build_app.sh`, and `./Scripts/qualify_alpha.sh` are macOS commands.

ExifTool is installed from `libimage-exiftool-perl`. Node is already on the image. Verify the portable export audit with:

```bash
node --test Tools/Evaluation/audit-export.test.mjs
node Tools/Evaluation/audit-export.mjs EXPORT_FOLDER NEW_REPORT_FOLDER
```

The audit reads copied media in an export folder and writes a new report directory outside that folder. It does not open the Photos library. Use a synthetic or isolated export for checks.
