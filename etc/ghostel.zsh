# Ghostel shell integration for zsh
# Source this from your .zshrc:
#   [[ "$INSIDE_EMACS" = 'ghostel' ]] && source /path/to/ghostel/etc/ghostel.zsh

# Idempotency guard — skip if already loaded (e.g. auto-injected).
(( $+functions[__ghostel_osc7] )) && return

# Report working directory to the terminal via OSC 7
__ghostel_osc7() {
    printf '\e]7;file://%s%s\e\\' "$HOST" "$PWD"
}

# --- Semantic prompt markers (OSC 133) ---

__ghostel_save_status() {
    __ghostel_last_status="$?"
}

# Emit "command finished" (D) + "prompt start" (A).
__ghostel_prompt_start() {
    if [[ -n "$__ghostel_prompt_shown" ]]; then
        printf '\e]133;D;%s\e\\' "$__ghostel_last_status"
    fi
    printf '\e]133;A\e\\'
}

# Emit "prompt end / command start" (B).
__ghostel_prompt_end() {
    printf '\e]133;B\e\\'
    __ghostel_prompt_shown=1
}

# Emit "command output start" (C).
__ghostel_preexec() {
    printf '\e]133;C\e\\'
}

precmd_functions=(__ghostel_save_status __ghostel_prompt_start __ghostel_osc7 "${precmd_functions[@]}" __ghostel_prompt_end)
preexec_functions=(__ghostel_preexec "${preexec_functions[@]}")
