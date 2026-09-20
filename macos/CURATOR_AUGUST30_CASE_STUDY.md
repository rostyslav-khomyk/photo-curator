# August 30 real-library case study

Tested September 9, 2026. No app redeploy or library edits. Exported using Photos UI,
not private Photos database access. Search selected 39 entries (30 results plus nine
duplicate Top Results). SHA-256 deduplication confirmed 30 unique exported JPEGs.
Copies and private OCR/EXIF output are outside the repository:
`~/Pictures/Photo Relay Analysis/2026-08-30/`.

Ran `swift macos/analyze_exported_photos.swift <export-folder>`: all 30 succeeded.
Vision accurate OCR, face rectangles, image classification; ImageIO metadata;
three contact sheets inspected, plus enlarged inspection of both zero-face results.
The script reads exported copies only and makes no network requests. Exported JPEG
metadata is not an independent guarantee of original camera metadata.

## Evidence

- 30 unique photos; 16 Favorites in the app index.
- Only IMG_5269 has GPS; Photos UI calls the area Woerden-West. Exact coordinates
  remain in the private local analysis JSON, not this document or web queries.
- Other 29 have no GPS in exported EXIF, agreeing with the app-owned index.
- Those 29 span 16:23:26-16:24:24 in stored timestamps but depict multiple venues,
  outfits and occasions. Treat date/chronology as suspect, possibly import-derived;
  do not assert the original capture dates or a single-day itinerary.
- OCR correctly returned `madurodam` for IMG_8796.
- IMG_8822 returned `IATIONALE OPERA & BALLET`, a useful imperfect place clue.
- Other OCR includes clothing/packaging fragments and errors. Do not blindly send
  all recognized text to web search or treat it as event/location evidence.
- Vision found faces in 28/30. IMG_8804 and IMG_8807 returned zero but both visibly
  contain people and visible/profile faces. Neither is cleared for image research.
- No images were uploaded to Google. Public text-only place/documentation searches
  were used; private names and precise GPS were not included.

## Proposed semantic groups

These are human visual interpretations, NOT output currently produced by the local
model. Place names except OCR-supported Madurodam remain suggestions to confirm.

| Files | Count | Suggested group |
| --- | ---: | --- |
| IMG_5269 | 1 | Indoor portrait, Woerden-West (GPS-backed) |
| IMG_8794, IMG_8797, IMG_8799 | 3 | Scheveningen seafront / likely Kurhaus |
| IMG_8795, IMG_8796, IMG_8798 | 3 | Madurodam miniature park |
| IMG_8800 | 1 | Likely Peace Palace, The Hague |
| IMG_8801-8804, IMG_8807 | 5 | Likely De Haar Castle, exterior and interior |
| IMG_8806 | 1 | Canal/city portrait, likely Utrecht; unconfirmed |
| IMG_8808-8814 | 7 | Garden gathering; no inferred identities/relationships |
| IMG_8815 | 1 | Ornate interior group portrait; venue unconfirmed |
| IMG_8816-8823 | 8 | Amsterdam sightseeing / canal boat |

Do not confuse Madurodam miniature buildings with actual visits to those landmarks.
An umbrella title could be `Netherlands visits and gatherings`, with separate
suggested moments beneath it, rather than one date-labelled event.

## Implementation implications

1. Add cached local OCR as evidence, preserving source asset, confidence and raw
   text separately from normalized place candidates. Brand/shirt text is not a venue.
2. Reduce trust in compressed timestamps when scene/place evidence conflicts.
   Offer split/merge review rather than silently rewriting dates or Photos metadata.
3. Rank distinctive evidence above generic `people/adult/outdoor` labels. The current
   template-candidate LLM cannot infer these groups from generic classification alone.
4. PhotoKit PHAsset.location exposes optional coordinates, not guaranteed Photos UI
   place names. Use public MapKit reverse geocoding when allowed, cached and disclosed
   as a network lookup. Never propagate the midday GPS across this mixed set.
5. Privacy gate must fail closed. Zero detected faces is not clearance; consider
   conservative person detection in addition, with any uncertainty preventing upload.
   For THIS set, recommend no image-search uploads at all. Text research is sufficient
   for several meaningful names already.
6. This is an exported-copy research tool, not a production feature or regression test
   of the app's classifier. Photos GUI export does not enforce a local-only resource
   request; future in-app export probes should use PhotoKit networkAccessAllowed=false.

## Primary sources consulted

- https://developer.apple.com/documentation/photos/phasset/location
- https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest
- https://www.madurodam.nl/en/practical-information/address-and-route
- https://www.amrathkurhaus.com/en/
- https://www.kasteeldehaar.nl/het-kasteel/
- https://www.vredespaleis.nl/?lang=en
- https://www.operaballet.nl/en/your-visit/visitor-information
- https://docs.cloud.google.com/vision/docs/internet-detection

Google Cloud Vision Web Detection is a potential supported API for future last-resort
research; it is not the Google Photos upload API or an assumed consumer Lens API.
