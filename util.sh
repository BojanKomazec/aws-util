#!/usr/bin/env bash
# shellcheck disable=SC1090

show_menu_select_message() {
    local menu_name=$1
    echo >&2
    log_prompt "[$menu_name] Please select an option:"
}

run_and_log() {
    log_wait "Executing command: $*"
    "$@"
}
