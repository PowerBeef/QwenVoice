#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/search_helpers.sh"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_YML="$PROJECT_DIR/project.yml"
PBXPROJ="$PROJECT_DIR/QwenVoice.xcodeproj/project.pbxproj"
REPO_BACKEND_DIR="$PROJECT_DIR/Sources/Resources/backend"

REQUIRED_BACKEND_FILES=(
    "server.py"
    "audio_io.py"
    "backend_state.py"
    "clone_context.py"
    "generation_pipeline.py"
    "output_paths.py"
    "rpc_handlers.py"
    "rpc_transport.py"
    "mlx_audio_qwen_speed_patch.py"
)

fail() {
    echo "error: $*" >&2
    exit 1
}

check_repo_source_files() {
    [ -d "$REPO_BACKEND_DIR" ] || fail "missing repo backend directory: $REPO_BACKEND_DIR"

    local backend_file
    for backend_file in "${REQUIRED_BACKEND_FILES[@]}"; do
        [ -f "$REPO_BACKEND_DIR/$backend_file" ] || fail "missing backend source file: Sources/Resources/backend/$backend_file"
    done

    [ -f "$REPO_BACKEND_DIR/server_compat.py" ] || fail "missing harness compatibility file: Sources/Resources/backend/server_compat.py"
}

check_project_metadata() {
    [ -f "$PROJECT_YML" ] || fail "missing project.yml at $PROJECT_YML"
    [ -f "$PBXPROJ" ] || fail "missing generated project at $PBXPROJ"

    search_fixed_in_file '"backend/**"' "$PROJECT_YML" || fail "project.yml must exclude backend/** from the flattened Sources/Resources resource entry"
    if search_fixed_in_file 'path: Sources/Resources/backend' "$PROJECT_YML"; then
        fail "project.yml must not bundle Sources/Resources/backend into shipped app resources"
    fi
    if search_fixed_in_file 'subpath: backend' "$PROJECT_YML"; then
        fail "project.yml must not copy production backend sources into Resources/backend"
    fi
    if search_regex_in_file 'dstPath = backend;' "$PBXPROJ"; then
        fail "generated project must not include a backend copy-files phase"
    fi
    if search_regex_in_file 'server_compat.py in Resources' "$PBXPROJ" || search_regex_in_file 'server_compat.py in CopyFiles' "$PBXPROJ"; then
        fail "generated project must not copy server_compat.py into app resources"
    fi
    if search_regex_in_file 'server.py in Resources' "$PBXPROJ" || search_regex_in_file 'server.py in CopyFiles' "$PBXPROJ"; then
        fail "generated project must not bundle server.py into the app"
    fi
    if search_regex_in_file 'mlx_audio_qwen_speed_patch.py in Resources' "$PBXPROJ" || search_regex_in_file 'mlx_audio_qwen_speed_patch.py in CopyFiles' "$PBXPROJ"; then
        fail "generated project must not bundle backend helper modules into the app"
    fi
}

check_app_bundle() {
    local app_path="$1"
    [ -d "$app_path" ] || fail "app bundle not found: $app_path"

    local resources_dir="$app_path/Contents/Resources"
    local backend_dir="$resources_dir/backend"
    [ ! -e "$backend_dir" ] || fail "bundled backend directory must be absent: $backend_dir"
    [ ! -e "$resources_dir/python" ] || fail "bundled Python runtime must be absent: $resources_dir/python"
    [ ! -e "$resources_dir/ffmpeg" ] || fail "bundled ffmpeg must be absent: $resources_dir/ffmpeg"

    local backend_file
    for backend_file in "${REQUIRED_BACKEND_FILES[@]}" "server_compat.py"; do
        if [ -e "$resources_dir/$backend_file" ]; then
            fail "backend source file must not be bundled into Contents/Resources: $resources_dir/$backend_file"
        fi
    done

    if find "$resources_dir" \( -type d -name "__pycache__" -o -name "*.pyc" -o -name "*.whl" \) -print -quit | grep -q .; then
        fail "Python runtime artifacts must not be bundled into the native app resources"
    fi
}

usage() {
    cat >&2 <<'EOF'
Usage:
  ./scripts/check_backend_resource_contract.sh --project
  ./scripts/check_backend_resource_contract.sh --app-bundle /path/to/QwenVoice.app
EOF
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

case "$1" in
    --project)
        [ $# -eq 1 ] || usage
        check_repo_source_files
        check_project_metadata
        echo "==> Native app resource contract is clean."
        ;;
    --app-bundle)
        [ $# -eq 2 ] || usage
        check_app_bundle "$2"
        echo "==> Native app bundle resource contract is clean."
        ;;
    *)
        usage
        ;;
esac
