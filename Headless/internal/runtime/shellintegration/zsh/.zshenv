# Warren shell integration for zsh.
#
# zsh sources this file because the session environment points ZDOTDIR at this
# directory. It restores the user's ZDOTDIR, sources their .zshenv, then reports
# the working directory with OSC 7 and the command lifecycle with OSC 133.
#
# This runs before the user's configuration, so it must not assume aliases,
# functions, or fpath. Every builtin is prefixed to avoid user overrides.

if [[ -n "${WARREN_ZSH_ZDOTDIR+x}" ]]; then
    builtin export ZDOTDIR="$WARREN_ZSH_ZDOTDIR"
    builtin unset WARREN_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    # zsh treats an unset ZDOTDIR as HOME, and so do we.
    builtin typeset _warren_zshenv=${ZDOTDIR-$HOME}/.zshenv
    [[ ! -r "$_warren_zshenv" ]] || builtin source -- "$_warren_zshenv"
} always {
    if [[ -o interactive ]]; then
        __warren_report_cwd() {
            builtin printf '\e]7;file://%s%s\e\\' "${HOST:-localhost}" "$PWD"
        }

        # OSC 133 semantic prompt markers. ghostline reads them to tell whether
        # the shell is waiting for input or running a command, what that command
        # is, and how it exited. The markers are only emitted when the user's own
        # prompt does not already emit them: a second set would interleave with
        # the first and corrupt the input region ghostline captures at 133;C.
        builtin typeset -g __warren_semantic=1

        __warren_foreign_semantic_prompt() {
            # Powerlevel10k emits OSC 133 through its precmd hook unless its
            # terminal integration is explicitly disabled.
            if (( $+functions[p10k] )) && [[ ${POWERLEVEL9K_TERM_SHELL_INTEGRATION:-true} == true ]]; then
                return 0
            fi
            builtin typeset __warren_hook
            for __warren_hook in "${precmd_functions[@]}" "${preexec_functions[@]}"; do
                [[ $__warren_hook == __warren_* ]] && continue
                (( $+functions[$__warren_hook] )) || continue
                [[ ${functions[$__warren_hook]} == *"133;"* ]] && return 0
            done
            return 1
        }

        __warren_prompt_start() {
            builtin typeset -g __warren_status=$?
            if (( ! ${+__warren_semantic_checked} )); then
                builtin typeset -g __warren_semantic_checked=1
                __warren_foreign_semantic_prompt && __warren_semantic=0
                __warren_install_line_init
            fi
            (( __warren_semantic )) || return 0
            if (( ${+__warren_ran} )); then
                builtin printf '\e]133;D;%s\e\\' "$__warren_status"
                builtin unset __warren_ran
            fi
            builtin printf '\e]133;A\e\\'
        }

        __warren_command_start() {
            (( __warren_semantic )) || return 0
            builtin typeset -g __warren_ran=1
            builtin printf '\e]133;C\e\\'
        }

        # 133;B ends the prompt so ghostline's input region starts after it. zle
        # reaches this hook once the prompt is on screen and before any typed
        # text, which is the only point that is exactly the prompt's end.
        __warren_line_init() {
            (( __warren_semantic )) || return 0
            builtin printf '\e]133;B\e\\'
        }

        # The line-init widget is registered at the first prompt, not while
        # .zshenv is sourced: zsh has not initialized the line editor yet at
        # that point, so a widget registered there is silently dropped. The
        # first prompt still precedes the first command, so its 133;B is not
        # missed.
        __warren_install_line_init() {
            (( __warren_semantic )) || return 0
            (( ${+__warren_line_init_installed} )) && return 0
            builtin typeset -g __warren_line_init_installed=1
            # zsh loads the line editor module lazily, and under some terminal
            # definitions (xterm-ghostty among them) it is not loaded yet at the
            # first prompt. add-zle-hook-widget silently declines without it, so
            # load it here rather than lose 133;B for the whole session.
            builtin zmodload zsh/zle 2>/dev/null
            if builtin autoload -Uz add-zle-hook-widget 2>/dev/null && (( $+functions[add-zle-hook-widget] )); then
                add-zle-hook-widget line-init __warren_line_init
                return 0
            fi
            # Without the hook helper, chain whatever zle-line-init already
            # exists so another plugin's widget still runs.
            if (( $+widgets[zle-line-init] )); then
                zle -A zle-line-init __warren_prev_line_init
                zle -N zle-line-init __warren_chained_line_init
            else
                zle -N zle-line-init __warren_line_init
            fi
        }

        __warren_chained_line_init() {
            (( ${+widgets[__warren_prev_line_init]} )) && zle __warren_prev_line_init
            __warren_line_init
        }

        __warren_add_precmd() {
            if builtin autoload -Uz add-zsh-hook 2>/dev/null && (( $+functions[add-zsh-hook] )); then
                add-zsh-hook precmd "$1"
                return 0
            fi
            builtin typeset -ga precmd_functions
            precmd_functions+=("$1")
        }

        __warren_add_preexec() {
            if builtin autoload -Uz add-zsh-hook 2>/dev/null && (( $+functions[add-zsh-hook] )); then
                add-zsh-hook preexec "$1"
                return 0
            fi
            builtin typeset -ga preexec_functions
            preexec_functions+=("$1")
        }

        # The status-capturing hook must run first: a previous hook's own
        # command would otherwise become ``$?`` and every exit code would read 0.
        __warren_add_precmd __warren_prompt_start
        __warren_add_precmd __warren_report_cwd
        __warren_add_preexec __warren_command_start
    fi
    builtin unset _warren_zshenv
}
