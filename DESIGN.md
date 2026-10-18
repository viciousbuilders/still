# Interface direction

Still is a compact native macOS focus timer and website blocker. Preserve its rounded wordmark, single muted green accent, system typography, and neutral system surfaces. Use native SwiftUI and AppKit controls. The design-taste skill's preservation audit and copy restraint apply here; marketing-page patterns do not replace native product controls.

DESIGN_VARIANCE 3, MOTION_INTENSITY 1, VISUAL_DENSITY 4. This is a light refinement of the established interface. Keep layout predictable and reduce visual clutter through omission. No automatic decorative animation, gradients, added typefaces, or motivational subtitles.

## Audit and changes

The earlier group panel mixed navigation, editing, and blocking controls. Focus, Groups, and Garden now separate those tasks. The next refinement removes duplicate picker labels, wide-tracked uppercase phase labels, decorative timer and group outlines, repeated row icons, round dots beside an existing round count, and explanatory copy already covered elsewhere. Keep functional state and next-transition messages.

The leaf wordmark, green accent, native inputs, visible keyboard focus, inline errors, and group boundaries remain. Use 12-point radii for grouped surfaces and 8-point radii for primary buttons. Typography stays in the system family, with rounded light timer digits and monospaced changing numbers.

## Views

The panel is 400 points wide and screen-bounded, up to 620 points tall. The fixed header contains the wordmark and settings; a native segmented control switches Focus, Groups, and Garden. The footer reports actual blocking state and provides Quit. Content scrolls within each view.

Focus shows the countdown, a restrained tree progress symbol, group and duration controls, round selection, one primary start action, and a compact next-tree progress bar. During a cycle, show its round, actual group state, next automatic transition, and End cycle early. Four-round long-break details belong to the rounds control's help. Shared-domain exceptions stay visible because they affect whether a break opens a website.

An existing combined blocklist can be reviewed as Always blocked and Study before an authenticated split. This preview lists the exact websites and explains the immediate effect of applying it.

Groups uses simple rows with website count, textual state, a native switch, and an edit action. Opening a row reveals its website editor and blocking controls. Group creation and renaming use a labeled inline field, explicit save/cancel, and inline validation. A timer-managed group cannot be deleted or manually toggled; its editable list is a draft for the next cycle.

Garden shows recorded focus minutes, earned trees, partial progress, and a sparse weekly history. One factual explanation covers the earning rule. Avoid slogans, badges, streak pressure, invented time-saved statistics, and punishment for ending early.

## Behavior and verification

Group changes preserve every other applied group's websites and timer, including when another group's editable list contains unapplied changes. Shared domains remain blocked while any active group includes them. One signed approval authorizes the exact focus schedule; the root helper owns subsequent transitions. The menu bar shows the countdown during a cycle.

Verification includes the actual menu bar popover and standalone preview, both appearances, native picker labels, empty and active states, primary actions, group editing, and settings. Preview mode changes no system blocking or preferences. Core and sandbox integration tests cover authorization, group independence, focus phase boundaries, sleep/restart exclusions, and garden persistence.
