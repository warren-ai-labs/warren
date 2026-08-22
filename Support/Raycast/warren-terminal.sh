#!/usr/bin/env bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Terminal
# @raycast.mode silent
# @raycast.packageName Warren
# @raycast.description Open a new shell in Warren's Inbox terminal group
# @raycast.icon warren-terminal.png

set -euo pipefail

/usr/bin/open -a "/Applications/Warren.app" "warren://terminal?group=Inbox"
