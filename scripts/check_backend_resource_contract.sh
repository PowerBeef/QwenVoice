#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

    rg -Fq 'path: Sources/Resources/backend' "$PROJECT_YML" || fail "project.yml does not define Sources/Resources/backend as a target resource"
    rg -Fq 'destination: resources' "$PROJECT_YML" || fail "project.yml must copy the backend into the resources destination"
    rg -Fq 'subpath: backend' "$PROJECT_YML" || fail "project.yml must copy the backend into Resources/backend"
    rg -Fq '"backend/**"' "$PROJECT_YML" || fail "project.yml must exclude backend/** from the flattened Sources/Resources resource entry"
    rg -Fq '"server_compat.py"' "$PROJECT_YML" || fail "project.yml must exclude server_compat.py from bundled backend resources"

    rg -q 'dstPath = backend;' "$PBXPROJ" || fail "generated project is missing the backend copy-files subpath"
    if rg -q 'server_compat.py in Resources' "$PBXPROJ" || rg -q 'server_compat.py in CopyFiles' "$PBXPROJ"; then
        fail "generated project must not copy server_compat.py into app resources"
    fi
    if rg -q 'server.py in Resources' "$PBXPROJ"; then
        fail "generated project must not flatten server.py into the top-level resource phase"
    fi
    if rg -q 'mlx_audio_qwen_speed_patch.py in Resources' "$PBXPROJ"; then
        fail "generated project must not flatten backend helper modules into top-level resources"
    fi
}

check_app_bundle() {
    local app_path="$1"
    [ -d "$app_path" ] || fail "app bundle not found: $app_path"

    local resources_dir="$app_path/Contents/Resources"
    local backend_dir="$resources_dir/backend"
    [ -d "$backend_dir" ] || fail "bundled backend directory missing: $backend_dir"

    local backend_file
    for backend_file in "${REQUIRED_BACKEND_FILES[@]}"; do
        [ -f "$backend_dir/$backend_file" ] || fail "bundled backend file missing: $backend_dir/$backend_file"
        if [ -f "$resources_dir/$backend_file" ]; then
            fail "bundled backend file must not be flattened into Contents/Resources: $resources_dir/$backend_file"
        fi
    done

    if [ -f "$backend_dir/server_compat.py" ] || [ -f "$resources_dir/server_compat.py" ]; then
        fail "server_compat.py must not be bundled into the app runtime resources"
    fi
    if find "$backend_dir" \( -type d -name "__pycache__" -o -name "*.pyc" \) -print -quit | grep -q .; then
        fail "compiled Python cache artifacts must not be bundled into the production backend directory"
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
        echo "==> Backend resource contract is clean."
        ;;
    --app-bundle)
        [ $# -eq 2 ] || usage
        check_app_bundle "$2"
        echo "==> Bundled backend resource contract is clean."
        ;;
    *)
        usage
        ;;
esac
