#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
exec ./CodexNotch.app/Contents/MacOS/CodexNotch --disconnect-hooks "$@"
