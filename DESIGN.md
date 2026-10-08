# Interface direction

Reading this as a refinement of a native macOS menu bar utility for personal website blocking, with a calm, compact language based on SwiftUI and AppKit controls.

Design-taste settings: DESIGN_VARIANCE 3, MOTION_INTENSITY 1, VISUAL_DENSITY 5. Low variance keeps controls predictable; motion is limited to pressed feedback; moderate density keeps the website editor and blocking control visible in a small popover.

The initial interface used a large rounded wordmark, a mint status card with slogan copy, repeated globe icons, and a tagline footer. The logo and green accent remain. The large status card, slogans, uppercase badge, repeated icons, and tagline are removed. Status now reports whether blocking is on and how many websites it covers.

Use the system sans serif, rounded type only for the established wordmark, and monospaced digits for changing numbers. Keep one green accent on neutral system surfaces. Lists and the primary button use an 8-point radius; input controls use the native macOS radius. Separate header, editor, and actions according to their function.

The status-item popover and SwiftUI root have a concrete, screen-bounded height. The website list is the main workspace and the only scrolling region on the main panel. The add field stays below the list. Duration and Start blocking / Stop blocking form a fixed control area below it. A single duration picker combines Always on and the timed choices. Blocking state is reported in the header; the remaining time stays beside Stop blocking. Settings replace the editor and provide an explicit Back control.

Invalid websites report errors beside the add field; administrator failures report errors beside the blocking action; login-item failures report errors beside the login setting. Pending edits explicitly say they have not been applied. Native Edit menu commands support paste, copy, selection, and undo in the accessory app.

Verification must include the actual menu bar popover in both appearances, not only the standalone preview window. The --demo --menu-preview flags exercise that popover without modifying network settings.
