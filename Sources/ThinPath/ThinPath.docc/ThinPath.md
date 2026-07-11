# ``ThinPath``

A memory-first, native SVG renderer for iOS, macOS, and watchOS, built directly on Core Graphics, Core Text, and ImageIO, with no third-party dependencies.

## Overview

ThinPath parses an SVG document into a flat, arena-based intermediate representation and draws it with a single depth-first walk into a `CGContext`. Every design choice keeps memory proportional to what you actually draw, not to the document's nominal complexity or its embedded assets' native resolution.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:HowItWorks>

### Guides

- <doc:LoadingSVGData>
- <doc:RenderingToAnImage>
- <doc:RenderingIntoAView>

### Performance

- <doc:MemoryModel>
- <doc:ScaleAwareImageDecoding>

### Design and Compatibility

- <doc:HowThinPathDiffers>
- <doc:SupportedFeaturesAndLimits>

### Core API

- ``parse(data:)``
- ``ThinPath``
- ``SVGDocument``
- ``SVGParseError``
