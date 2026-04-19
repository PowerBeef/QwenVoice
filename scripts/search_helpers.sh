#!/bin/bash

has_ripgrep() {
    command -v rg >/dev/null 2>&1
}

search_regex_in_file() {
    local pattern="$1"
    local file_path="$2"

    if has_ripgrep; then
        rg -q -- "$pattern" "$file_path"
    else
        grep -Eq -- "$pattern" "$file_path"
    fi
}

search_fixed_in_file() {
    local needle="$1"
    local file_path="$2"

    if has_ripgrep; then
        rg -Fq -- "$needle" "$file_path"
    else
        grep -Fq -- "$needle" "$file_path"
    fi
}
