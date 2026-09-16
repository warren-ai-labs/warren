# Warren shell integration for fish.
#
# fish sources vendor_conf.d snippets from XDG_DATA_DIRS. This reports the
# working directory with OSC 7 before every prompt, then removes the
# integration directory from XDG_DATA_DIRS so child processes do not inherit it.

function __warren_report_cwd --on-event fish_prompt
    printf '\e]7;file://%s%s\e\\' (hostname) $PWD
end

if set -q WARREN_SHELL_INTEGRATION_DIR
    set -l warren_dirs
    for dir in $XDG_DATA_DIRS
        if test "$dir" != "$WARREN_SHELL_INTEGRATION_DIR"
            set -a warren_dirs $dir
        end
    end
    set -gx XDG_DATA_DIRS $warren_dirs
    set -e WARREN_SHELL_INTEGRATION_DIR
end
