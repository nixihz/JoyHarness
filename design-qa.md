# Design QA

- Source visual truth: user-provided General Settings and Controller Mapping screenshots from 2026-08-24.
- Implementation screenshot: `/tmp/joyharness-grouped-mapping-clicked.png`
- Menu interaction screenshot: `/tmp/joyharness-picker-anchor.png`
- Viewport: native macOS Settings window; SwiftUI content frame 620 x 640 pt.
- State: dark appearance, English, controller mapping selected, primary button mappings visible.

## Evidence

- Full view: fixed 170 pt sidebar, content title, grouped form cards, scrollbar, and fixed restore footer align with General Settings.
- Focused mapping region: input labels remain leading-aligned and native menu pickers remain trailing-aligned inside each grouped section.
- Typography: native macOS system font, semantic weights, no negative letter spacing, and no clipped Chinese labels in the captured state.
- Spacing: the title, section headers, grouped cards, row separators, and 54 pt footer use the same native form rhythm as General Settings.
- Colors: system dark materials and semantic separators preserve contrast and adapt to the active/inactive window state.
- Assets: no custom raster assets are required; navigation and reset controls use native SF Symbols.
- Copy: visible Chinese labels and mapping values match application localization and the selected mock.
- Interactions tested: sidebar navigation, mapping list scrolling, and mapping picker opening with the current action checked and aligned to the click position.

## Comparison History

1. The compact table pass used custom borderless menus and a transparent hit target.
2. The transparent target caused unreliable mouse interaction, so the visible label became the actual menu target.
3. User review established General Settings as the preferred visual reference and required the selected option to align with the pointer.
4. The final pass uses the same grouped Form and native menu Picker components as General Settings. No actionable P0, P1, or P2 findings remain.

## Follow-up Polish

- P3: active sidebar selection follows the user's macOS accent color. This is expected native behavior.

final result: passed
