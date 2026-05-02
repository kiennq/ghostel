# Ghostel shell integration for zsh
# Source this from your .zshrc.
#
# The `${var-}' fallback inside the trim is for users with `setopt
# nounset' — zsh errors on `${unset%%pat}' without it (bash doesn't).
#
# Local `~/.zshrc' (prefix match — TRAMP appends `,tramp:VER'):
#   [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' ]] && source /path/to/ghostel/etc/shell/ghostel.zsh
#
# Remote `~/.zshrc' (also gates on TERM, since ssh propagates it
# natively and INSIDE_EMACS does not without server-side AcceptEnv):
#   if [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
#       source ~/.local/share/ghostel/ghostel.zsh
#   fi
# See the README "Manual setup" section for the full rationale.

# Idempotency guard — skip if already loaded (e.g. auto-injected).
(( $+functions[__ghostel_osc7] )) && return

# Report working directory to the terminal via OSC 7
__ghostel_osc7() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    builtin printf '\e]7;file://%s%s\e\\' "$HOST" "$PWD"
}

# --- Semantic prompt markers (OSC 133) ---

# Capture $? from the just-finished command.  Must run before any other
# precmd that resets $?, hence prepended at the head of `precmd_functions'.
__ghostel_save_status() {
    # Capture $? FIRST: `emulate -L' below resets it to 0.
    # `$status' is a read-only zsh special parameter (synonym for $?), so
    # use a different name for the local copy.
    builtin local cmd_status=$?
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    __ghostel_last_status=$cmd_status
}

# Emit "command finished" (D) for the previous command.
# 133;A and 133;B are embedded in PROMPT itself (see `__ghostel_ensure_prompt_wrap'
# below) so they fire in lockstep with prompt rendering, including
# readline-style redraws — emitting them from precmd here would only
# fire once and leave any subsequent redraw outside the PROMPT scope.
__ghostel_prompt_start() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    if [[ -n "$__ghostel_prompt_shown" ]]; then
        builtin printf '\e]133;D;%s\e\\' "$__ghostel_last_status"
    fi
    __ghostel_prompt_shown=1
}

# Restore the unmarked PROMPT (mirror of the restore-on-precmd logic in
# `__ghostel_ensure_prompt_wrap') and emit "command output start" (C).
# Restoring before later preexec hooks run keeps themes that pattern-match
# `$PROMPT' (e.g. Pure) from seeing our OSC sequences.
__ghostel_preexec() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    if [[ -n ${__ghostel_marked_prompt+x} && "$PROMPT" == "$__ghostel_marked_prompt" ]]; then
        PROMPT=$__ghostel_saved_prompt
    fi
    builtin printf '\e]133;C\e\\'
}

# Wrap PROMPT with 133;A at the start and 133;B at the end so they fire
# in lockstep with prompt rendering, including any redraws. %{ %} mark
# the OSC sequence as zero-width for line-wrap. $'...' is ANSI-C quoting:
# \e is ESC, \\ is a single backslash — so \e\\ is ESC \ (ST).
#
# Re-wrap from precmd: a `.zshrc' or prompt theme loaded after this file
# (oh-my-zsh, powerlevel10k, starship, prompt_*) commonly reassigns
# PROMPT and strips our wrap.  Each cycle:
#   1. If $PROMPT matches our last marked snapshot, nobody touched it —
#      restore to the saved unmarked version before re-marking.  Avoids
#      exposing markers to other hooks (themes like Pure pattern-match
#      $PROMPT to strip/rebuild and break if they see our markers).
#   2. Otherwise treat $PROMPT as a new clean baseline (theme rebuild,
#      async update).  Skip wrapping if it already contains our marker
#      (defensive: theme copied a marked PROMPT somewhere).
#   3. Reposition to the end of `precmd_functions' so we run after any
#      precmd added later (themes that rebuild PROMPT each prompt, e.g.
#      p10k's `_p9k_precmd').  One-prompt warmup is the trade-off.
__ghostel_ensure_prompt_wrap() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    if [[ -n ${__ghostel_marked_prompt+x} && "$PROMPT" == "$__ghostel_marked_prompt" ]]; then
        PROMPT=$__ghostel_saved_prompt
    fi
    if [[ "$PROMPT" != *$'%{\e]133;A'* ]]; then
        __ghostel_saved_prompt=$PROMPT
        # If $PROMPT ends with an unpaired `%', appending our `%{...%}'
        # markers turns the user's `%' + our `%{' into a single `%{'
        # prompt escape, swallowing the marker.  Double the trailing `%'
        # to make it a literal percent.
        [[ $PROMPT == *[^%]% || $PROMPT == % ]] && PROMPT=$PROMPT%
        PROMPT=$'%{\e]133;A\e\\%}'"$PROMPT"$'%{\e]133;B\e\\%}'
        __ghostel_marked_prompt=$PROMPT
    fi
    if [[ ${precmd_functions[-1]} != __ghostel_ensure_prompt_wrap ]]; then
        precmd_functions=(${precmd_functions:#__ghostel_ensure_prompt_wrap})
        precmd_functions+=(__ghostel_ensure_prompt_wrap)
    fi
}

# ZLE line-init fallback: if $PROMPT lost its markers between precmd and
# this redraw (e.g. an async theme update via `zle -F' reassigned
# $PROMPT then triggered `zle reset-prompt' without re-firing precmd),
# emit 133;A + 133;B directly so libghostty still tags the input span —
# the link-skip logic in the renderer relies on `ghostel-input' cells.
# Side-effect: this can create duplicate `ghostel--prompt-positions'
# entries during heavy async updates; navigation steps may be no-ops on
# those cycles.  Acceptable trade-off vs. the link-skip false positive.
__ghostel_zle_line_init_hook() {
    [[ "$PROMPT" != *$'%{\e]133;A'* ]] && \
        printf '\e]133;A\e\\\e]133;B\e\\'
}

# One-shot installer: registered as a precmd, runs once on the first
# prompt fire (after `.zshrc' has finished and any user/theme
# `zle-line-init' widget is in place).  Chains our hook to whatever
# existing widget is registered, then removes itself from precmd_functions.
#
# Mirrors ghostty's zsh integration:
#   - If the widget is already managed by `add-zle-hook-widget'
#     (oh-my-zsh, prezto and others wrap zle-line-init this way),
#     register through that framework instead of overwriting — blindly
#     rebinding the widget detaches the framework's dispatcher chain.
#   - Otherwise, save any existing widget under a leading-dot name (works
#     around zsh-syntax-highlighting bugs) and append a tail invocation
#     of the original to our hook function's body so it still runs after
#     us.  `flag' picks `-N' vs. `-Nw' — the former preserves $WIDGET
#     for user-defined widgets, the latter is needed for builtins.
__ghostel_install_zle_hook() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    builtin local hook=line-init
    builtin local func=__ghostel_zle_line_init_hook
    builtin local widget=zle-$hook
    builtin local orig_widget flag
    if [[ ${widgets[$widget]} == user:azhw:* ]] && \
           (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget $hook $func
    else
        if (( $+widgets[$widget] )); then
            orig_widget=._ghostel_orig_$widget
            builtin zle -A $widget $orig_widget
            if [[ ${widgets[$widget]} == user:* ]]; then
                flag=
            else
                flag=w
            fi
            functions[$func]+="
                builtin zle $orig_widget -N$flag -- \"\$@\""
        fi
        builtin zle -N $widget $func
    fi
    precmd_functions=(${precmd_functions:#__ghostel_install_zle_hook})
}

precmd_functions=(__ghostel_save_status __ghostel_prompt_start __ghostel_osc7 "${precmd_functions[@]}")
precmd_functions+=(__ghostel_ensure_prompt_wrap __ghostel_install_zle_hook)
preexec_functions=(__ghostel_preexec "${preexec_functions[@]}")

# Outbound `ssh' wrapper.  See etc/ghostel.bash for the full design
# notes — this is the zsh port of the same install-and-cache logic.
if [[ -n "$GHOSTEL_SSH_INSTALL_TERMINFO" ]]; then
    # `function NAME { … }' rather than `NAME() { … }' so a user alias
    # on `ssh' (aliases expand at parse time in zsh, and bash when the
    # alias is already active while sourcing this file) can't turn the
    # definition into a parse error.
    function ssh {
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
