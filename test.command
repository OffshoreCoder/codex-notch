#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
mkdir -p .build/module-cache
compiler_args=(-swift-version 5 -module-cache-path "$PWD/.build/module-cache")
xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/StateTests.swift -o .build/state-tests
./.build/state-tests
xcrun swiftc "${compiler_args[@]}" Sources/HookConfiguration.swift Tests/HookConfigurationTests.swift -o .build/hook-tests
./.build/hook-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/LibraryTests.swift -o .build/library-tests
./.build/library-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/HookConfiguration.swift Sources/IntegrationHealth.swift Tests/IntegrationHealthTests.swift -o .build/health-tests
./.build/health-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/AttentionTests.swift -o .build/attention-tests
./.build/attention-tests

xcrun swiftc "${compiler_args[@]}" -lsqlite3 Sources/ThreadNames.swift Tests/ThreadNamesTests.swift -o .build/name-tests
./.build/name-tests

xcrun swiftc "${compiler_args[@]}" -framework AppKit -framework Carbon Sources/GlobalShortcut.swift Tests/KeyboardTests.swift -o .build/keyboard-tests
./.build/keyboard-tests

xcrun swiftc "${compiler_args[@]}" Sources/ProjectContext.swift Tests/ProjectContextTests.swift -o .build/project-context-tests
./.build/project-context-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Tests/ResultTests.swift -o .build/result-tests
./.build/result-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/ResultWorkflowTests.swift -o .build/result-workflow-tests
./.build/result-workflow-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/ReviewTests.swift -o .build/review-tests
./.build/review-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/NotificationPolicy.swift Tests/NotificationTests.swift -o .build/notification-tests
./.build/notification-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/TurnGroup.swift Tests/TurnGroupTests.swift -o .build/group-tests
./.build/group-tests

xcrun swiftc "${compiler_args[@]}" Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/ArchiveTests.swift -o .build/archive-tests
./.build/archive-tests

xcrun swiftc "${compiler_args[@]}" Sources/PrivacyPresentation.swift Tests/PrivacyTests.swift -o .build/privacy-tests
./.build/privacy-tests

xcrun swiftc "${compiler_args[@]}" -framework AppKit Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/CharacterSkin.swift Tests/CharacterSkinTests.swift -o .build/skin-tests
./.build/skin-tests

xcrun swiftc "${compiler_args[@]}" -framework IOKit Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/KeepAwake.swift Tests/KeepAwakeTests.swift -o .build/keep-awake-tests
./.build/keep-awake-tests

xcrun swiftc "${compiler_args[@]}" -framework IOKit Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/KeepAwake.swift Tests/KeepAwakeQuestionTests.swift -o .build/keep-awake-question-tests
./.build/keep-awake-question-tests

if [[ "${CODEX_NOTCH_TEST_NATIVE_POWER:-0}" == "1" ]]; then
  xcrun swiftc "${compiler_args[@]}" -framework IOKit Sources/ResultSignal.swift Sources/TurnGroup.swift Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/KeepAwake.swift Tests/KeepAwakeNativeTests.swift -o .build/keep-awake-native-tests
  ./.build/keep-awake-native-tests --run-native-smoke
fi
