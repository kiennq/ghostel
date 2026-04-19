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

# Outbound `ssh' wrapper.  See etc/ghostel.bash for the full design
# notes — this is the zsh port of the same install-and-cache logic.
if [[ -n "$GHOSTEL_SSH_INSTALL_TERMINFO" ]]; then
    ssh() {
        if [[ -n "$GHOSTEL_SSH_KEEP_TERM" ]] || \
               ! command -v infocmp >/dev/null 2>&1; then
            command ssh "$@"
            return
        fi

        local _user="" _host="" _port="" _k _v
        while IFS=' ' read -r _k _v; do
            case "$_k" in
                user)     _user=$_v ;;
                hostname) _host=$_v ;;
                port)     _port=$_v ;;
            esac
            [[ -n $_user && -n $_host && -n $_port ]] && break
        done < <(command ssh -G "$@" 2>/dev/null)

        if [[ -z $_host ]]; then
            command ssh "$@"
            return
        fi

        local _target="$_user@$_host:$_port"
        local _hash
        _hash=$(infocmp -0 -x xterm-ghostty 2>/dev/null \
                    | cksum 2>/dev/null | awk '{print $1}')
        local _cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ghostel"
        local _cache="$_cache_dir/ssh-terminfo-cache"
        local _key="$_target:$_hash"

        if [[ -r $_cache ]]; then
            if grep -Fxq "$_key ok" "$_cache" 2>/dev/null; then
                TERM=xterm-ghostty command ssh "$@"
                return
            fi
            if grep -Fxq "$_key skip" "$_cache" 2>/dev/null; then
                TERM=xterm-256color command ssh "$@"
                return
            fi
        fi

        local _positional=0 _skip=0 _arg
        for _arg in "$@"; do
            if (( _skip )); then _skip=0; continue; fi
            case "$_arg" in
                -[bcDEeFIiJLlmOoPpQRSWw]) _skip=1 ;;
                -*) ;;
                *) ((_positional++)) ;;
            esac
        done

        if (( _positional > 1 )); then
            TERM=xterm-256color command ssh "$@"
            return
        fi

        command mkdir -p "$_cache_dir" 2>/dev/null
        # Lock keyed on (target, hash) — see etc/ghostel.bash.
        local _lock="$_cache_dir/.lock.$_target.$_hash"
        if ! command mkdir "$_lock" 2>/dev/null; then
            TERM=xterm-256color command ssh "$@"
            return
        fi
        {
            if infocmp -0 -x xterm-ghostty 2>/dev/null \
                    | command ssh "$@" '
                        infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                        command -v tic >/dev/null 2>&1 || exit 1
                        mkdir -p "$HOME/.terminfo" && tic -x - >/dev/null 2>&1
                      ' >/dev/null 2>&1; then
                print -r -- "$_key ok" >> "$_cache"
                TERM=xterm-ghostty command ssh "$@"
            else
                print -r -- "ghostel: failed to install xterm-ghostty terminfo on $_host \
(no \`tic' on remote?), using xterm-256color." >&2
                print -r -- "$_key skip" >> "$_cache"
                TERM=xterm-256color command ssh "$@"
            fi
        } always {
            command rmdir "$_lock" 2>/dev/null
        }
    }
fi

# Call an Emacs Elisp function from the shell.
# Usage: ghostel_cmd FUNCTION [ARGS...]
# The function must be in `ghostel-eval-cmds'.
ghostel_cmd() {
    local payload="" arg
    while (( $# )); do
        arg="${1//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        payload="$payload\"$arg\" "
        shift
    done
    printf '\e]51;E%s\e\\' "$payload"
}
