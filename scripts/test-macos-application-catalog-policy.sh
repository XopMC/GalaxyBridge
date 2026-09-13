#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-app-catalog-policy.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

# Exercise AppModel's real budget decision bodies without starting an app,
# opening sockets, or requiring a full package build. Only their containing
# class and method visibility are changed for this focused test facade.
GB_BUDGET_MODEL="${GB_SESSION_BUDGET_APP_MODEL:-$GB_ROOT/macos/GalaxyBridgeMac/AppModel.swift}"
{
  printf 'import Foundation\nfinal class ApplicationSessionBudgetProbe {\n'
  printf '  var activePhysicalLogicalSessionIDs: Set<String> = []\n  var lastError: String?\n'
  sed -n '/^    private var applicationSessionLeases = /p' "$GB_BUDGET_MODEL" | sed 's/private var/var/'
  sed -n '/^    func reserveApplicationWindowSession(/,/^    }/p' "$GB_BUDGET_MODEL"
  sed -n '/^    func releaseApplicationWindowSession(/,/^    }/p' "$GB_BUDGET_MODEL"
  sed -n '/^    private func canStartLogicalSession(/,/^    }/p' "$GB_BUDGET_MODEL" | sed 's/private func/func/'
  printf '}\n'
} > "$GB_TMP/ApplicationSessionBudgetProbe.swift"

set --
if [ -f "$GB_ROOT/macos/GalaxyBridgeMac/SessionCapacityPolicy.swift" ]; then
  set -- "$GB_ROOT/macos/GalaxyBridgeMac/SessionCapacityPolicy.swift"
fi

xcrun swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  "${GB_APPLICATION_CATALOG_SOURCE:-$GB_ROOT/macos/GalaxyBridgeMac/ApplicationCatalog.swift}" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationIconCache.swift" \
  "$GB_TMP/ApplicationSessionBudgetProbe.swift" \
  "$@" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ApplicationCatalogPolicySpec.swift" \
  -o "$GB_TMP/ApplicationCatalogPolicySpec"

"$GB_TMP/ApplicationCatalogPolicySpec"

GB_PANEL="$GB_ROOT/macos/GalaxyBridgeMac/ApplicationCatalogPanel.swift"
rg -q 'Image\(systemName: "app\.fill"\)' "$GB_PANEL"
if rg -q 'application\.label\.prefix\(|String\(application\.label\.prefix' "$GB_PANEL"; then
  echo "Application catalog must use a real system fallback, not a fabricated initial tile" >&2
  exit 1
fi

GB_SCRCPY_SESSION="$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpySession.swift"
rg -q 'self\.sendInitialControlMessages\(\)' "$GB_SCRCPY_SESSION"
rg -q 'configuration\.initialControlMessages' "$GB_SCRCPY_SESSION"
rg -Fq 'self.controlReadyHandler?()' "$GB_SCRCPY_SESSION"
rg -q 'self\.sendDirectText\(boundedText\)' "$GB_SCRCPY_SESSION"
if rg -q 'pasteMode: \.acknowledgedDisplayKeycode' "$GB_SCRCPY_SESSION"; then
  echo "Independent app-window typing must use the session-targeted direct text injector" >&2
  exit 1
fi
if rg -q 'injectRemoteText' "$GB_SCRCPY_SESSION"; then
  echo "Independent app-window text must remain on its session-targeted scrcpy channel" >&2
  exit 1
fi

GB_APP_WINDOW="$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowCoordinator.swift"
rg -q 'session\.presentationState\.showsOpeningOverlay' "$GB_APP_WINDOW"
rg -q 'onClipboardCommand:.*session\.requestRemoteClipboard' "$GB_APP_WINDOW"
if rg -q 'session\.surface\.hasFrame' "$GB_APP_WINDOW"; then
  echo "Application window must observe session first-frame state, not a nested surface object" >&2
  exit 1
fi
