# TranslateAnywhere

A macOS menu-bar application that translates between Russian and English via a global hotkey. Select text in any application, press the hotkey, and TranslateAnywhere either replaces the selected text (editable fields) or shows a small popup with the translation (non-editable selections).

TranslateAnywhere runs local models through CTranslate2 (OPUS and NLLB options) with an optional Ollama backend for LLM-based translation. Local model files are downloaded on demand and are not bundled into the `.app` or `.dmg`.

## Features

- **High-accuracy local model options** -- Choose between OPUS Base, OPUS Big, NLLB 1.3B, and NLLB 3.3B for EN<->RU translation quality/resource tradeoffs.
- **On-demand model downloads** -- Install models from the menu (`Models > Downloads`) or via first-run prompt; model weights are stored in `~/Library/Application Support/TranslateAnywhere/models/`.
- **Private Hugging Face auth** -- Configure a Hugging Face read token from `Models > Configure Hugging Face Token…`; token is stored in macOS Keychain.
- **Configurable global hotkey** -- Default Ctrl+Option+T. Change it to any combination that includes Control or Command.
- **Context-aware output** -- In editable text inputs, the selected text is replaced in-place via simulated Cmd+V. In non-editable contexts (e.g., selected webpage text), translation appears in a small popup near the cursor.
- **Auto-detect direction** -- Automatically determines whether the selected text is Russian or English and translates in the correct direction.
- **Ollama backend option** -- Switch to an Ollama-powered LLM backend for translation when preferred.
- **Clipboard preservation** -- Saves and restores your clipboard contents around the capture/replace cycle.
- **Accessibility API fallback** -- Falls back to the macOS Accessibility API when clipboard-based text capture is unavailable (secure input mode, non-standard text fields).
- **Lower-latency hotkey pipeline** -- Reduced capture/paste wait overhead, startup model warmup, and CPU thread auto-tuning improve responsiveness while preserving translation quality settings.

## Requirements

| Requirement | Version |
|---|---|
| macOS | 15.0 (Sequoia) or later |
| Xcode | 15.0 or later |
| Rust toolchain | stable (Homebrew `rust` or rustup) |
| Python 3 | 3.9+ (for model conversion via CTranslate2 Python package) |
| CMake | 3.18+ (for building CTranslate2 and SentencePiece) |
| Disk space | ~600 MB to ~7 GB depending on installed local models |

> **Note:** Universal2 (arm64 + x86_64) builds require a rustup-managed Rust toolchain with both targets installed. Homebrew Rust builds for the host architecture only.

## Quick Start

```bash
# Clone the repository with submodules
git clone --recursive https://github.com/grantr-code/TranslateAnywhere.git
cd TranslateAnywhere

# Run the full development setup (installs deps, builds everything)
./scripts/dev_setup.sh

# Open in Xcode and run
open App/TranslateAnywhere.xcodeproj
```

## Build Scripts

### `scripts/dev_setup.sh`

The all-in-one development setup script. It performs the following steps in order:

1. **Checks dependencies** -- Verifies that `cmake`, `python3`, `rustc`, and `cargo` are installed. Installs missing tools via Homebrew or rustup.
2. **Initializes git submodules** -- Clones CTranslate2 and SentencePiece into `ThirdParty/` if not already present.
3. **Builds third-party libraries** -- Runs `build_thirdparty_universal.sh` to compile CTranslate2 and SentencePiece as static libraries.
4. **Builds the Rust core** -- Runs `build_core_universal.sh` to compile `translator_core` as a static library.
5. **Builds the Xcode project** -- Runs `xcodebuild` in Debug configuration.

```bash
./scripts/dev_setup.sh
```

### `scripts/build_thirdparty_universal.sh`

Compiles CTranslate2 and SentencePiece from source, then merges the resulting static libraries with `lipo` into universal binaries under `ThirdParty/build/lib/`.

```bash
./scripts/build_thirdparty_universal.sh
```

### `scripts/fetch_and_convert_models.sh`

Legacy helper script for local development to build OPUS artifacts in `models/`. The app itself now downloads runtime models into Application Support and does not read bundled model files.

```bash
./scripts/fetch_and_convert_models.sh
```

### `scripts/build_core_universal.sh`

Compiles the Rust `translator_core` crate as a static library (`staticlib`) and places it at `build/lib/libtranslator_core.a`.

```bash
./scripts/build_core_universal.sh
```

### `scripts/package.sh`

Packages the built application into a distributable `.dmg` disk image in the `dist/` directory. The script asserts that no `Contents/Resources/models` directory exists in the app bundle.

```bash
./scripts/package.sh
```

### `scripts/build_model_artifacts.sh`

Builds runtime-downloadable model artifacts (OPUS base/big and NLLB 1.3B/3.3B) and generates `manifest-v1.json` with SHA-256 checksums.

```bash
./scripts/build_model_artifacts.sh
```

### `scripts/verify_model_artifacts.sh`

Validates artifact files against checksums in `manifest-v1.json`.

```bash
./scripts/verify_model_artifacts.sh dist/model-artifacts
```

### `manifests/manifest-v1.json`

Published runtime manifest consumed by the app. It currently references external Hugging Face model repositories (OPUS and NLLB CT2 assets) with per-file SHA-256 checksums and sizes.

## Architecture

```
+-------------------+
|   macOS Menu Bar  |
|   (NSMenu)        |
+--------+----------+
         |
+--------v----------+       +---------------------+
| TranslatorService  |------>| Ollama HTTP Backend |
| (Swift)            |       | (optional)          |
+--------+----------+       +---------------------+
         |
         | C ABI (tc_init, tc_translate, tc_free_buffer, tc_is_russian)
         |
+--------v----------+
| translator_core    |
| (Rust staticlib)   |
+--------+----------+
         |
         | extern "C" FFI (cpp_translate, cpp_free_string)
         |
+--------v----------+
| ctranslate2_wrapper|
| (C++ wrapper)      |
+--------+----------+
         |
    +----+----+
    |         |
+---v---+ +---v----------+
|CTranslate2| |SentencePiece|
|(C++ lib)   | |(C++ lib)    |
+------------+ +-------------+
```

**Data flow for a translation request:**

1. User presses the global hotkey (Carbon `RegisterEventHotKey`).
2. `SelectionCapture` reads selected text via simulated Cmd+C or Accessibility API fallback.
3. `TranslatorService` calls through the C ABI into the Rust `translator_core` static library.
4. Rust resolves auto-detect direction via `tc_is_russian` (Cyrillic character ratio analysis).
5. Rust calls into the C++ wrapper (`cpp_translate`), which loads the selected model family (OPUS or NLLB) and runs SentencePiece tokenization + CTranslate2 inference.
6. The translated UTF-8 string is returned back up through the C ABI.
7. If the focused context is editable, `SelectionCapture` replaces the selected text in-place via simulated Cmd+V. Otherwise, a transient popup is shown near the cursor with the translated text.

## Repository Layout

```
TranslateAnywhere/
├── App/
│   ├── TranslateAnywhere/
│   │   ├── AccessibilityHelper.swift   # AX API fallback for text capture
│   │   ├── AppDelegate.swift           # App lifecycle and hotkey dispatch
│   │   ├── ClipboardManager.swift      # Save/restore system clipboard
│   │   ├── Contracts.swift             # Shared enums, UserDefaults keys, constants
│   │   ├── HotkeyManager.swift         # Carbon global hotkey registration
│   │   ├── Info.plist                  # App bundle configuration
│   │   ├── main.swift                  # App entry point
│   │   ├── MenuManager.swift           # Status bar menu
│   │   ├── ModelStoreManager.swift     # Runtime model install/download manager
│   │   ├── SelectionCapture.swift      # Text capture via Cmd+C / AX fallback
│   │   ├── SettingsManager.swift       # UserDefaults wrapper singleton
│   │   ├── TranslateAnywhere.entitlements
│   │   └── TranslatorService.swift     # Swift bridge to Rust C ABI + Ollama
│   └── TranslateAnywhere.xcodeproj/
├── Core/
│   ├── native/
│   │   ├── ctranslate2_wrapper.cpp     # C++ CTranslate2 + SentencePiece wrapper
│   │   └── ctranslate2_wrapper.h       # C-callable header
│   └── translator_core/
│       ├── Cargo.toml                  # Rust crate manifest (staticlib)
│       ├── include/
│       │   └── translator_core.h       # Public C ABI header
│       └── src/
│           ├── lib.rs                  # Exported C ABI functions
│           └── translator.rs           # Internal CTranslate2 FFI bridge
├── LICENSES/
│   ├── MIT.txt                         # MIT License
│   ├── APACHE-2.0.txt                  # Apache License 2.0
│   ├── CC-BY-4.0.txt                   # Creative Commons Attribution 4.0
│   └── THIRD-PARTY.md                  # Third-party attribution
├── ThirdParty/                         # Git submodules (CTranslate2, sentencepiece)
├── scripts/
│   ├── dev_setup.sh                    # Full development environment setup
│   ├── build_thirdparty_universal.sh   # Build CTranslate2 + SentencePiece
│   ├── fetch_and_convert_models.sh     # Download and convert OPUS-MT models
│   ├── build_model_artifacts.sh        # Build downloadable model artifacts + manifest
│   ├── verify_model_artifacts.sh       # Verify artifact checksums from manifest
│   ├── build_core_universal.sh         # Build Rust staticlib
│   └── package.sh                      # Package app into .dmg
├── build/                              # Build output (gitignored)
├── dist/                               # Distributable .dmg output
├── models/                             # Optional local conversion output (legacy helper path)
├── .gitignore
└── README.md
```

## Verification

### Run Rust unit and integration tests

```bash
# Language detection tests (no models required)
cargo test --manifest-path Core/translator_core/Cargo.toml

# Translation tests (requires models to be present)
MODELS_DIR=/path/to/models cargo test --manifest-path Core/translator_core/Cargo.toml -- --ignored
```

### Smoke test

1. Build and run the app from Xcode (Cmd+R).
2. If prompted, install the default local model (NLLB 1.3B) from the one-click first-run dialog.
3. Grant Accessibility and Input Monitoring permissions when prompted.
4. Open any text editor and type "Hello, how are you?"
5. Select the text and press Ctrl+Option+T.
6. Verify that the text is replaced with a Russian translation.
7. Select the Russian text, press the hotkey again, and verify it is replaced with English.
8. Select non-editable text in a webpage (or other read-only UI) and press the hotkey; verify a small popup appears near the cursor with the translation.

## Configuration

All settings are accessible from the menu bar icon's dropdown menu.

### Menu Bar Options

| Option | Description | Default |
|---|---|---|
| Direction | Auto Detect / EN->RU / RU->EN | Auto Detect |
| Backend | Local / Ollama | Local |
| Active local model | OPUS Base / OPUS Big / NLLB 1.3B / NLLB 3.3B | NLLB 1.3B |
| Model downloads | Install one model or Download All from `Models > Downloads` | N/A |
| Hugging Face token | Configure/clear private artifact repo access in `Models` submenu | Not set |
| Restore clipboard | Restore original clipboard after capture/replace | On |
| Hotkey | The global keyboard shortcut to trigger translation | Ctrl+Option+T |
| Ollama endpoint | HTTP endpoint for the Ollama server | http://localhost:11434 |
| Ollama model | Model name for the Ollama backend | llama3 |

### UserDefaults Keys

| Key | Type | Description |
|---|---|---|
| `hotkeyKeyCode` | UInt32 | Carbon virtual key code |
| `hotkeyModifiers` | UInt32 | Carbon modifier mask |
| `direction` | Int | TranslateDirection raw value (0, 1, or 2) |
| `backend` | String | "local" or "ollama" |
| `restoreClipboard` | Bool | Restore clipboard after capture |
| `maxInputChars` | Int | Character limit for input text |
| `ollamaEndpoint` | String | Ollama server URL |
| `ollamaModel` | String | Ollama model identifier |
| `localModelId` | String | Selected local model id (`opus_base`, `opus_big`, `nllb_1_3b`, `nllb_3_3b`) |

## Permissions

TranslateAnywhere requires two macOS permissions to function:

### Accessibility

Required to read selected text from other applications via the Accessibility API (used as a fallback when clipboard capture fails). The app will prompt you on first launch. You can also grant it manually:

**System Settings > Privacy & Security > Accessibility > TranslateAnywhere**

### Input Monitoring

Required to register the global hotkey and simulate keyboard events (Cmd+C for capture, Cmd+V for paste). The app will prompt you on first launch. You can also grant it manually:

**System Settings > Privacy & Security > Input Monitoring > TranslateAnywhere**

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Ctrl+Option+T (default) | Trigger translation of selected text |

The trigger hotkey can be changed to any combination that includes at least Control or Command as a modifier.

## Edge Cases Handled

1. **Empty selection** -- If no text is selected when the hotkey is pressed, translation is skipped and a system beep is played.
2. **Secure input mode** -- When macOS secure input is active (e.g., password fields), the app skips clipboard capture entirely and uses only the Accessibility API fallback, which correctly refuses to read secure text fields.
3. **Clipboard preservation** -- The user's clipboard contents (including images, RTF, and file references -- not just plain text) are saved before capture and restored afterward when the "Restore clipboard" preference is enabled.
4. **Mutex poisoning recovery** -- If the translation thread panics, the Rust mutex is recovered via `poisoned.into_inner()` rather than propagating the panic.
5. **Null pointer safety** -- `tc_free_buffer` is safe to call with a null pointer. All C ABI entry points validate input pointers before dereferencing.
6. **Re-initialization replaces active model** -- Calling `tc_init` again swaps the active local model and clears C++ model caches.
7. **Hotkey registration fallback** -- If the user's configured hotkey cannot be registered (e.g., conflict with another app), the app falls back to Ctrl+Option+T and shows a warning alert.
8. **Modifier validation** -- Hotkey combinations that do not include Control or Command are rejected to avoid accidental triggers.
9. **Non-alphabetic input** -- Strings containing only numbers, punctuation, or whitespace are classified as non-Russian (returns 0 from `tc_is_russian`), which defaults to EN->RU translation direction.
10. **Large input truncation** -- Input is capped at `maxInputChars` (default 8000) to prevent excessive memory usage and long translation times.

## Troubleshooting

### "Hotkey does not work"

- Verify that Input Monitoring permission is granted in System Settings > Privacy & Security > Input Monitoring.
- Check if another application has registered the same hotkey combination. Try changing the hotkey in TranslateAnywhere settings.
- If the hotkey still fails, the app will fall back to Ctrl+Option+T and display a warning dialog.

### "No text is captured"

- Verify that Accessibility permission is granted in System Settings > Privacy & Security > Accessibility.
- Some applications block programmatic Cmd+C. The app will try the Accessibility API fallback automatically.
- Password fields (secure text fields) are intentionally excluded from text capture.

### "Translation returns empty or fails"

- Open the menu and check `Models > Active Model` and `Models > Downloads` status.
- Install or re-install the selected model from `Models > Downloads`.
- Verify model files exist under `~/Library/Application Support/TranslateAnywhere/models/<model-id>/`.
- If using private artifacts, configure a token in `Models > Configure Hugging Face Token…`.
- Look for error messages in Console.app by filtering for "com.translateanywhere.app".

### "App does not appear in menu bar"

- TranslateAnywhere is an LSUIElement app (no Dock icon). Look for its icon in the macOS menu bar.
- If the app crashes on launch, check Console.app for crash reports.

### "Ollama backend not working"

- Verify that Ollama is running and accessible at the configured endpoint (default: `http://localhost:11434`).
- Ensure the configured model (default: `llama3`) is pulled and available in Ollama.
- Check Console.app logs for HTTP error details.

### Build failures

- CTranslate2 and SentencePiece require CMake 3.18+. Install via `brew install cmake`.
- If `build_thirdparty_universal.sh` fails, try deleting `ThirdParty/build/` and re-running.
- For universal2 builds, install both targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.

## License

This project is licensed under the MIT License. See [LICENSES/MIT.txt](LICENSES/MIT.txt) for the full text.

Third-party components are used under their respective licenses. See [LICENSES/THIRD-PARTY.md](LICENSES/THIRD-PARTY.md) for complete attribution and license details.
