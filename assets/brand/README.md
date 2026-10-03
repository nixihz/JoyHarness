# Joy Harness Brand Assets

- `joy-harness-logo-concept-v5.png` is the retained high-resolution logo master.
- `joy-harness-logo-readme.png` is the tightly cropped README presentation asset.
- `joy-harness-app-icon-v5.png` is the 1024 x 1024 PNG export.
- `Sources/JoyHarness/Resources/JoyHarness.icns` is the generated macOS app icon used by packaged builds.

These files stay outside `Sources/JoyHarness/Resources` so they are not copied into the app bundle.

Regenerate the app icon after changing the master:

```bash
./scripts/generate_app_icon.sh
```
