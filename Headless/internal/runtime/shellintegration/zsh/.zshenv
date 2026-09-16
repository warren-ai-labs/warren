# Warren shell integration for zsh.
#
# zsh sources this file because the session environment points ZDOTDIR at this
# directory. It restores the user's ZDOTDIR, sources their .zshenv, then reports
# the working directory with OSC 7 before every prompt.
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
        if builtin autoload -Uz add-zsh-hook 2>/dev/null && (( $+functions[add-zsh-hook] )); then
            add-zsh-hook precmd __warren_report_cwd
        else
            builtin typeset -ga precmd_functions
            precmd_functions+=(__warren_report_cwd)
        fi
    fi
    builtin unset _warren_zshenv
}
