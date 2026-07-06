# Loading SVG Data

Read SVG bytes from a bundle resource, a local file, or a `data:` URI before parsing.

## Overview

`parse(data:)` accepts only `Data`. Obtaining those bytes is your responsibility, which keeps ThinPath's parse and render paths synchronous and free of network I/O. Whatever the source, the final step is the same: hand the raw bytes to `parse(data:)`.

### From the app bundle

```swift
import ThinPath

guard let url = Bundle.main.url(forResource: "icon", withExtension: "svg") else { return }
let svgData = try Data(contentsOf: url)
let (document, errors) = parse(data: svgData)
if !errors.isEmpty {
    print("Parse warnings: \(errors.map(\.message))")
}
```

### From a file URL

`Data(contentsOf:)` reads any local file already on disk.

```swift
let localURL = URL(fileURLWithPath: "/path/to/downloaded/icon.svg")
let svgData = try Data(contentsOf: localURL)
let (document, _) = parse(data: svgData)
```

Fetching bytes from a remote URL is up to you — for example, with `URLSession`.

### From a `data:` URI

For a top-level SVG delivered as a `data:` URI, extract and base64-decode the payload, then parse the raw bytes. This mirrors how ThinPath decodes `<image href="data:...">` elements internally.

```swift
let dataURIString = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0i...=="
guard let comma = dataURIString.firstIndex(of: ","),
      let payload = Data(base64Encoded: String(dataURIString[dataURIString.index(after: comma)...]))
else { return }
let (document, errors) = parse(data: payload)
```
