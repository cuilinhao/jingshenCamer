# Depth Anything V2 Small FP16

This directory includes the unmodified `DepthAnythingV2SmallF16.mlpackage`
distributed in [Apple's machine learning model gallery](https://developer.apple.com/machine-learning/models/).
The app bundles the model for offline, post-capture relative depth estimation.
No download or third-party runtime SDK is used by the app.

- Original model authors: Lihe Yang et al., [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2).
- Core ML distributor: Apple; [Apple's model card](https://huggingface.co/apple/coreml-depth-anything-v2-small).
- Downloaded 2026-09-22 from [Apple's Small FP16 archive](https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/DepthAnything/DepthAnythingV2SmallF16.mlpackage.zip).
- Archive size: 45,828,566 bytes. Uncompressed package payload: 49,819,122 bytes.
- Archive SHA-256: `8e875979ec82fa46f292468a7567a520b2aa07c41008c32141f3396da05a4067`.
- Per-file SHA-256 checksums: `DepthAnythingV2-SHA256SUMS.txt`.
- Model metadata version: 2.0; release 2024-06; Core ML specification 8.
- License: Apache License 2.0, as stated by the embedded model metadata and Apple's model card.
  The full upstream [license](https://raw.githubusercontent.com/DepthAnything/Depth-Anything-V2/main/LICENSE)
  is preserved in `DepthAnythingV2-LICENSE.txt`. This attribution document is added by TestCamer.
- Only the package was extracted. macOS archive sidecar metadata was excluded; package content and weights were not modified.

## Actual artifact interface

Validated with `xcrun coremlcompiler metadata` and a real `MLModel` prediction.
The fixed tensor dimensions take precedence over imprecise prose in the model card.

| Feature | Name | Format | Size |
| --- | --- | --- | --- |
| Input | `image` | RGB image, Core Video BGRA storage | 518 × 392 |
| Output | `depth` | Grayscale16Half image | 518 × 392 |

Minimum deployment targets reported by the compiler: iOS 17.0 / macOS 14.0.
The compiled MIL ends with a nonnegative predicted disparity divided by its maximum.
Values are relative disparity (larger is nearer), not metric distances. TestCamer
adds a fixed 0.001 offset to preserve zero-valued far samples in its positive-disparity
representation. It does not normalize each output's min/max range or invent depth
variation for a constant plane. Non-finite or negative model values cause explicit failure.

The whole upright image is stretched to the fixed model shape without cropping.
The output is bilinearly resampled back to the original aspect ratio, with a longest
edge of 518 pixels and at most 2% aspect-ratio error. Geometries that cannot meet
that bound are rejected. The app retains full-resolution RGB for rendering.

Xcode's synchronized source group compiles the package into
`DepthAnythingV2SmallF16.mlmodelc` in the app bundle. The estimator loads it lazily
and reuses the loaded `MLModel` instance on its owner's background serial queue.

Run `bash Scripts/verify_monocular_depth.sh` from the repository root to verify
package checksums, conversion, image preprocessing, compilation, and actual Core ML
inference on macOS. This is not an iPhone latency or photographic quality benchmark.
