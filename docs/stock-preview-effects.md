# Stock-preview effects: grain scale and halation

The stock selector shows a bundled Apple Log 2 plate with the selected stock's own look applied
at display time. White balance, halation, the stock LUT and grain run in that order. Halation
reuses the production stage; grain uses a smaller preview approximation. The preview does not
include the renderer's glow, contrast adjustment or complete grain model.

```
plate (Apple Log 2)
  -> plate_prepare        decode to linear light, apply the stock's locked white balance,
                          re-encode to Apple Log 2
  -> SpatialEffectsStage  the production halation kernels, on that locked frame, with the
                          stock's own strength / radius fraction / layer tints
  -> stock .cube          red-fastest trilinear, clamp-to-edge (identical to a live frame)
  -> grain                the shipped 128^3 volume, sized in the REFERENCE frame's pixels
  -> 8-bit BGRA drawable
```

White balance runs first because the camera locks white balance in hardware before the renderer
ever sees a frame: the halo must scatter the light the lock actually produced. There is no
preview-only halo shader -- `spatial_halation_mask` and `spatial_halation_apply` are the same
kernels `PipelineRenderer` dispatches.

## Grain scale

`grain.metal`'s `pass2_grain` samples the volume at `gid / (128 * footprint)`, so one grain cell
spans `footprint` pixels of the render frame. The reference frame is the 4K delivery render
(long edge 3840), and the preview samples the volume in that frame's pixel space:

```
referenceScale  = referenceLongEdge / max(drawableWidth, drawableHeight)
referencePixel  = fragmentPixel * referenceScale
address         = referencePixel / (128 * footprint)
```

A cell is therefore `footprint * drawableLongEdge / 3840` drawable pixels: the same size
*relative to the picture* at any resolution. The previous implementation divided normalised uv
by the footprint, which tied a cell to the volume's own 128-texel repeat instead of the frame --
`3840 / 128 = 30x` too large at 4K, and it did not shrink with the drawable.

### Subpixel damping

When a cell is smaller than one drawable pixel it cannot be resolved. The preview scales its
amplitude by `saturate(cellDrawablePixels)` to reduce visible noise at that size. This is an
approximation, not an exact filtered reduction of the production grain field.

## Gauge presence

The gauge owns both grain axes. Size comes from `GrainModel.effectiveSize`, and presence now
comes from `GrainModel.amount` rather than the quieter preview-only constant. The same
luminance window as the renderer suppresses grain in deep shadows and bright highlights.
The preview still uses a simplified noise field and reduced-image damping; matching the amount
constant does not make it an exact filtered copy of exported grain.

### Detail view

The card starts with the full photograph. Its **Detail** button shows a 3× centre crop and
changes to **Full photo** to return. The photograph, halation and grain enlarge together;
stock strength, radius, selected scene and gauge do not change. The control sits above the
caption and has a minimum 44-point height. Halation remains subtle at full-photo size, so the
detail view provides inspection without increasing exported strength or diffusion radius.

## Halation amount

`halationStrength` is the stock's total amount, used unchanged. The catalogs carry
`3.60 -> 2.52` (70%), which is an authoring change only: neither the preview nor the renderer
multiplies by 0.7, so it cannot be reduced twice. The radius fraction (0.001) and the layer
tints are untouched by that reduction.

## Tests

`Tests/PlatePreviewEffectsTests.swift` drives the shipping `PlatePreviewPipeline` on real Metal
textures and measures pixels:

- the CPU uniform mirror matches the shader structs (stride and every offset, including the
  `referenceLongEdge` field that rescales the grain);
- reducing the drawable reduces the grain cell's pixel size while preserving its size relative
  to the picture;
- a subpixel cell is damped well below a resolved one while staying present;
- presence falls across the gauge ladder, 8mm loudest and 75mm nearly silent;
- the corrected reference resolves far finer grain than the legacy 128-pixel one;
- halation adds warm, local energy outside a bright block and does not touch input below the
  per-layer knees;
- the configuration carries the stock's reduced halation total amount without reducing it again;
- a real bundled scene renders at 8-bit and writes the before/after comparison sheet plus its
  panels as PNG diagnostics (`before-grain`, `after-grain`, `before-grain-halation`,
  `after-grain-halation`, `after-stock-halation`, `preview-before-after`).

`Tests/PlatePreviewColourTests.swift` covers the colour step, and
`Tests/RenderContractTests.swift` covers the shipped catalog reduction.

These are regression checks on the preview and the catalogs, not a colorimetric or photographic
calibration of the camera, the plates or the display.
