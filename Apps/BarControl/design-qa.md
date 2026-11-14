# Bar Control Compact Power Flow Design QA

## Evidence

- Source visual truth: `<本机参考图，未随仓库分发>`.
- Source pixels: 1290 x 563.
- Canonical expanded vector source retained for the measured-device state: `~/Downloads/power_flow_ui_figma_precise.svg` (1290 x 681).
- Rendered compact implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-compact-menu-material-light.png`.
- Implementation pixels: 780 x 341 at 2x density; logical AppKit size 390 x 170.21 points.
- Normalized same-state comparison: `~/Library/Logs/BarControl-compact-reference-vs-appkit.png`; the AppKit render was scaled to 1290 x 563 and placed beside the source.
- Live telemetry implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-live-menu-material.png`.
- Expanded measured-device regression render: `~/Library/Logs/CodexTouchBarNative-power-flow-menu-material-light.png`.
- State: light appearance, adapter connected, no measured external USB power outputs. QA fixture uses the source values 67 W, 41.21 W, and 25.59 W; live evidence uses the Mac's current 20 W, 0.12 W, and 12.57 W telemetry.

## Findings

- No actionable P0, P1, or P2 mismatch remains after normalization.
- Fonts and typography: compact branch values use two decimal places, rounded system typography, bold branch hierarchy, and the source card removes the unit gap (`67W`) to match the reference. Baselines and centers align with the visual target.
- Spacing and layout rhythm: the no-output state is 1290 x 563, with the source at x=45...208, flows at x=225...1078, and battery/laptop cards at x=1094...1259. The absent fan-out, hub, and endpoint cards consume no space. The view height contracts from 206 to 170.21 AppKit points.
- Colors and visual tokens: light mode uses translucent white glass, pale green upper tint, pale blue lower tint, a restrained gray rim, and soft gray elevation. The view itself remains transparent; the gray comparison material is only a preview backdrop.
- Image and asset fidelity: paths and icons stay vector/AppKit-native. The expanded state keeps the existing precise SVG geometry, while the compact state follows the supplied 1290 x 563 source silhouette.
- Copy and content: source and branch values are telemetry-driven. Missing output devices do not produce placeholders or `-- W` labels.
- P3 only: the photographed reference contains camera blur and a nonuniform real-world backdrop; the native render is slightly sharper. This is expected and avoids baking raster blur into the UI.

## Focused Region Review

- A separate crop was not required: after normalization, all three value labels, the split notch, four card edges, and all three icons remain clearly readable in the full-width 2580 x 563 comparison.

## Comparison History

1. P1 — the no-output state still showed placeholder iPad/display/more endpoints and kept the 1290 x 681 expanded width. Fix: removed placeholder outputs, made visibility depend only on measured wattage, and added the 1290 x 563 compact layout with dynamic view height.
2. P2 — the first light render was too flat and nearly pure white on a light material. Fix: strengthened green/blue flow tints, reduced the flow sheen, and increased the soft gray shadow while preserving transparency.
3. P2 — branch values were rounded to one decimal (`41.2 W`, `25.6 W`) while the source uses two. Fix: compact branches now render exactly two decimals.
4. Post-fix evidence: `~/Library/Logs/BarControl-compact-reference-vs-appkit.png` shows matching structure, proportions, state, and copy with only expected photographic blur remaining.

## Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed; light/dark compact and expanded renders generated.
- `--smoke-test`: passed; device-count assertions and live telemetry render completed.
- Hidden-output behavior: passed (`previewBatteryDischarging` and `previewWithoutOutputs` both display zero external devices).
- Live no-output view: passed at 780 x 341 pixels; no right-side external-device layer is present.
- Installation: Bar Control 0.16.0 (35) installed at `/Applications/Bar Control.app`; signature verification and distribution/installed executable hash comparison passed.
- Installed-binary live render: passed at 780 x 341 pixels, then the normal installed app was relaunched and remained running.

## Expanded fan-out revision awaiting visual acceptance

- Source visual truth: `~/Downloads/IMG_4650.jpg`.
- The first-level upper/lower flows now share one shadow and one outer rim. Their common origin segment is fill-only, so no horizontal splice line is drawn before the V split.
- The former separately rimmed `hub` card is no longer rendered. The second-to-third-level fan uses one open shared root whose right side fades into the branch bodies.
- Branch start and end widths are recomputed from both the current sibling count and relative wattage; the combined root height is capped at the 116 px outlet edge.
- Actual AppKit evidence:
  - one device: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png`
  - two devices: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-two-light.png`
  - three devices: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png`
- `swift build -c release`: passed after the revision.
- `--flow-animation-preview`: passed and regenerated all three count states.
- `--smoke-test`: passed, including ordering, total-height, count-response, and hidden-output assertions.
- Figma MCP inspection was attempted first but the authenticated Starter plan returned its official `MCP tool call limit` response; no Figma changes were made.
- Installation: intentionally pending user approval of the actual AppKit renders above.

earlier status: implementation validated; visual acceptance and installation pending

## Three-level dynamic hierarchy revision

- Source visual truth: `~/Downloads/IMG_4665.jpg`.
- Level 1 is the input/source card. Level 2 contains battery and whole-machine branches. Level 3 is created only from the whole-machine card and contains measured external devices.
- Level-2 card heights are allocated from battery/system wattage with readable minimums; their battery/laptop icon sizes follow card height.
- Level-3 ribbon root widths, endpoint widths, endpoint card heights, label sizes, and device icon sizes all respond to sibling count plus relative wattage.
- High-contrast fixture: input 89 W, battery 3.47 W, system 84.0 W, outputs 58.6 / 3.90 / 26.7 W.
- Actual AppKit evidence:
  - light: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png`
  - dark: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-dark.png`
  - one-device regression: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png`
  - two-device regression: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-two-light.png`
- Small endpoint icons keep a 28 px design-space readability floor and level-2
  icons keep a 32 px floor, while both remain capped to avoid crowding.
- `swift build -c release`, `--flow-animation-preview`, and `--smoke-test`: passed after the revision.
- Figma MCP inspection was attempted again because the Figma plugin was explicitly selected; the Starter account still returned the official MCP rate-limit response, so no Figma file was mutated.
- Installation remains intentionally pending visual approval.

## Dynamic animation wash coverage

- Cause: the moving color wash was capped at 58 design points even after dynamic hierarchy ribbons could exceed 200 points in cross-section.
- Fix: sweep width now responds to both path length and the live ribbon's maximum start/end cross-section; third-level sweeps begin at the shared root's left edge instead of after the root.
- High-contrast animated evidence: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-animation-00.png` through `-07.png`.
- Verified: the moving wash spans the complete vertical cross-section of the 58.6 W, 26.7 W, 3.90 W, 84.0 W, and 3.47 W ribbons at each sampled position.
- `swift build -c release`, `--flow-animation-preview`, `--smoke-test`, and `git diff --check`: passed.
- Follow-up gap fix: the former single transparent-ended wash was replaced by a
  full-path source-to-destination tint plus four overlapping wrapped bands.
  Bands keep tinted endpoints and a tinted center, so neither loop boundaries
  nor white highlights create apparent blank animation slots.

## Lunacy-backed splice and hierarchy review

- Editable QA source:
  `Design/Lunacy/BarControl-PowerFlow-Dynamic-QA-0.16.0.free`.
- The file preserves the grouped expanded vectors. The source image was opened
  as an independent Lunacy layer for source/card/ribbon measurement; the Mac
  locked before that overlay could be saved back to the `.free` file, so the
  saved workspace remains the editable baseline and the program renders below
  remain the actual acceptance evidence.
- Main level-2 branches and level-3 output branches omit sibling-facing rims
  completely. The transparent gap itself separates branches after the split;
  no doubled gray border is drawn along either side of that gap.
- Sibling ribbons use one neutral compound glass fill and one shared vertical
  sheen. Per-branch shadows and per-branch sheens were the remaining source of
  visible alpha seams even after the inner stroke prefix was removed.
- No third-level hub card is drawn. Output ribbons begin directly at the
  whole-machine card edge, and missing siblings are removed before widths,
  card heights, and packed positions are calculated.
- A hierarchy level with one visible child no longer applies a wattage ratio:
  that child owns the complete parent-card outlet and its destination card is
  matched to the same available height. With two or three visible siblings,
  start/end widths and card packing return to relative-wattage allocation.
- A sole third-level child also has a 176 design-point visual-height floor
  (capped at 220), applied to both its ribbon and destination card. This keeps
  a single external device prominent instead of rendering it as a thin slot.
- Single-device ribbon attachments are asymmetric by design: the left edge is
  `systemCard.height - 6`, while the right edge is
  `endpointCard.height - 6`. The ribbon therefore matches both connected
  modules instead of forcing the small parent and larger destination to share
  one arbitrary thickness.
- A sole endpoint icon uses a separate 88...116 design-point scale and remains
  centered on both axes. Multi-device icons retain their compact scale.
- With one third-level child, the entire far-right destination card is centered
  on the expanded canvas vertical axis instead of inheriting the lower
  whole-machine card center. The main-style ribbon curves from the machine
  outlet to that centered destination.
- A sole third-level ribbon uses the same stronger yellow-to-blue liquid-glass
  gradient, broad Bezier control profile, and rim treatment as the main
  first-to-second-level flow. Multi-device fan-out branches retain their
  lighter compact style.
- Latest actual program evidence:
  - dynamic light:
    `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png`
  - dynamic dark:
    `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-dark.png`
  - compact light:
    `~/Library/Logs/CodexTouchBarNative-power-flow-compact-menu-material-light.png`
  - animation phases:
    `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-animation-00.png`
    through `-07.png`
- `swift build -c release`, `--flow-animation-preview`, `--smoke-test`, and
  `git diff --check`: passed after the selective-rim revision.
- Installation: intentionally not performed. `/Applications/Bar Control.app`
  remains the rollback 0.16.0 (35) build pending user approval of the actual
  program renders.

## Installed dynamic hierarchy build

- Version: Bar Control 0.16.1 (36).
- Installed at `/Applications/Bar Control.app` and relaunched successfully.
- `codesign --verify --deep --strict`: passed; the bundle is valid on disk and satisfies its designated requirement.
- Signed distribution and installed executable SHA-256 match: `7e3f7f61aa7945b4029e8eac3c1828499f3570d84c14bd091bc8f664c6f48b34`.
- Running process path: `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`.

## Rollback to the previous accepted build

- Rolled the live renderer back from the dynamic 0.16.1 hierarchy to the previous fixed expanded/compact rendering path.
- Restored the fixed square junction, fixed three-output fan-out, separate compact upper/lower ribbons, and the original single localized animation sweep.
- Regenerated and visually checked the expanded and compact light previews before installation.
- Installed Bar Control 0.16.0 (35) at `/Applications/Bar Control.app` and relaunched it successfully.
- `codesign --verify --deep --strict`: passed.
- Signed distribution and installed executable SHA-256 match: `24618726be0a915e1e5513b9095b0ae85c181e43b8a702fe67e75fa88931e36a`.
- Running process path: `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`.

## Installed visually accepted dynamic build

- Version: Bar Control 0.16.2 (37).
- Installed and relaunched at `/Applications/Bar Control.app` after the user
  approved the actual single-device centered render.
- Previous installed 0.16.0 (35) bundle retained at
  `backups/Bar Control-0.16.0-35-before-0.16.2.app`.
- `codesign --verify --deep --strict`: passed; installed bundle is valid and
  satisfies its designated requirement.
- Distribution and installed executable SHA-256 match:
  `39b073e0666ffe7de390aee92edc62d317f68e9b53880dbef3a35c0439e4ca8a`.
- Installed-binary `--flow-animation-preview`: passed; the approved
  single-device render was regenerated at
  `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png`.
- Running process path:
  `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`.

## Battery floor and softened attachment revision

### Evidence

- Geometry reference: `~/Downloads/IMG_4665.jpg` (782 x 416 pixels).
- White liquid-glass reference: `<本机参考图，未随仓库分发>` (1290 x 563 pixels).
- Dynamic implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Zero-battery implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-battery-idle-menu-material-light.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Single-output implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Full-view comparisons opened the relevant source and all implementation captures together. The dynamic geometry source and implementation differ by only 2 pixels in width and 4 pixels in height, so no additional density normalization was necessary for geometry review. The white-material source is a compact two-branch state and was used only for material, radius, and elevation review.
- State: light appearance. The dynamic fixture is 89 W input, 3.47 W battery, 84.0 W system, and 58.6 / 3.90 / 26.7 W outputs. The zero-battery fixture is 85 W input, 0 W battery, 23.7 W system, and three outputs.

### Findings

- No actionable P0, P1, or P2 difference remains for the requested revision.
- Fonts and typography: values retain the established rounded system type, weight hierarchy, and readable placement; the wider 3.47 W battery destination no longer crowds its label.
- Spacing and layout rhythm: a nonzero low-power battery now has a 96 design-pixel card floor. A 0 W battery removes its entire branch, and the remaining system branch expands to match both the source-card outlet and second-level card edge. First-to-second-level ribbons now size their destination edge independently instead of being capped by the source width.
- Colors and visual tokens: the existing translucent white fill and pale yellow/green/blue tints remain unchanged. Second-to-third-level elevation is added only to the selective outside rim, avoiding a new shadow seam between sibling ribbons.
- Image and asset fidelity: symbols remain native vector assets and are not rasterized. Output destination caps use a 22 design-pixel radius; the single-output source also receives a rounded cap, removing the square-ended appearance without changing the multi-output shared root.
- Copy and content: 0 W does not leave a battery card, icon, label, or empty placeholder. Nonzero low power remains visible and reports the live value.
- Focused region review was not required: at 780 x 412, the battery minimum card, both main attachment edges, the three output caps, and the single-output rounded source are all clearly legible in the full capture.
- P3 only: the photographed references include optical blur and uneven physical-display lighting, while the AppKit capture is sharper. That difference is expected and should not be simulated in code.

### Comparison history

1. P2 — a 3.47 W battery inherited the former 56-pixel card floor and looked accidental. Fix: increased the nonzero battery floor to 96 pixels while making 0 W suppress the branch completely.
2. P2 — first-to-second-level destination attachments were clamped by their source slots and could not match the connected card. Fix: each destination width is now `card height - 6`, independent of its source share.
3. P2 — second-to-third-level ends looked angular and flat. Fix: increased output destination cap radius to 22 pixels, rounded the source cap for the sole-output case, and added a soft shadow only to the outside selective outline.
4. Post-fix evidence: the dynamic, zero-battery, and single-output implementation captures listed above were opened together with the source visuals and show the corrected states.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all acceptance captures.
- `--smoke-test`: passed, including the 96-pixel battery floor, 0 W hidden branch, and nonzero discharging branch assertions.
- `git diff --check`: passed.
- Installation was intentionally not performed. The accepted Bar Control 0.16.2 (37) installation remains unchanged until the user approves these actual program renders.

## AlDente-inspired flow direction, proportional sizing, and animation revision

### Evidence

- Source visual truth: `~/Downloads/IMG_4665.jpg` (782 x 416 pixels).
- Official behavior references: `https://apphousekitchen.com/aldente-overview/features/` and `https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/releases`.
- Underpowered implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Low-positive-battery implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-compact-low-battery-menu-material-light.png` (780 x 341 pixels; 390 x 170.5 AppKit points at 2x).
- Underpowered animation loop: `~/Library/Logs/CodexTouchBarNative-power-flow-underpowered-hierarchy-animation.gif` (780 x 412 pixels).
- Low-positive-battery animation loop: `~/Library/Logs/CodexTouchBarNative-power-flow-compact-low-battery-animation.gif` (780 x 341 pixels).
- Full-view comparison opened the source, revised underpowered state, revised low-battery state, and an animated phase in one comparison input. Source and underpowered implementation differ by only 2 pixels in width and 4 pixels in height, so geometry review required no density normalization.
- State A: weak adapter plus battery supplementation, 3.47 W battery + 84.00 W adapter feeding an 89.0 W computer, then 58.6 / 3.90 / 26.7 W outputs.
- State B: charging, 89 W input splitting into 3.47 W battery and 84.00 W computer consumption.

### Findings

- No actionable P0, P1, or P2 difference remains for this revision.
- Fonts and typography: the rounded system-value hierarchy remains consistent; the small 3.47 W label is readable without forcing the battery card or ribbon to the computer branch size.
- Spacing and layout rhythm: battery and computer branches share a fixed height budget allocated from their actual wattage with a readable nonzero floor. In the 3.47 W / 84 W fixture, the linked design heights are 72 / 322 pixels. Each destination card uses the same allocation as its ribbon edge.
- Colors and visual tokens: static liquid-glass tint remains visible at all times. A single broad asymmetric tide moves continuously left-to-right over the base tint, replacing the former repeating bright bands and removing apparent blank intervals.
- Image and asset fidelity: device symbols remain native vector symbols. No bitmap placeholder, handcrafted SVG, or text glyph replaces a visible device asset.
- Copy and content: all displayed watt values reflect the fixture values and keep the semantic hierarchy intact.
- Direction and topology: a positive battery value is a charger-to-battery destination branch. A negative battery value becomes a separate left-side source that merges with the charger into the computer. There is no battery-to-charger path.
- Focused region evidence was not required because the 780-pixel captures clearly show the complete battery card, both attachment edges, labels, and all output cards. Animation phases 00 / 05 / 10 / 15 were additionally opened together and show the broad tide progressing from the source side to the destination side.
- P3 only: the broad tide follows AlDente's documented continuous left-to-right Sankey behavior, but does not attempt to copy proprietary easing or rendering internals.

### Comparison history

1. P1 - discharging battery was previously represented inside a charger-origin split, allowing the visual to imply battery-to-charger flow. Fix: added a dedicated underpowered topology with battery and charger as left-side inputs merging into the computer. Post-fix evidence is the revised underpowered implementation and GIF listed above.
2. P2 - compact battery and computer branches previously inherited fixed template sizes, so 3.47 W could look too large relative to 84 W. Fix: replaced the template with actual-watt allocation plus a readable nonzero floor; card and ribbon heights now use the same allocation. Post-fix evidence is the compact low-positive-battery capture.
3. P2 - four repeated bright animation bands produced flashing, busy motion. Fix: replaced them with one broad wrapped color tide over a stable base tint, slowed to 3.6 seconds, always traveling source-to-destination. Post-fix evidence is the two GIFs and the four-phase comparison.

### Validation

- `swift build -c release`: passed after the revision.
- `--flow-animation-preview`: passed and generated both GIF loops plus frame sequences.
- `--smoke-test`: passed, including linked-height and battery-direction assertions.
- `git diff --check`: passed.
- Installation was intentionally not performed. `/Applications/Bar Control.app` remains the accepted Bar Control 0.16.2 (37) build and is still running.

## Installed AlDente-inspired flow revision

- Installed version: Bar Control 0.16.3 (38).
- Rollback copy: `backups/Bar Control-0.16.2-37-before-0.16.3.app`.
- `codesign --verify --deep --strict`: passed.
- Distribution and installed executable SHA-256 match: `a7a171af10b8284f41d12972e8676ed636ae934c6b811d33fdf5b84aa0db229d`.
- Installed-binary `--flow-animation-preview`: passed.
- Running process path: `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`.

## Adaptive monochrome surfaces, equal third-level scale, and path-following motion

### Evidence

- Light source visual truth: `<本机参考图，未随仓库分发>` (1290 x 563 pixels).
- Dark hierarchy source visual truth: `~/Downloads/IMG_4665.jpg` (782 x 416 pixels).
- Official behavior and appearance reference: `https://apphousekitchen.com/aldente-overview/features/`, including its charging and underpowered-charger screenshots.
- Revised light implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Revised dark implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-dark.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Revised equal-scale single-device implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png` (780 x 412 pixels; 390 x 206 AppKit points at 2x).
- Revised animation loops: `~/Library/Logs/CodexTouchBarNative-power-flow-underpowered-hierarchy-animation.gif` (780 x 412 pixels) and `~/Library/Logs/CodexTouchBarNative-power-flow-compact-low-battery-animation.gif` (780 x 341 pixels).
- Full-view comparison placed both user references, both revised appearances, the single-device state, and an animation phase into one comparison input. IMG_4665 and the hierarchy implementation differ by only 2 pixels in width and 4 pixels in height, so no density normalization was required for geometry review. IMG_4664 was used for the light monochrome material, ink contrast, radius, and elevation treatment.

### Findings

- No actionable P0, P1, or P2 difference remains for the four requested changes.
- Fonts and typography: watt values retain the established rounded system font, weights, line spacing, and high-contrast black/white ink. Small labels remain readable on both appearances.
- Spacing and layout rhythm: a sole third-level destination now uses exactly the second-level system card height; its ribbon also uses the same source and destination attachment thickness. Multi-device power allocation remains unchanged.
- Colors and visual tokens: the background remains transparent. Light appearance now uses white foreground modules and ribbons with black ink; dark appearance uses smoked white glass with white ink. Battery, laptop, charger, and external-device symbols no longer retain green/blue accent colors.
- Image and asset fidelity: all icons remain native vector symbols or the existing native AppKit paths. No placeholder image, handcrafted SVG, or raster substitution was introduced.
- Copy and content: watt values and hierarchy labels are unchanged.
- Coverage: main, input, and output ribbon groups now receive one compound background fill. Removed per-branch translucent background passes eliminate double-blended triangles and apparent uncovered patches at shared roots.
- Motion: each moving highlight center is evaluated on the cubic ribbon centerline. Its gradient axis uses the local cubic tangent, including the gentler middle-output curve, so motion follows each branch instead of moving on a fixed upward diagonal.
- Focused-region evidence was not required: at 780 pixels wide, the shared roots, equal-height second/third cards, symbol colors, and moving band are legible in the full captures. Animation phases 02 / 06 / 10 / 14 were also opened together to verify left-to-right progress along the curves.
- P3 only: the light reference retains faint colored optical tints, while this experiment intentionally follows the user's request for a stricter monochrome foreground.

### Comparison history

1. P2 - per-branch translucent backgrounds double-blended at shared/overlapping roots, creating triangular dark or apparently uncovered patches. Fix: one compound adaptive surface is drawn before one compound sheen; branch-local background gradients were removed. Post-fix light and dark hierarchy captures show continuous coverage.
2. P2 - a sole third-level endpoint used a 176...220 pixel visual floor and could be larger than its second-level parent. Fix: the sole endpoint height is now exactly `systemCardRect.height`, with matching source and destination ribbon widths. Post-fix evidence is the single-device capture.
3. P2 - the animation gradient used a fixed diagonal y-offset and moved by x-position, so its direction did not match curved ribbons. Fix: the band center now follows the cubic centerline and its gradient axis follows the local tangent. Post-fix evidence is the revised GIFs and four-phase comparison.
4. P2 - colored green/blue icons and pastel ribbons did not behave as one adaptive foreground system. Fix: introduced shared monochrome ink, surface, and rim tokens for light and dark appearances and applied them to cards, ribbons, labels, and symbols.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated light/dark captures, both GIFs, and animation frame sequences.
- `--smoke-test`: passed.
- `git diff --check`: passed.
- Installation was intentionally not performed. The currently installed Bar Control 0.16.3 (38) remains unchanged pending visual approval.

## Shared-root and module attachment corner revision

### Evidence

- White source visual: `<本机参考图，未随仓库分发>`.
- Dark hierarchy source visual: `~/Downloads/IMG_4665.jpg`.
- Revised single-device state: `~/Library/Logs/CodexTouchBarNative-power-flow-state-single-device.png`.
- Revised low-battery compact state: `~/Library/Logs/CodexTouchBarNative-power-flow-state-compact-low-battery.png`.
- Revised light/dark hierarchy states: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` and `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-dark.png`.
- Both source visuals and the corresponding revised implementation states were opened together for full-view comparison.

### Findings

- No actionable P0, P1, or P2 corner defect remains in the reviewed states.
- Shared roots now use one outer silhouette: only the group top-left and bottom-left corners are rounded, while the internal split stays completely filled and unoutlined.
- Merged inputs use the equivalent shared destination silhouette, rounding only the outer destination corners and preserving the continuous merge into the system card.
- Flow attachment corners use a radius up to 40 design pixels. First-level source cards use 34 design pixels in the expanded hierarchy and 40 in the compact hierarchy; dynamic destination cards use 34 or 40 according to the active scale.
- The change is geometry-only. Power-proportional sizing, third-level card equality, transparent background, adaptive monochrome surfaces, and path-following animation remain unchanged.

### Comparison history

1. P2 - independently rounding every sibling ribbon created black wedge-shaped cutouts at a shared source. Fix: added independent top/bottom corner geometry and a single shared attachment outline; only the two outside corners are rounded.
2. P2 - the first-level icon card retained a 15/16-pixel attachment-side radius and still read as sharp beside the wider ribbon. Fix: replaced that asymmetric path with a uniform 34/40-pixel rounded card at the applicable layout scale.
3. Post-fix evidence shows continuous shared roots in both the compact two-branch state and the three-output hierarchy, with rounded ribbon ends and rounded adjoining module cards.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all listed captures plus both GIF loops.
- `--smoke-test`: passed.
- `git diff --check`: passed.
- Installation was intentionally not performed. The running `/Applications/Bar Control.app` remains Bar Control 0.16.3 (38).

## Attachment equality, restrained radii, and minimum thickness revision

### Evidence

- Source visual truth: `<本机参考图，未随仓库分发>` and `~/Downloads/IMG_4665.jpg`.
- Revised single-device implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-state-single-device.png` (780 x 375 pixels).
- Revised hierarchy implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels).
- The two source/implementation state pairs were opened together in one full-view comparison input. Attachment edges and the 3.90 W branch remain clearly readable at this size, so a separate focused crop was not required.

### Findings

- No actionable P0, P1, or P2 geometry difference remains for this revision.
- Fonts and typography: all existing value sizes, weights, placement, and adaptive black/white ink are unchanged. The widened 3.90 W branch now contains its label rather than reading as a labeled hairline.
- Spacing and layout rhythm: every shared source or destination group now consumes exactly the connected module edge. Every individual destination ribbon ends at exactly its endpoint card height. Nonzero fan-out branches receive a 32 design-pixel source floor, and endpoint cards/ribbons retain a 48 design-pixel destination floor.
- Radii and elevation: flow corners are reduced from 40 to 24 design pixels. Expanded module corners are reduced from 34 to 22; compact module corners are 24. Existing shadows and rims are unchanged.
- Colors and visual tokens: adaptive monochrome surfaces, transparent background, contrast, and gradients remain unchanged.
- Image and asset fidelity: all device symbols remain the same native vector assets.
- Copy and content: watt values and device hierarchy remain unchanged.

### Comparison history

1. P2 - the prior 34/40-pixel module and flow radii looked over-rounded. Fix: reduced module radii to 22/24 and flow attachment radii to 24 design pixels. Post-fix evidence shows restrained corners without returning to sharp edges.
2. P2 - first-level roots and several destination edges were inset by 3 to 13 design pixels, so the ribbon edge did not equal the connected module height. Fix: source groups now fill the complete source card height, merged input groups fill the complete system-card edge, output source groups fill the complete parent edge, and each destination width equals its card height.
3. P2 - low-power output branches could taper to 8 design pixels and read as a line. Fix: shared fan-out allocation now applies a 32-pixel nonzero floor before distributing the remaining height by power; endpoint cards and their destination edges keep a 48-pixel floor.
4. Post-fix single-device and three-output captures show exact edge alignment and a visibly substantial 3.90 W branch.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated the implementation captures and GIF loops.
- `--smoke-test`: passed, including exact 116-pixel shared allocation and 32-pixel minimum branch assertions.
- `git diff --check`: passed.
- Installation was intentionally not performed. The running `/Applications/Bar Control.app` remains Bar Control 0.16.3 (38).

## Installed restrained-radius and minimum-thickness build

- Installed version: Bar Control 0.16.4 (39).
- Rollback copy: `backups/Bar Control-0.16.3-38-before-0.16.4.app`.
- `codesign --verify --deep --strict`: passed for the installed bundle and rollback copy.
- Distribution and installed executable SHA-256 match: `6667c3620c131e6adc8b4425474f20b30dbef7107853dd44d08d5aed3659d8d5`.
- Installed-binary `--flow-animation-preview`: passed and regenerated the accepted hierarchy and compact low-battery captures.
- Running process: `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`.

## Semantic icon color, seamless tide, subordinate single device, and internal power revision

### Evidence

- Geometry references: `<本机参考图，未随仓库分发>` and `~/Downloads/IMG_4665.jpg`.
- Deterministic internal-breakdown render: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png`.
- Dark-mode render: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-dark.png`.
- Revised single-device render: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png`.
- Full 3.6-second animation: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-animation.gif` and its 36 source PNG frames.
- Live hardware render: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png`.
- The two source images, the internal-breakdown render, the single-device render, and animation frames 00 and 35 were opened in one comparison input for final full-view review.

### Findings

- No actionable P0, P1, or P2 visual defect remains in the requested states.
- Icons now retain adaptive readability while using semantic colors: orange input/CPU, green battery and mobile device, blue whole Mac/display, purple GPU, and teal process.
- A sole third-level device uses 60% of the connected whole-Mac card height with a 48-design-pixel readability floor and remains centered on the full far-right column. In the small-host fixture this produces the requested approximately two-thirds hierarchy instead of another full-height primary node.
- The third level can contain measured external power, CPU/GPU subsystem power, and a top kernel billed-energy process. It remains capped at three visible branches to preserve the established reference density. Missing and zero-valued measurements are removed before layout.
- The deterministic layout fixture explicitly uses mock values only for repeatable visual QA. The live capture is generated from current machine data and showed measured iPad output, GPU watts, and a billed-energy process. The M1 `CPU Energy` channel remained static under an applied CPU load, so CPU is hidden in live UI instead of being estimated from unrelated totals.
- CPU/GPU/process endpoint cards include native SF Symbols plus compact captions where the symbol alone would not identify the subsystem or process.
- The animation now consists of two half-cycle-staggered soft tides. Each tide uses a sine endpoint envelope and becomes fully transparent before wrapping, so the outgoing and incoming states overlap instead of snapping from the destination back to the source.
- Pixel-difference verification across all 36 animation frames found the 35-to-00 wrap change was 0.220768 mean RGB levels, below the 0.285079 mean consecutive-frame change; the loop boundary is not an outlier.

### Comparison history

1. P2 - the prior single moving band visibly teleported when its phase wrapped. Fix: added a second staggered band and endpoint fade envelope. Post-fix evidence is the 36-frame GIF and the frame-difference result above.
2. P2 - a sole third-level device previously equaled the whole-Mac card height. Fix: changed it to 60% with a compact readability floor and resized its icon in concert with the card.
3. P2 - monochrome icons made CPU, GPU, process, source, battery, and host states harder to distinguish. Fix: restored restrained semantic system colors without changing the white/black adaptive glass surfaces.
4. P1 - CPU/GPU/process values could not be represented honestly by the former USB-only model. Fix: added a read-only IOReport hardware sampler plus separate kernel billed-energy process attribution. Unavailable channels are hidden, not inferred.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and generated all listed static/GIF evidence.
- `--smoke-test`: passed, including the internal three-branch fixture and existing hidden-output regressions.
- `--power-telemetry-probe`: passed with live GPU and process values; CPU unavailability on this M1 was correctly hidden.
- `git diff --check`: passed.
- Installation was intentionally not performed; the current `/Applications/Bar Control.app` was left untouched pending user approval of the actual program renders.

## Equal-width curved second-to-third-level ribbons

### Evidence

- Source visual truth: `~/Downloads/IMG_4665.jpg` and `~/Downloads/IMG_4650.jpg`.
- Dynamic hierarchy implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png`.
- Compact three-device implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png`.
- Single-device regression: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png`.
- Both source/implementation pairs were opened together in one full-view comparison input for final review.

### Findings

- No actionable P0, P1, or P2 visual defect remains for the requested equal-width interpretation.
- Each second-to-third-level ribbon now has one constant cross-section: its source width, curved body thickness, destination width, and endpoint-card height are equal.
- Power still controls the constant thickness of each ribbon. When preferred power-proportional sizes fit inside the parent edge they are preserved; compact groups reuse the existing proportional allocator with a 32-design-pixel nonzero floor, preventing low-power branches from collapsing into hairlines.
- A sole third-level device retains its subordinate 60% scale and centered placement, while its ribbon uses the same height from the whole-Mac card through the endpoint card.
- The reference images establish the curve direction and hierarchy. The source screenshots include some tapering; constant source/destination width is an intentional user-requested correction, not an attempt to copy that taper.
- Fonts, spacing outside the connected dimensions, adaptive surfaces, semantic icon colors, native vector assets, labels, and animation treatment remain unchanged.

### Comparison history

1. P2 - the previous second-to-third-level geometry could read as an asymmetric funnel because source allocation and endpoint-card height were calculated independently. Fix: added one equalized width allocation and use it for both ribbon edges and the endpoint card.
2. P2 - simply forcing equal widths could overflow the whole-Mac edge in compact three-device states. Fix: preserve preferred card heights when they fit; otherwise proportionally compress the complete group into the available edge with the existing minimum-thickness allocator.
3. Post-fix dynamic, compact-three, and single-device captures show curved bars with equal thickness on both ends and matching endpoint modules.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all implementation captures.
- `--smoke-test`: passed, including preferred-size preservation, compact shared-edge allocation, and minimum-thickness assertions.
- Installation was intentionally not performed. `/Applications/Bar Control.app` remains the accepted Bar Control 0.16.4 (39) rollback target while this revision awaits visual approval.

## Normal endpoint token and icon floor revision

### Evidence

- Single-device source context: `/var/folders/2j/1pfctdcd11z178vkxyw6lrw00000gn/T/codex-clipboard-762a5494-0bdd-4bd2-ad56-0bcc743adbb7.png` (780 x 412 pixels).
- Single-device implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png` (780 x 412 pixels).
- Multi-device hierarchy source: `~/Downloads/IMG_4665.jpg` (782 x 416 pixels).
- Multi-device implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png` (780 x 412 pixels).
- Both source/implementation pairs were opened together in one full-view comparison input. The endpoint-card and symbol sizes are clearly readable at native output density, so a focused crop was not required.

### Findings

- No actionable P0, P1, or P2 visual defect remains for the clarified sizing behavior.
- A sole third-level module no longer derives its size from `systemCardHeight * 0.60`. It uses a 104-design-pixel normal endpoint token, while the whole-Mac host reserves a separate 136-design-pixel token. This produces a visually subordinate but normally sized child without encoding a fixed parent percentage.
- A sole endpoint icon uses a 60-design-pixel normal token. Multi-endpoint icons have a 48-design-pixel hard floor. Low wattage therefore changes branch/card allocation but cannot reduce an icon into a dot or hairline.
- Multi-device endpoint cards have a 72-design-pixel hard floor. The whole-Mac card expands with endpoint count and preferred power-proportional heights, up to the existing 360-design-pixel layout cap, so the icon floor is supported by real card space rather than overflow.
- Second-to-third-level ribbons remain curved and constant-width from source through destination; each ribbon still equals its endpoint-card height.
- Fonts/typography, spacing outside the connected card dimensions, adaptive colors and glass tokens, native SF Symbol assets, labels, and copy remain unchanged.
- The source screenshots ground hierarchy, curve direction, and approximate visual rank. Larger icons and token-based endpoint sizing are intentional corrections from the user's explicit clarification.

### Comparison history

1. P2 - the previous single endpoint was calculated as 60% of the whole-Mac card, reducing the card to 68 design pixels in the fixture and the icon to approximately 32 design pixels. It read as a power-scaled miniature instead of a normal device control. Fix: replaced the ratio with independent 104/136 child/host component tokens and a 60-pixel single-icon token.
2. P2 - multi-device low-power cards and icons could still compress below normal readable size. Fix: added 72-pixel endpoint-card and 48-pixel icon floors, then made the whole-Mac card reserve the required group height before laying out equal-width ribbons.
3. Post-fix evidence shows the single device centered at the far right with a normal-size green device symbol, a child card visibly smaller than but not mechanically scaled from the host, and multi-device symbols that remain readable.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated the single-, three-, and dynamic-device renders.
- `--smoke-test`: passed, including the 104-pixel endpoint token, 136-pixel host reservation, 72-pixel multi-device floor, 360-pixel dynamic allocation, and existing hierarchy regressions.
- `git diff --check`: passed after the implementation and QA update.
- Installation was intentionally not performed. `/Applications/Bar Control.app` remains Bar Control 0.16.4 (39) pending visual approval.

## Equal-width first-to-second-level and larger single endpoint revision

### Evidence

- Reference hierarchy: `~/Downloads/IMG_4650.jpg` and `~/Downloads/IMG_4665.jpg`.
- Single-endpoint implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-one-light.png` (780 x 412 pixels).
- Dynamic input implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels).
- The two reference/implementation pairs were opened together in one full-view comparison input. All attachment edges and device icons are readable at this scale, so a focused crop was not required.

### Findings

- No actionable P0, P1, or P2 visual defect remains for this correction.
- Every first-to-second-level ribbon now uses the destination card height as its source width and end width. The source slots, curved bodies, destination edges, and battery/whole-Mac cards therefore have identical cross-sections instead of independently allocated widths.
- The active first-level source and all second-level destinations share one exact 413-design-pixel attachment budget. When the whole-Mac node must grow for third-level content, the battery/system allocation is recomputed inside that same budget, preserving equal widths without overflowing the source card.
- The charging-input hierarchy already used equal source and destination allocations; its dynamic 3.47 W + 84.00 W render remains a regression fixture for the same rule.
- A sole third-level endpoint is increased from 104 to 120 design pixels, its normal icon token from 60 to 64, and its independently sized whole-Mac host reservation from 136 to 152. It is visibly larger while remaining subordinate and is still not computed as a parent percentage.
- Second-to-third-level ribbons remain curved, constant-width, centered, and matched to their endpoint cards. Multi-device card and icon floors remain unchanged.
- Fonts/typography, non-attachment spacing, adaptive light/dark colors, glass tokens, native vector assets, labels, copy, and animation remain unchanged.

### Comparison history

1. P2 - normal first-to-second-level layouts still used a 413-pixel power allocation at the source but independent dynamic card heights at the destination. This made individual ribbons taper even though the later hierarchy had been corrected. Fix: use each destination card height for both ends and allocate the two cards inside the exact shared 413-pixel source budget.
2. P2 - the prior 104-pixel sole endpoint remained visually conservative after the icon-floor correction. Fix: raised the independent single-endpoint/card and icon tokens to 120/64, with a separate 152-pixel whole-Mac reservation.
3. Post-fix single-, three-, and dynamic-device renders show equal first/second attachment widths, equal second/third attachment widths, and a larger centered sole endpoint.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated the single-, three-, and dynamic-device renders.
- `--smoke-test`: passed, including exact 413-pixel second-level sums, the 120-pixel single endpoint, the 152-pixel host reservation, endpoint floors, and existing hierarchy regressions.
- Installation was intentionally not performed. `/Applications/Bar Control.app` remains Bar Control 0.16.4 (39) pending visual approval.

## Installed equal-width and internal-power build

- Installed version: Bar Control 0.16.5 (40).
- Installed features include the equal-width first/second and second/third hierarchy, the larger sole endpoint, and measured third-level external/CPU/GPU/process power outputs.
- Deterministic internal-power render: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png`.
- Live hardware render: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png`; the current machine exposed measured GPU and billed-energy process channels while CPU power remained unavailable and was correctly hidden.
- Sub-0.1 W process labels use three decimals so a real nonzero measurement is not rendered as `0.00 W`.
- Previous accepted installation retained at `backups/Bar Control-0.16.4-39-before-0.16.5.app`; signature verification passed and executable SHA-256 remains `6667c3620c131e6adc8b4425474f20b30dbef7107853dd44d08d5aed3659d8d5`.
- Distribution and installed 0.16.5 executables match at SHA-256 `72c73072c658d2a2fc66b378f67fad7a0910a97df3d317c54ba6609cd698927b`.
- `codesign --verify --deep --strict`: passed for the installed bundle.
- Installed process is running from `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`; startup, Control Strip registration, login-item status, and initial metrics sampling were recorded successfully.
- Physical Touch Bar/menu appearance still requires the user's on-device inspection; installation and off-screen renders do not substitute for that acceptance.

## Restored compact third-level invariants

### Evidence

- Source hierarchy references: `~/Downloads/IMG_4650.jpg` and `~/Downloads/IMG_4665.jpg`.
- Revised external-device render: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png` (780 x 412 pixels).
- Revised deterministic internal-power render: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png` (780 x 412 pixels).
- Revised live hardware render: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png` (780 x 412 pixels).
- Both reference/implementation pairs were opened together in one full-view comparison input. Endpoint icons and attachment edges are clearly readable, so a focused crop was not required.

### Root-cause summary

1. The multi-endpoint center allocator used all remaining vertical space as inter-card gaps. Smaller cards therefore produced larger gaps and scattered three modules across the full column.
2. Endpoint icons still had separate single-device and multi-device formulas. The multi-device branch retained a 48-pixel floor, silently overriding the previously accepted normal icon size.
3. Ribbon/card equality existed numerically, but the 72-pixel card floor and full-column spacing made the endpoint modules look detached and undersized. The earlier QA asserted values rather than treating the installed visual result as the acceptance boundary.
4. The requirements were encoded across separate calculations instead of one set of layout invariants, allowing later count-based logic to reintroduce old behavior.

### Findings and fixes

- No actionable P0, P1, or P2 visual defect remains for the clarified compact-three state.
- Third-level modules no longer spread to fill the available column. The complete group is centered on the whole-Mac node with a 32-design-pixel maximum gap, falling back only when the region cannot fit.
- All endpoint states now share one icon-size function with a 64-design-pixel hard floor. Device count no longer selects a smaller icon branch.
- Multi-endpoint cards and ribbons have a 96-design-pixel hard floor; a sole endpoint uses a separate 132-pixel normal card token. The whole-Mac/source attachment budget was raised to 360/456 so these floors fit without being compressed away.
- Each branch continues to use one equalized value for source width, curved-body thickness, destination width, and endpoint-card height. The revised renders make that equality visually apparent at every endpoint.
- The three-device group remains power-proportional above the floor; weaker branches do not collapse into lines.
- Sub-0.1 W labels receive a wider label box and smaller cap, preventing `0.006 W` from truncating while preserving exact values.
- Fonts/typography outside that small-value correction, adaptive colors, glass surfaces, native SF Symbols, animation, copy, and hierarchy semantics remain unchanged.

### Comparison history

1. P2 - the installed 0.16.5 layout spread three modules across the complete far-right column. Fix: replaced fill-space gaps with a centered compact group and a 32-pixel maximum gap.
2. P2 - multi-device icons still used the smaller 48-pixel floor. Fix: removed the single/multi icon fork and use one 64-pixel minimum in every state.
3. P2 - 72-pixel endpoint cards made equal-width ribbons look optically disconnected from normal-size modules. Fix: raised the card/ribbon floor to 96 and expanded the parent/source attachment budgets so the floor remains real after allocation.
4. P2 - precise process power such as `0.055 W` could truncate in the widened minimum branch. Fix: use a 220-pixel label region and 36-pixel font cap only for sub-0.1 W labels.
5. Post-fix external, deterministic internal, and live hardware renders show compact third-level grouping, normal-size icons, and exact visible ribbon-to-module attachment widths.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all comparison states.
- `--smoke-test`: passed, including the 96-pixel card floor, unified 64-pixel icon floor, 132-pixel single-card token, 360-pixel system allocation, 456-pixel source attachment, and existing hierarchy regressions.
- `--power-telemetry-probe`: passed and generated the revised live internal-power state.
- `git diff --check`: passed after implementation and QA updates.
- This corrective source build is intentionally not installed. `/Applications/Bar Control.app` remains the previously installed 0.16.5 (40) build until the user validates these actual renders.

## Flush second-to-third-level source attachment

### Evidence

- Source references: `~/Downloads/IMG_4650.jpg` and `~/Downloads/IMG_4665.jpg`.
- Revised external-device render: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png` (780 x 412 pixels).
- Revised dynamic hierarchy render: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels).
- Revised live internal-power render: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png` (780 x 412 pixels).
- Both source/implementation pairs were opened together in one full-view comparison input. The whole-Mac/output junction is readable at native output density, so a separate crop was not required.

### Findings and fixes

- No actionable P0, P1, or P2 visual defect remains for the requested junction correction.
- Root cause: the whole-Mac card ended at design `x=716`, while every output ribbon still started at the legacy fixed `x=733`. The 17-pixel horizontal discontinuity remained after width equality was corrected.
- Output ribbons now derive their start X directly from `systemCardRect.maxX`; no fixed layout coordinate can drift away from the current second-level card.
- A multi-output group now always allocates the complete whole-Mac connection height. Its first top edge and last bottom edge therefore meet the card's top and bottom exactly instead of leaving vertical insets when preferred child sizes sum to less than the parent.
- Multi-output source corners are square and their source cap outline is removed. The connected whole-Mac card uses a square, un-stroked right edge, so the card and branch group form one continuous surface without a rounded notch or vertical splice line.
- A sole third-level endpoint remains the accepted smaller centered child; it touches the card's right boundary directly but does not consume the complete parent height.
- The previously fixed compact spacing, 96-pixel endpoint floor, unified 64-pixel icon floor, equal ribbon/card widths, colors, typography, assets, labels, and animation remain unchanged.

### Comparison history

1. P2 - the prior corrected render still left a 17-design-pixel gap between the second-level whole-Mac card and the third-level branch root. Fix: bind the root to `systemCardRect.maxX`.
2. P2 - preferred child heights could leave the multi-branch root inset from the card's top and bottom. Fix: multi-output equalization now consumes the complete parent connection height.
3. P2 - simply moving the root left would leave the card's rounded right rim and output source outline as a visible junction seam. Fix: use an open-right connected card contour and omit all source caps/radii for the multi-output group.
4. Post-fix external, dynamic, deterministic internal, and live hardware renders show continuous top and bottom perimeters from the whole-Mac card into the output group.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all implementation states.
- `--smoke-test`: passed, including full 360-pixel multi-output allocation, power ordering, 96-pixel floor, unified icon floor, and existing hierarchy regressions.
- `--power-telemetry-probe`: passed and generated the revised live internal-power render.
- `git diff --check`: passed after implementation and QA updates.
- This correction is intentionally not installed. `/Applications/Bar Control.app` remains the previously installed 0.16.5 (40) build until the user validates the actual renders.

## Corrected independent second-level cards and endpoint spacing

### Evidence

- Source references: `~/Downloads/IMG_4650.jpg` and `~/Downloads/IMG_4665.jpg`.
- Revised external-device render: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png` (780 x 412 pixels).
- Revised dynamic hierarchy render: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels).
- Revised deterministic internal-power render: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png` (780 x 412 pixels).
- Both source/implementation pairs were opened together at full size. The card/ribbon gap, second-level icons, branch-root alignment, and endpoint spacing are readable without a crop.

### Root cause and correction

- The previous correction misread vertical edge alignment as a request to merge surfaces. It removed the 17-design-pixel reference gap and opened the whole-Mac card's right edge, visually joining the second-level card to the output ribbons.
- The whole-Mac card is again a complete independently rounded module. The output root starts after a fixed 17-design-pixel gap, with its own rounded shared source cap.
- The output group's top and bottom still match the complete whole-Mac connection height. This preserves the requested vertical alignment without fusing the two components.
- Battery and whole-Mac symbols now use one second-level size function with a 64-design-pixel hard floor and 72-pixel cap in normal, compact, and underpowered layouts. Card allocation can no longer silently select a smaller icon branch.
- Three endpoint modules use a 64-design-pixel maximum gap instead of the over-compressed 32-pixel value. They remain centered around the whole-Mac node, visibly grouped but no longer crowded.
- Third-level card/ribbon equality, the 96-pixel branch floor, power ordering, adaptive colors, animation, typography, and hierarchy semantics remain unchanged.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all comparison states.
- `--smoke-test`: passed, including the new second-level 64/72 icon assertions and existing 360-pixel full-height multi-output allocation checks.
- `--power-telemetry-probe`: passed and regenerated the current live internal-power state.
- `git diff --check`: passed before this QA entry and will be rerun after it.
- This correction is intentionally not installed. `/Applications/Bar Control.app` remains the previously installed 0.16.5 (40) build until the user validates the actual renders.

## Installed independent-card spacing correction

- Installed `/Applications/Bar Control.app` as Bar Control 0.16.5 (40).
- Previous installed bundle retained at `backups/Bar Control-0.16.5-40-before-independent-card-spacing.app`.
- `codesign --verify --deep --strict`: passed for both installed and rollback bundles.
- Distribution and installed executable SHA-256 match at `6e2c8b456f5b2645cd379f05526cdb1411abe895f66bdff08a47338a181f5a36`.
- Installed process is running from `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative`.
- Startup log confirms Control Strip support and registration, enabled login item, initial metrics sampling, main-container presentation, and Touch Bar brightness correction.
- Physical menu/Touch Bar appearance remains the user's acceptance boundary after installation.

## Readable endpoint identities and non-shrinking input battery

### Evidence

- Source visual truth: `~/Downloads/IMG_4665.jpg` (780 x 384 pixels after normalized comparison) and `~/Downloads/IMG_4650.jpg`.
- Revised dynamic implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-dynamic-hierarchy-light.png` (780 x 412 pixels).
- Revised internal-power implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png` (780 x 412 pixels).
- Revised external-device implementation: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png` (780 x 412 pixels).
- Full-view reference and implementation were opened together. A focused right-column comparison was also opened from normalized 350 x 412 crops because endpoint copy and icon identity were too small to judge reliably in the full view.

### Findings and fixes

- P1 resolved: CPU/GPU were previously identified by 12-to-20-design-pixel colored captions, while external devices had no caption at all. At the rendered density, the labels were too small and color became the only usable distinction.
- Every endpoint now has a high-contrast bold identity label. Canonical labels include `CPU`, `GPU`, `显示器`, `iPad`, `iPhone`, `扩展坞`, and `外接设备`; measured process names remain visible with controlled truncation.
- Endpoint labels use 22-to-26-design-pixel type for normal names and 19-to-22 for longer process names. Colored SF Symbols remain as secondary recognition cues, while text follows the adaptive foreground color for light/dark contrast.
- P2 resolved: the underpowered first-level battery input still used the old 72-design-pixel card floor, so the entire battery module visibly shrank even after the symbol-size correction. Its normal layout floor is now 132, while the paired charger receives the remaining 324 of the unchanged 456-pixel attachment budget.
- Battery and whole-Mac symbols now use a 72-design-pixel floor and 80-pixel cap. Battery-only source state uses the same larger battery-symbol token.
- Flow direction, branch/card width equality, independent second-level card gap, endpoint spacing, power ordering, colors, and animation remain unchanged.

### Comparison history

1. P1 - endpoint captions were absent or unreadably small. Fix: add explicit canonical labels to every endpoint and raise type size/weight/contrast.
2. P2 - first-level low-power battery input used a 72-pixel compact card. Fix: raise the normal input-card floor to 132 without changing the total attachment budget.
3. Post-fix full and focused comparisons show readable `CPU`, `显示器`, and `外接设备` identities; deterministic internal renders likewise show `CPU`, `GPU`, and process names. The low-power battery card is now a normal module rather than a thin badge.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated dynamic, external-device, and internal-power states.
- `--smoke-test`: passed, including canonical-label assertions, 132-pixel input-card floor, 72/80 second-level icon sizes, and existing hierarchy regressions.
- `--power-telemetry-probe`: passed and regenerated the current live hardware state.
- `git diff --check`: passed before this QA entry and will be rerun after it.
- This correction is intentionally not installed. `/Applications/Bar Control.app` remains the previously installed 0.16.5 (40) build until the user validates these actual renders.

## Installed readable endpoint and battery-size correction

- Installed `/Applications/Bar Control.app` as Bar Control 0.16.5 (40).
- Previous installed bundle retained at `backups/Bar Control-0.16.5-40-before-readable-endpoints.app`.
- `codesign --verify --deep --strict`: passed for both the installed and rollback bundles.
- Distribution and installed executable SHA-256 match at `e2a0d307d5033d79ac71e5bbad4c321f82b05764b5e4289efce8276daa660faa`.
- Installed process remains running from `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative` after the post-launch wait.
- Startup log confirms Control Strip support/registration, enabled login item, initial power sampling, and successful main-container presentation.
- Physical Touch Bar appearance remains the user's final acceptance boundary.

## Corrected third-level hardware hierarchy

### Evidence

- Source hierarchy reference: `~/Downloads/IMG_4665.jpg` (798 x 384 pixels).
- Deterministic peer-hardware render: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png` (780 x 412 pixels).
- Live peer-hardware render: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png` (780 x 412 pixels).
- External-device regression render: `~/Library/Logs/CodexTouchBarNative-power-flow-device-count-three-light.png` (780 x 412 pixels).
- Reference, deterministic implementation, and live implementation were opened together at full size. Endpoint names and watt totals are readable without a focused crop, so no additional crop was required.

### Information-architecture correction

- P1 resolved: measured processes were previously inserted beside CPU and GPU whenever third-level slots remained. That mixed execution-level consumers with hardware-level power rails and could imply that process watts were independent of CPU/GPU watts.
- Third level now contains only peer power destinations: measured external devices, measured CPU, measured GPU, and a mathematically reconciled `其他硬件` remainder.
- `其他硬件` is calculated as whole-machine watts minus measured external-output, CPU, and GPU watts. Negative or effectively zero remainders are clamped/hidden; no synthetic CPU or GPU value is invented.
- Process energy sampling remains available in telemetry but is no longer rendered at this level. It is reserved for a possible future fourth-level drill-down under the hardware that executes the work.
- The deterministic fixture now reconciles exactly: 34.6 W total = 16.8 W CPU + 9.4 W GPU + 8.4 W other hardware.
- The live fixture correctly shows only GPU and other hardware because the current machine did not expose a CPU power rail in that sample.
- Typography, icon size, spacing, card/ribbon equality, flow direction, adaptive colors, and external-device behavior remain unchanged.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated all hierarchy states.
- `--smoke-test`: passed, including the exact `[CPU, GPU, 其他硬件]` deterministic order and a regression assertion that no process appears at third level.
- `--power-telemetry-probe`: passed and generated the current two-rail live state.
- `git diff --check`: passed before this QA entry and will be rerun after it.
- This hierarchy correction is intentionally not installed. `/Applications/Bar Control.app` remains the previously installed 0.16.5 (40) build until the user validates these actual renders.

## Installed peer-hardware hierarchy correction

- Installed `/Applications/Bar Control.app` as Bar Control 0.16.5 (40).
- Previous installed bundle retained at `backups/Bar Control-0.16.5-40-before-hardware-peer-hierarchy.app`.
- `codesign --verify --deep --strict`: passed for both installed and rollback bundles.
- Distribution and installed executable SHA-256 match at `3ca9727a29404e03ff4c518136358e9a481297cdba598e0f505e3cf55de1d7cf`.
- Installed process remains running from `/Applications/Bar Control.app/Contents/MacOS/CodexTouchBarNative` after the post-launch wait.
- Startup log confirms Control Strip support/registration, enabled login item, initial power sampling, and successful main-container presentation.
- Physical Touch Bar appearance remains the user's final acceptance boundary.

final result: passed

## Installed fan and temperature telemetry

- Installed `/Applications/Bar Control.app` as Bar Control 0.16.6 (41).
- Previous installed bundle retained at `backups/Bar Control-0.16.6-41-before-fan-temperature.app`.
- The first installed temperature build exposed an HID cold-session `30°C` placeholder during validation. The GPU temperature reader now retains one read-only HID session instead of recreating it every refresh.
- The intermediate bundle is retained at `backups/Bar Control-0.16.6-41-before-gpu-temperature-session-fix.app`.
- Three fresh installed-executable probes returned stable GPU values of `65.27°C`, `65.27°C`, and `66.23°C`; fan values were `1188`, `1190`, and `1198 RPM`.
- The final live render shows fan `1198 RPM`, battery `36.0°C`, and GPU `66.2°C`.
- `codesign --verify --deep --strict` passed for the installed and both rollback bundles; the distribution and installed executables compare byte-for-byte equal.
- The installed 0.16.6 (41) process is running from `/Applications/Bar Control.app`; startup confirms Control Strip registration, enabled login item, initial power sampling, and main-container presentation.
- Physical Touch Bar appearance remains the user's final acceptance boundary.

final result: passed

## 2026-08-25 read-only fan status

- before screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-before-fan-summary-light.png`
- deterministic after screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-local-external-summary-light.png`
- deterministic dark screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-local-external-summary-dark.png`
- stopped-fan screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-internal-breakdown-light.png`
- live AppleSMC screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png`
- exact before/after comparison: `~/Library/Logs/CodexTouchBarNative-power-flow-fan-summary-qa-comparison.png`
- viewport: native AppKit menu view, 390 x 264 pt at 2x

### Implementation and safety

- Added a third equal-width material chip beside `本机实际` and `外接设备`, using the native `fan.fill` symbol and adaptive purple accent.
- The chip renders three explicit states: `运行` with measured RPM, `停转` with `0 RPM`, and `无数据` with `--` when a fan sensor is unavailable.
- Fan RPM is read from the AppleSMC `F0Ac` through `F3Ac` keys. The support layer opens a read-only connection and exposes no fan-control or write operation.
- The live telemetry probe read `1181 RPM` and the actual live screenshot renders that value without fixture substitution.

### Visual comparison

- The graph region, flow ribbons, device cards, icon floors, colors, and secondary source/status line remain pixel-aligned with the before capture.
- The previous two wide chips were redistributed into three equal chips. All labels and values remain readable at the native 390 pt width.
- The deterministic light and dark captures preserve contrast, and the stopped-fan state fits without changing the footer height.
- No clipping, truncation, baseline mismatch, or actionable P0/P1/P2 issue remains.

### Validation

- `swift build -c release`: passed.
- `--flow-animation-preview`: passed and regenerated light, dark, stopped, and running states.
- `--power-telemetry-probe`: passed with a real `1181 RPM` AppleSMC sample.
- `--smoke-test`: passed, including deterministic fan telemetry.
- `git diff --check`: passed before this QA entry and will be rerun after it.
- This fan-status change is intentionally not installed pending user validation of the actual render.

final result: passed

## 2026-08-25 synchronized local/external power summary

- source visual truth path: `~/Library/Logs/CodexTouchBarNative-power-flow-before-summary-live-light.png` (installed 0.16.5 (40) graph immediately before this change), grounded by `~/Downloads/IMG_4665.jpg`
- implementation screenshot path: `~/Library/Logs/CodexTouchBarNative-power-flow-summary-live-light.png`
- deterministic light screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-local-external-summary-light.png`
- deterministic dark screenshot: `~/Library/Logs/CodexTouchBarNative-power-flow-local-external-summary-dark.png`
- same-state comparison: `~/Library/Logs/CodexTouchBarNative-power-flow-summary-exact-qa-comparison.png`
- viewport: native AppKit menu view, 390 x 264 pt
- source pixels: 780 x 412 at 2x for the existing 390 x 206 graph
- implementation pixels: 780 x 528 at 2x for the 390 x 264 graph-plus-summary view
- density normalization: the implementation's top 390 x 206 pt graph region was cropped and compared 1:1 with the installed source capture; both were 780 x 412 px at 2x
- state: live underpowered-adapter state with charger and battery feeding the Mac, one iPad output, GPU, and other hardware

### Full-view comparison evidence

The new summary is appended below the approved graph instead of resizing it. The before/after comparison keeps the graph region at the same 390 x 206 pt frame. Device cards, attachment edges, ribbon curves, corner treatment, icon floors, and column spacing remain in their previous positions; only live readings and their power-driven branch allocation changed between captures.

### Focused-region evidence

The full 780 x 528 implementation screenshot clearly resolves the added 116 px footer. Its two 26 pt material chips show `本机实际` and `外接设备` with monospaced values. The second line separates charger/battery sources from the right-aligned `USB-C 自动协商` status. A separate focused crop was unnecessary because every footer label is readable at the native 2x capture.

### Required fidelity surfaces

- Fonts and typography: native San Francisco labels and monospaced-digit power values remain readable in light and dark appearances; hierarchy separates labels, values, and secondary source/status copy.
- Spacing and layout rhythm: the graph is unchanged at 390 x 206 pt; the 58 pt footer uses equal-width chips, 8 pt outer insets, an 8 pt chip gap, and a compact secondary row.
- Colors and visual tokens: adaptive label colors and native material are used; blue identifies local Mac power, orange identifies external output, and both retain sufficient contrast in light and dark captures.
- Image quality and asset fidelity: existing SF Symbols and native vector rendering remain sharp at 2x; no source icon or device asset was replaced.
- Copy and content: `本机实际`, `外接设备`, `来源`, and `USB-C 自动协商` describe measured values and do not imply unsupported manual power-role control.

### Data consistency checks

- deterministic fixture: 32.7 W whole-machine - 15.0 W external = 17.7 W local
- deterministic fixture sources: 12.6 W charger + 20.1 W battery = 32.7 W
- live capture: 21.5 W whole-machine - 4.32 W external = 17.18 W, displayed as 17.2 W
- live graph peers: 4.17 W GPU + 13.0 W other hardware = 17.17 W (rounding-aligned with the 17.2 W summary)

### Findings

- No actionable P0/P1/P2 visual or accounting mismatch remains.
- P3: the source line is intentionally dense at 10 pt to preserve the 390 pt menu width; it remains readable in both captured appearances.

### Comparison history

- pass 1: no P0/P1/P2 issue found; no visual fix was made after the comparison.

final result: passed

## 2026-08-25 battery and GPU temperatures

- source visual truth path: `~/Library/Logs/CodexTouchBarNative-power-flow-before-temperature-summary-light.png`
- implementation screenshot path: `~/Library/Logs/CodexTouchBarNative-power-flow-local-external-summary-light.png`
- live sensor screenshot path: `~/Library/Logs/CodexTouchBarNative-power-flow-live-hardware-breakdown-light.png`
- dark screenshot path: `~/Library/Logs/CodexTouchBarNative-power-flow-local-external-summary-dark.png`
- exact before/after comparison: `~/Library/Logs/CodexTouchBarNative-power-flow-temperature-summary-qa-comparison.png`
- viewport: native AppKit menu view, graph 390 x 206 pt plus 88 pt summary footer
- source pixels: 780 x 528 at 2x; implementation pixels: 780 x 588 at 2x
- density normalization: both captures use the same 390 pt width and 2x density; top edges are aligned so the unchanged 390 x 206 pt graph compares 1:1
- state: deterministic underpowered-adapter fixture with one iPad, running fan, battery temperature, and GPU temperature

### Full-view comparison evidence

The side-by-side comparison confirms that the approved graph, first summary row, device cards, ribbons, icon floors, typography, and horizontal positions are unchanged. A new equal-width temperature row is inserted above the existing source/status caption, increasing only the footer height by 30 pt.

### Focused-region evidence

The two temperature chips are readable in the full native 2x capture, so a separate crop was unnecessary. The battery and GPU symbols, labels, decimal values, degree marks, and unit remain sharp without clipping in both light and dark appearances.

### Required fidelity surfaces

- Fonts and typography: native San Francisco labels and monospaced-digit temperatures preserve the established hierarchy; `33.4°C` and `63.9°C` fit without truncation.
- Spacing and layout rhythm: the new row uses the established 26 pt chip height, 8 pt gap, 8.5 pt outer inset, continuous 8 pt radius, border, and material shadow.
- Colors and visual tokens: green matches the battery destination; pink matches the GPU destination; adaptive label and material colors retain dark-mode contrast.
- Image quality and asset fidelity: both icons are native SF Symbols rendered as vectors; no bitmap, custom drawing, placeholder, or handcrafted SVG was introduced.
- Copy and content: concise `电池` and `GPU` labels pair with explicit Celsius values; inaccessible readings fall back to `--°C` rather than estimates.

### Live telemetry evidence

- Fan: `1193 RPM` from AppleSMC `F0Ac` in the same live sample.
- Battery: `36.69°C` from AppleSmartBatteryPack, independently consistent with live SMC/HID battery sensors.
- GPU: `66.20°C`, averaged from two live `GPU MTR Temp Sensor` HID readings.
- The live implementation screenshot renders `1193 RPM`, `36.7°C`, and `66.2°C` from that sample.

### Findings and comparison history

- No actionable P0/P1/P2 visual, data-source, or fallback-state mismatch remains.
- pass 1: no P0/P1/P2 issue found; no visual fix was made after the exact comparison.
- `swift build -c release`, `--flow-animation-preview`, `--smoke-test`, and `git diff --check` passed.
- Installed as Bar Control 0.16.6 (41) after user approval and post-install sensor validation.

final result: passed
