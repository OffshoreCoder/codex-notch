#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
if [[ ! -x CodexNotch.app/Contents/MacOS/CodexNotch ]]; then ./build.command; fi
exec ./CodexNotch.app/Contents/MacOS/CodexNotch --connect-hooks "$@"
