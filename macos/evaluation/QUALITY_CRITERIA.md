# Moments Quality Gate

Structural checks and content quality are separate. Processing state `ready` is not
proof of event identity or a personally meaningful selection.

## Provisional Content Checks

- Represent the distinct visible parts of an outing when suitable photos exist:
  setting, people, activity/details and significant changes of scene. Not every outing
  needs every category; an object collection can be meaningful without people.
- Avoid utility photos as automatic display representatives. Keep them accessible for
  context. User Include and Favorites remain authoritative.
- Avoid redundant representatives when another retained image conveys the same content;
  similarity alone must not erase a different person, activity or meaningful detail.
- Use supported titles and uncertainty, not invented venues, relationships or occasions.
- Preserve all original membership and manual corrections, even when suggestions change.
- Do not hide a Moment merely because it contains one photo. Assess context, content and
  user intent; raw candidate counts do not measure feed clutter or event quality.

These criteria are provisional, not a claim about the user's personal preferences.
Role coverage is necessary evidence, not a sufficient quality score. Review actual
composition, redundancy, covers and full-visit omissions separately.

## Repeatable Sample Audit

`PHOTO_RELAY_QUALITY_REPORT=REPORT_FOLDER swift test --package-path macos/PhotoRelay --filter ExportedReferenceBaselineTests/testOptInReviewedSelectionQuality`

The private report folder supplies `quality-reference.json` with case IDs, named roles
and one-based indices into approved reference samples. Context-only reference indices
are separate. These annotations are evaluation inputs only, never production features.
The test verifies source hashes, rejects held-out samples, runs local Vision/OCR and the
production display selector, then writes `selection-quality.json` with selected indices,
missed roles and context selections. The test reports quality deficits rather than
failing because an unapproved subjective label was missed. Read the report, not only
the XCTest exit code. No model inference, network, Photos changes or live index access.

## September 11 Review

Reviewed the previously approved palace and restaurant contact sheets. Provisional role
coverage passed on the 20-photo palace sample (11 selected) and all 16 restaurant copies
(4 selected). Neither selection included the annotated context-only map/menu photos.
The retained palace photos cover artworks/objects, rooms, a visitor and exterior/grounds;
the restaurant selection covers two people, meal views and the setting. No production
threshold or grouping rule was changed in response.

Limits: the palace sample selection is not the 25-photo selection from the entire visit.
Full-shortlist composition/coverage, live Favorites/categories, user title corrections,
and deployed UI remain acceptance work. February has already been evaluated structurally;
do not call it untouched or use it for tuning followed by claims of independent validation.
