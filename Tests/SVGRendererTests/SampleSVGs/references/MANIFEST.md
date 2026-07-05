# references/ — required golden PNGs

This directory is intentionally **empty of images** right now. It must contain
exactly the PNG files below before the GOLDEN-tier cases in `RenderTests.swift`
can pass. See `GoldenWorkflow.md` for how to produce them.

Each row gives: the filename this test suite loads (via
`SnapshotSupport.loadReferencePNG`), the source `.svg`, and the **exact pixel
size** the PNG must be (no scale factor — all golden cases render at scale 1).

| Reference PNG filename            | Source SVG                                          | Pixel size |
|------------------------------------|------------------------------------------------------|------------|
| `linear_gradient_basic.png`        | `gradients/linear_gradient_basic.svg`                 | 120 x 80   |
| `radial_gradient_basic.png`        | `gradients/radial_gradient_basic.svg`                 | 100 x 100  |
| `gradient_object_bounding_box.png` | `gradients/gradient_object_bounding_box.svg`           | 140 x 100  |
| `gradient_user_space_on_use.png`   | `gradients/gradient_user_space_on_use.svg`             | 140 x 100  |
| `gradient_spread_reflect.png`      | `gradients/gradient_spread_reflect.svg`                | 120 x 60   |
| `pattern_basic_tiling.png`         | `patterns/pattern_basic_tiling.svg`                    | 100 x 100  |
| `pattern_object_bounding_box.png`  | `patterns/pattern_object_bounding_box.svg`              | 160 x 100  |
| `mask_luminance_basic.png`         | `mask/mask_luminance_basic.svg`                        | 100 x 100  |
| `mask_nested.png`                  | `mask/mask_nested.svg`                                 | 100 x 100  |
| `clip_path_complex.png`            | `clip/clip_path_complex.svg`                           | 120 x 120  |
| `text_basic.png`                   | `text/text_basic.svg`                                  | 200 x 60   |
| `image_embedded_basic.png`         | `images/image_embedded_basic.svg`                      | 80 x 80    |
| `image_preserve_aspect_ratio.png`  | `images/image_preserve_aspect_ratio.svg`               | 80 x 80    |

13 files total. `memory-stress/*.svg` documents are **not** in this list — they
are for later profiling, not golden comparison (see their own header comments).

Filenames have no extension when passed to `SnapshotSupport.loadReferencePNG`;
the `.png` above is the actual file extension on disk.
