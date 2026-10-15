#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
binary_path="$PWD/CodexNotch.app/Contents/MacOS/CodexNotch"
if [[ ! -x "$binary_path" ]]; then
  ./build.command
fi
# The app has no network code. Also deny network system calls for this launch.
if [[ -x /usr/bin/sandbox-exec ]]; then
  exec /usr/bin/sandbox-exec -f "$PWD/offline.sb" "$binary_path" "$@"
fi
print -u2 'Не найден штатный sandbox-exec. Для запуска без системной блокировки сети откройте CodexNotch.app самостоятельно.'
exit 1
