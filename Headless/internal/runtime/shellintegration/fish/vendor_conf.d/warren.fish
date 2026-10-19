# Warren shell integration for fish.
#
# fish sources vendor_conf.d snippets from XDG_DATA_DIRS. This reports the
# working directory with OSC 7 before every prompt and the command lifecycle
# with OSC 133, then removes the integration directory from XDG_DATA_DIRS so
# child processes do not inherit it.

function __warren_report_cwd --on-event fish_prompt
    printf '\e]7;file://%s%s\e\\' (hostname) $PWD
end

# OSC 133 semantic prompt markers. ghostline reads them to tell whether the
# shell is waiting for input or running a command, what that command is, and
# how it exited. The markers are only emitted when the user's own prompt does
# not already emit them: a second set would interleave with the first and
# corrupt the input region ghostline captures at 133;C.
set -g __warren_semantic 1

function __warren_foreign_semantic_prompt
    for line in (functions --handlers 2>/dev/null | string match -r '^(?:fish_prompt|fish_preexec|fish_postexec) .+')
        set -l handler (string split -m1 ' ' -- $line)[2]
        string match -q '__warren_*' -- $handler
        and continue
        functions -q $handler; or continue
        functions $handler | string match -q '*133;*'
        and return 0
    end
    return 1
end

# 133;C marks the command ghostline captures. fish emits fish_preexec after the
# typed line is on screen and before the command runs, which is that point.
function __warren_command_start --on-event fish_preexec
    test "$__warren_semantic" = 1; or return 0
    set -g __warren_ran 1
    printf '\e]133;C\e\\'
end

# 133;D carries the exit status. fish_postexec fires the moment the command
# finishes, before the next prompt, so the recorded end time is the command's.
function __warren_command_end --on-event fish_postexec
    set -l warren_status $status
    test "$__warren_semantic" = 1; or return 0
    printf '\e]133;D;%s\e\\' $warren_status
end

function __warren_prompt_start --on-event fish_prompt
    if not set -q __warren_semantic_checked
        set -g __warren_semantic_checked 1
        if __warren_foreign_semantic_prompt
            set -g __warren_semantic 0
        end
        if test "$__warren_semantic" = 1; and functions -q fish_prompt
            # 133;B ends the prompt so ghostline's input region starts after
            # it. Wrapping the user's prompt function is the only point in fish
            # that is exactly the prompt's end.
            functions -c fish_prompt __warren_user_prompt
            function fish_prompt
                __warren_user_prompt $argv
                printf '\e]133;B\e\\'
            end
        end
    end
    test "$__warren_semantic" = 1; or return 0
    printf '\e]133;A\e\\'
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
