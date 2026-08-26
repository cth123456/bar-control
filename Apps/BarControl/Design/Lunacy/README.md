# Bar Control Lunacy design source

These files are the editable layout baseline for the accepted Bar Control
0.16.0 (35) power-flow UI:

- `BarControl-PowerFlow-Expanded-0.16.0.free`: Lunacy expanded workspace.
- `BarControl-PowerFlow-Expanded-0.16.0.svg`: inspectable 1290 x 681 vector source.
- `BarControl-PowerFlow-Compact-0.16.0.free`: Lunacy compact workspace.
- `BarControl-PowerFlow-Compact-0.16.0.svg`: inspectable 1290 x 563 vector source.
- `BarControl-PowerFlow-Dynamic-QA-0.16.0.free`: dynamic-hierarchy QA
  workspace derived from the editable expanded groups. Use the supplied
  `IMG_4665.jpg` as an independent overlay layer for measured comparison.

The SVG geometry was copied from the accepted native AppKit path coordinates.
SVG IDs name the source card, main ribbons, output ribbons, cards, labels, and
icons so layout changes can be measured rather than inferred from screenshots.

## Required change and acceptance flow

1. Edit the matching `.free` file in Lunacy.
2. Export SVG at 1x with the original canvas size and a transparent background.
3. Compare exported path/card coordinates with the native AppKit implementation.
4. Render the actual program for compact, one-device, two-device, and
   three-device states in both light and dark appearances.
5. Show those actual program renders to the user for visual approval.
6. Only after approval, build and replace `/Applications/Bar Control.app`.

For the dynamic fixture, keep the supplied reference overlay independent from
the editable groups. The native program render remains the acceptance artifact;
the Lunacy overlay is a measurement aid, not proof that the AppKit result
matches.

A Lunacy canvas, SVG export, successful build, or off-screen fixture by itself
does not authorize installation and does not prove the physical Touch Bar state.
