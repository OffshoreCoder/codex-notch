#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
mkdir -p .build/module-cache
compiler_args=(-swift-version 5 -module-cache-path "$PWD/.build/module-cache")
xcrun swiftc "${compiler_args[@]}" Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/StateTests.swift -o .build/state-tests
./.build/state-tests
xcrun swiftc "${compiler_args[@]}" Sources/HookConfiguration.swift Tests/HookConfigurationTests.swift -o .build/hook-tests
./.build/hook-tests

xcrun swiftc "${compiler_args[@]}" Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Tests/LibraryTests.swift -o .build/library-tests
./.build/library-tests

xcrun swiftc "${compiler_args[@]}" Sources/CompanionState.swift Sources/EventSpool.swift Sources/LocalStore.swift Sources/HookConfiguration.swift Sources/IntegrationHealth.swift Tests/IntegrationHealthTests.swift -o .build/health-tests
./.build/health-tests
