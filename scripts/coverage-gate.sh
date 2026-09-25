#!/usr/bin/env bash
# coverage-gate.sh — gate de cobertura de líneas del core de AnimaKit.
# Idéntico en local y CI: corre `swift test --enable-code-coverage`, calcula el %
# de líneas del recorte y falla si queda bajo el umbral.
#
# Uso:
#   ./scripts/coverage-gate.sh              # corre tests + gate
#   SKIP_TESTS=1 ./scripts/coverage-gate.sh # reusa el profdata del último run
#   MIN_COVERAGE=85 ./scripts/coverage-gate.sh
#
# EXCLUSIONES (fuera del denominador) — cada una con su justificación:
#   Sources/AnimaKit/UI/                                 SwiftUI: se cubre con UI tests de simulador, no unit.
#   Sources/AnimaKit/Design/                             SwiftUI (tema, BreathMark): idem.
#   Sources/AnimaKit/Desire/SystemObservableEnvironment.swift
#                                                        EventKit/HealthKit reales; solo verificable en device.
#   Tests/                                               el propio código de test no cuenta.
#   .build/ (dependencias SPM, p. ej. GRDB)              código de terceros.
# TODO lo demás bajo Sources/AnimaKit/ cuenta.

set -euo pipefail

MIN_COVERAGE="${MIN_COVERAGE:-90}"
EXCLUDE_REGEX='(/Sources/AnimaKit/UI/|/Sources/AnimaKit/Design/|/Sources/AnimaKit/Desire/SystemObservableEnvironment\.swift$|/Tests/|/\.build/)'

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  swift test --enable-code-coverage
fi

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="$BIN_PATH/codecov/default.profdata"
TEST_BIN="$BIN_PATH/AnimaKitPackageTests.xctest/Contents/MacOS/AnimaKitPackageTests"
[[ -f "$TEST_BIN" ]] || TEST_BIN="$BIN_PATH/AnimaKitPackageTests.xctest"

if [[ ! -f "$PROFDATA" ]]; then
  echo "coverage-gate: no existe $PROFDATA (¿corriste swift test --enable-code-coverage?)" >&2
  exit 2
fi

SUMMARY_JSON="$(mktemp)"
trap 'rm -f "$SUMMARY_JSON"' EXIT

xcrun llvm-cov export -summary-only \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex "$EXCLUDE_REGEX" \
  "$TEST_BIN" > "$SUMMARY_JSON"

COVERAGE_JSON="$SUMMARY_JSON" COVERAGE_ROOT="$ROOT/Sources/AnimaKit/" MIN_COVERAGE="$MIN_COVERAGE" python3 - <<'PY'
import json, os, sys

root = os.environ["COVERAGE_ROOT"]
minimum = float(os.environ["MIN_COVERAGE"])
with open(os.environ["COVERAGE_JSON"]) as fh:
    data = json.load(fh)

rows, covered, total = [], 0, 0
for f in data["data"][0]["files"]:
    name = f["filename"]
    if not name.startswith(root):
        continue
    lines = f["summary"]["lines"]
    covered += lines["covered"]
    total += lines["count"]
    rows.append((lines["percent"], name[len(root):], lines["covered"], lines["count"]))

if total == 0:
    print("coverage-gate: 0 líneas en el recorte — ¿regex de exclusión rota?", file=sys.stderr)
    sys.exit(2)

rows.sort()
width = max(len(r[1]) for r in rows)
print(f"{'Archivo'.ljust(width)}  {'Líneas':>11}  {'%':>7}")
print("-" * (width + 22))
for pct, name, cov, cnt in rows:
    print(f"{name.ljust(width)}  {cov:>5}/{cnt:<5}  {pct:>6.2f}%")
print("-" * (width + 22))
pct = 100.0 * covered / total
print(f"{'TOTAL (recorte)'.ljust(width)}  {covered:>5}/{total:<5}  {pct:>6.2f}%")

sys.stdout.flush()
if pct < minimum:
    print(f"\n❌ coverage-gate: {pct:.2f}% de líneas < mínimo {minimum:.0f}%. "
          "Sube la cobertura de los archivos de arriba (los más bajos primero).", file=sys.stderr)
    sys.exit(1)
print(f"\n✅ coverage-gate: {pct:.2f}% ≥ {minimum:.0f}%")
PY
