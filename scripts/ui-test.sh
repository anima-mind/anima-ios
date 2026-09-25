#!/usr/bin/env bash
# ui-test.sh — corre la suite XCUITest (AnimaUITests) en un simulador iOS 26.
# Uso: scripts/ui-test.sh [UDID]   (default: $SIM_UDID o el primer iPhone iOS 26 booteado/disponible)
# Resetea TCC (calendar/reminders/contacts) del bundle antes de correr; los tests
# además lo resetean por test con XCUIApplication.resetAuthorizationStatus(for:).
# Firma ad-hoc ("-"): sin ella el Keychain del simulador falla (-34018) y el
# camino Anthropic no puede guardar la key.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.joshuamoreno1.anima"
RESULT="${RESULT_BUNDLE:-$ROOT/build/AnimaUITests.xcresult}"
UDID="${1:-${SIM_UDID:-}}"

if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
cands = [d for rt, ds in devices.items() if "iOS-26" in rt for d in ds if d["name"].startswith("iPhone")]
cands.sort(key=lambda d: d["state"] != "Booted")
print(cands[0]["udid"] if cands else "")')"
fi
[[ -n "$UDID" ]] || { echo "No hay simulador iPhone iOS 26 disponible" >&2; exit 1; }
echo "Simulador: $UDID"

xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" reset calendar,reminders,contacts "$BUNDLE_ID" 2>/dev/null || true

(cd "$ROOT" && xcodegen generate --spec App/project.yml)
rm -rf "$RESULT"
xcodebuild test \
  -project "$ROOT/App/Anima.xcodeproj" -scheme Anima \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:AnimaUITests \
  -resultBundlePath "$RESULT" \
  ${DERIVED_DATA:+-derivedDataPath "$DERIVED_DATA"} \
  ${SPM_DIR:+-clonedSourcePackagesDirPath "$SPM_DIR"} \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
