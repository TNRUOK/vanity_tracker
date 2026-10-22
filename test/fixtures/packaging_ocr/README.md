# Packaging OCR test corpus

Twelve **synthetic** packaging labels (`*.png`) rendered on an HTML canvas, so the ground truth
is exact and the images can be shared freely (no product photos, no personal data).
`corpus.json` holds for each image:

| field | meaning |
|---|---|
| `truth` | the text that was drawn |
| `ocr.original` | real Tesseract.js 6.0.1 output for the image as captured (recorded 2026-10-19 in headless Microsoft Edge 155, the app's own `web/tesseract` build, PSM 6) |
| `ocr.enhanced_js` | output for the enhanced pass (grayscale + 1 % contrast stretch + upscale to 1600 px) |
| `expected` | what the app should fill in after both passes are parsed |
| `known_limitation` | why an expected value is empty although the truth contains it |

Difficult cases: 13 px text, low contrast, 6° tilt, blur, dot-matrix inkjet, embossed silver,
a retail barcode next to the batch code, labels on their own line, PAO (12M) and size (50ml)
decoys, ambiguous day/month dates, and marketing text with no codes.

Measured with the same images (headless Edge):

| case | as captured | enhanced |
|---|---|---|
| rotated_6deg | date misread `2027.03.34` | `2027-03-31` (correct) |
| embossed_silver | labels lost | `B.N 0 K42` / `EXP 09/2028` |
| dot_matrix | no text | no text |
| others | correct | correct |

Blur and binarization were also measured and rejected (blur turned `4021A` into `S021A`).
Page-segmentation mode 11 (sparse text) gave no improvement over mode 6.

## Real app in a browser (2026-10-19)

The built web app was driven in headless Chrome: Add Product → "Scan Packaging / Batch Code
OCR" → real file chooser → both OCR passes (Tesseract.js + the app's Dart preprocessing) →
Confirm & Apply, with Firestore traffic blocked. About 3–4 s per image.

| case | filled automatically | offered for the user to choose |
|---|---|---|
| clean_labels | A7K29, 2024-10-17, Oct 2027 (month only) | – |
| small_text, low_contrast, blurred, pao_size_decoys, barcode_and_batch | batch + expiry | – |
| label_on_own_line | Feb 2025 / Feb 2028 (month only) | – |
| rotated_6deg | expiry 2027-03-31 (batch line unreadable) | – |
| embossed_silver | K42 (after B.NO), Sep 2028 (month only) | – |
| ambiguous_dates | nothing | both readings of each date |
| dot_matrix | nothing ("No text was found") | – |
| marketing_only | nothing | – |

This run found a web-only bug the unit tests could not: `ui.ImageDescriptor` is not
implemented in Flutter web, so the enhanced pass silently failed there. It now uses
`instantiateImageCodec` / `decodeImageFromPixels`, and a failed pass is reported in the status.

Not covered: real camera photos (glare, curved tubes, reflective foil). Android ML Kit was not
run on this corpus (no device available).
