# A²gent branding

## Decisions

- The user identified `https://a2gent.net/a2gent.jpg` as the official mark and clarified that it may not be SVG. `a2gent.jpg` is copied unchanged from `square/frontend/public/a2gent.jpg` (1024 × 1024); no vector source was found.
- App icons are resized from that original. `status-icon.png` is a monochrome alpha-mask derivative for AppKit template rendering in light/dark menu bars. Previous Medusa artwork is removed.
- The settings window opens directly from the status item, with no dropdown. It is nonmodal, resizable, and retains drafts while open. Save validates the whole draft before applying anything; Cancel/close discards unsaved edits.

Regenerate icon sizes and the template mask with `python3 scripts/generate-brand-icons.py` (Pillow required).

## Sphere

`caesar-sphere.js` is an offline Three.js bundle using the geometry, camera, and GLSL shaders from `caesar/src/components/common/AgentAvatar.tsx`. Its native WebKit wrapper switches idle/listening/speaking modes, stops animation while occluded, and respects Reduce Motion. Native macOS controls remain outside WebKit. No backend, CDN, or web server is needed to display it.

Regenerate from the sibling Caesar checkout after installing Caesar's npm dependencies:

```sh
node scripts/sync-caesar-sphere.mjs
```

The small platform-specific animation host is maintained in `scripts/caesar-sphere-runtime.js`. Shader constants are extracted rather than manually reimplemented. Pointer parallax and the web-only CSS indicator ring are intentionally omitted. Three.js is distributed under the adjacent `THREE-LICENSE.txt`. Simplex-noise GLSL originates from Ashima Arts / stegu, as documented in Caesar.

Resources are copied as a `Brand` directory by both SwiftPM and Xcode. Keep the directory structure intact when packaging.
