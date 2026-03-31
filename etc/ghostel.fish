# Ghostel shell integration for fish
# Source this from your config.fish:
#   test "$INSIDE_EMACS" = 'ghostel'; and source /path/to/ghostel/etc/ghostel.fish

# Idempotency guard — skip if already loaded (e.g. auto-injected).
functions -q __ghostel_osc7; and return

# Report working directory to the terminal via OSC 7
function __ghostel_osc7 --on-event fish_prompt
    printf '\e]7;file://%s%s\e\\' (hostname) "$PWD"
end

# --- Semantic prompt markers (OSC 133) ---

set -g __ghostel_prompt_shown 0

function __ghostel_postexec --on-event fish_postexec
    set -g __ghostel_last_status $status
end

# Emit "command finished" (D) + "prompt start" (A) before the prompt.
function __ghostel_prompt_start --on-event fish_prompt
    if test "$__ghostel_prompt_shown" = 1
        printf '\e]133;D;%s\e\\' "$__ghostel_last_status"
    end
    printf '\e]133;A\e\\'
end

# Emit "prompt end / command start" (B) after the prompt.
function __ghostel_prompt_end --on-event fish_prompt
    printf '\e]133;B\e\\'
    set -g __ghostel_prompt_shown 1
end

# Emit "command output start" (C) before command runs.
function __ghostel_preexec --on-event fish_preexec
    printf '\e]133;C\e\\'
end
