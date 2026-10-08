# Native Aura Frames client (deferred)

Recorded 2026-10-07. Do not start until a spare Aura frame is available for live
probes. This is a publication side-effect, like Google Photos, not curation.

Unofficial. Aura has no public API. The phone app talks to `api.pushd.com/v5`
plus Cognito, S3, and optionally SQS. Aura can change that without notice. A
Developer ID build you run yourself is a different risk from the Mac App Store.

Protocol notebook, not code to translate: [coredmp95/pushframe](https://github.com/coredmp95/pushframe)
(2026 MIT revival of [zmanowar/auraframes](https://github.com/zmanowar/auraframes),
which has no license). Implement from the protocol with fakes, the same way
Google Photos was done. Do not copy Python.

## Shape in Photo Curator

Reuse the Google Photos three-layer pattern. Destinations are **frames**, not
albums. Feed the same exported originals / Highlights already used for Google.

| Layer | Analog | Job |
| --- | --- | --- |
| Auth | `NativeGoogleOAuth.swift` | Email + password once; store `{email, userID, authToken}` in Keychain; resume without the password |
| HTTP | `NativeGooglePhotosClient.swift` | Login, list frames, paginate assets, `select_asset`, `batch_update`, hide/unhide |
| Sync | `NativeGoogleSync.swift` | Content-hash ledger `(account, digest) → assetID`; pair Story/Moment → named frame; add-only first, hide later |

Do **not** port pushframe’s Google cookie vault, CLI, systemd timers, dump/clone,
people/faces, activities, playlists, Nominatim EXIF rewrite, or rate-limit bucket
(until 429s appear). Photo Curator already talks to Google through the official API.

Login payload mimics the mobile app (`app_identifier`, `identifier_for_vendor`,
`client_device_id`). Keep a stable per-install UUID; do not randomize each launch.
Headers after login: `X-Token-Auth`, `X-User-Id`.

Upload (the only real unknown):

1. `select_asset` with a local GUID
2. Anonymous Cognito `GetId` + `GetCredentialsForIdentity`
3. S3 `PutObject` of original bytes (SigV4 + session token; no boto3)
4. `assets/batch_update.json` with filename, MD5, width, height
5. Optional SQS long-poll — skip until a live probe shows `batch_update`
   acknowledgement is not enough

Sync rule, same as Google: never delete remotely unless the user asked. Pushframe
hides photos that leave the source set. Match that.

## Phases (spare frame required)

| Phase | Prove | Stop if |
| --- | --- | --- |
| 1 | Login + list frames | Auth headers or token resume fail |
| 2 | List assets + content hashes | Pagination or hash identity disagrees with the phone app |
| 3 | Upload **one** JPEG to the spare frame (Cognito → S3 → `batch_update`) | Pools, bucket, or `batch_update` have drifted |
| 4 | Add-only sync of one Moment’s Highlights | Ledger / abort semantics fail |
| 5 | Multi-frame pairing + hide-when-removed | Product, not protocol |

UI: “Connect Aura,” list frames, pick destinations next to the Google review
sheet. Reuse `SyncReview` if it still fits.

Official email-to-frame remains the supported fallback if phase 3 fails.

## Effort

About the same Swift as native Google, plus a small Cognito/SigV4 helper Photo
Curator does not have yet, minus OAuth paperwork. Phase 3 on the spare frame is
the gate; do not build sync or UI beyond “connected / N frames” until that lands.
