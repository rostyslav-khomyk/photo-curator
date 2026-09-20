# Similarity Calibration (2026-09-07)

## Public Category Follow-up

PhotoKit category support verified against PhotosTypes.h in installed Xcode and Apple's
PHAssetCollectionSubtype and PHAssetMediaSubtype documentation:
https://developer.apple.com/documentation/photos/phassetcollectionsubtype
https://developer.apple.com/documentation/photos/phassetmediasubtype/photoscreenshot
Documents, Receipts and Handwriting have no matching public enum in this SDK. Revisit on
SDK updates, without inferring availability from Photos UI or using private schema access.
The implemented category priority and preview behavior are recorded in the development log.

## Grounding

- Apple computeDistance: smaller feature-print distance means greater similarity,
  not a percentage or calibrated probability of duplication.
  https://developer.apple.com/documentation/vision/vnfeatureprintobservation/computedistance(_:to:)
- Apple's sample and WWDC explain feature-based image retrieval, not exact byte matching.
  Resemblance alone cannot establish an interchangeable memory or facial expression.
  https://developer.apple.com/documentation/vision/analyzing-image-similarity-with-feature-print
  https://developer.apple.com/videos/play/wwdc2019/222/
- Apple HIG recommends live slider feedback.
  https://developer.apple.com/design/human-interface-guidelines/sliders
- Threshold evaluation trades precision against recall. Our priority is avoiding false
  suppression of meaningful photos, not maximizing suppression counts.
  https://scikit-learn.org/stable/auto_examples/model_selection/plot_precision_recall.html

## Decisions

Keep native computeDistance, pinned print revision 1 and scaleFit preprocessing. Do not
assume a universal range, convert to percentages, substitute a cosine formula, or transfer
thresholds between model versions. Persist under full analyzer version. The 0.01 default
is uncalibrated, NOT an Apple recommendation.

Dialog uses up to 512 deterministically sampled adjacent pairs within moments and within
60 seconds, distributed across the period. Current-version cached results only. Show the
nearest pair below/equal to cutoff and nearest above it. Empty sides are explicit.
Slider maximum is max(1, observed sample maximum, saved cutoff): a UI range, not a claimed
mathematical maximum. Thumbnails use local-only PhotoKit. Apply updates suggestions
globally; Cancel leaves them alone. Favorites remain protected. Pair classification is
explicitly distinct from final greedy representative selection. Selection now compares
the nearest 32 retained temporal neighbors, not the last 32 in aesthetic ranking.

## Remaining Validation

Calibration aid, not validated duplicate detection. Adjacent sampling misses nonadjacent
repeats and cannot measure quality alone. No precision/recall claims yet. Next: durable
user judgments and thumbnail include/exclude review; labeled pairs from multiple trips,
bursts, portraits, crops and lighting changes, with a held-out set. Keep pair precision
separate from selection quality/story diversity. Inspect false positives before raising
the default. Manual decisions should outlive automatic recommendations. Photos writes LAST.
