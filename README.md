# QwenVoice

A native macOS text-to-speech application powered by Qwen TTS models. QwenVoice provides a clean SwiftUI interface with a Python backend for high-quality speech synthesis, supporting custom voices, voice design, and voice cloning.

## Features

- **Custom Voice** – Generate speech using pre-built or downloaded voice profiles
- - **Voice Design** – Create voices from a text description
  - - **Voice Cloning** – Enroll your own voice from a reference audio clip
    - - **Model Manager** – Download and manage multiple Qwen TTS models (stored in `~/Library/Application Support/QwenVoice/models/`)
      - - **Generation History** – SQLite-backed history of all generations
        - - **Apple Silicon native** – Optimised for arm64 / macOS 14.0+
         
          - ## Requirements
         
          - - macOS 14.0 or later (Apple Silicon)
            - - Xcode 15+
              - - Python 3.13 (bundled for distribution; dev venv also supported)
                - - [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for regenerating the `.xcodeproj`)
                 
                  - ## Getting Started
                 
                  - ### 1. Clone the repository
                 
                  - ```bash
                    git clone https://github.com/PowerBeef/QwenVoice.git
                    cd QwenVoice
                    ```

                    ### 2. Set up the Python environment (development)

                    ```bash
                    cd Qwen-Voice
                    python3 -m venv .venv
                    source .venv/bin/activate
                    pip install -r requirements.txt
                    ```

                    ### 3. Build and run

                    ```bash
                    # Build
                    xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build

                    # Launch
                    open "/Users/$USER/Library/Developer/Xcode/DerivedData/QwenVoice-*/Build/Products/Debug/Qwen Voice.app"
                    ```

                    Or simply open `QwenVoice.xcodeproj` in Xcode and press **Run**.

                    ### 4. Download a model

                    On first launch, go to the **Models** tab inside the app and download a Qwen TTS model. Models are fetched via `huggingface-cli` and stored at:

                    ```
                    ~/Library/Application Support/QwenVoice/models/
                    ```

                    ## Architecture

                    QwenVoice uses a two-process design:

                    | Layer | Technology | Role |
                    |-------|-----------|------|
                    | Frontend | SwiftUI (Swift 5.9) | UI, navigation, model management |
                    | Backend | Python 3.13 + server.py | ML inference via JSON-RPC 2.0 |
                    | IPC | stdin/stdout pipes | Newline-delimited JSON-RPC messages |
                    | Storage | SQLite via GRDB | Generation history |

                    The Swift frontend spawns `server.py` as a subprocess on launch. All TTS inference (custom voice, voice design, voice cloning) is handled by the Python process and results are streamed back as JSON-RPC responses.

                    ## Project Structure

                    ```
                    QwenVoice/
                    ├── QwenVoice/
                    │   ├── Resources/backend/server.py   # Python JSON-RPC server & ML inference
                    │   ├── Services/PythonBridge.swift   # Swift JSON-RPC client
                    │   ├── Services/DatabaseService.swift# GRDB SQLite history store
                    │   ├── Models/TTSModel.swift         # Model registry & enums
                    │   ├── ViewModels/                   # View models (model manager, etc.)
                    │   └── ContentView.swift             # Root navigation (SidebarItem + NavigationSplitView)
                    ├── QwenVoiceUITests/                 # XCUITest end-to-end tests (58 tests)
                    ├── scripts/
                    │   ├── bundle_python.sh              # Bundle standalone Python for distribution
                    │   ├── regenerate_project.sh         # Safely regenerate .xcodeproj via XcodeGen
                    │   └── run_tests.sh                  # Convenience test runner
                    └── project.yml                       # XcodeGen configuration
                    ```

                    ## Testing

                    All 58 UI tests run without requiring downloaded models (model-dependent tests use `XCTSkip`).

                    ```bash
                    # Run all UI tests
                    ./scripts/run_tests.sh

                    # Run a single test class
                    ./scripts/run_tests.sh SidebarNavigation

                    # List available test classes
                    ./scripts/run_tests.sh --list
                    ```

                    Test coverage spans: sidebar navigation, custom voice, voice design, voice cloning, models, history, voices, preferences, generation flow, and debug views.

                    ## Distribution

                    To bundle a self-contained Python environment for distribution:

                    ```bash
                    ./scripts/bundle_python.sh
                    ```

                    This packages a standalone Python 3.13 runtime into `QwenVoice/Resources/python/`, which the app uses automatically in production builds.

                    ## License

                    See [LICENSE](LICENSE) for details.
