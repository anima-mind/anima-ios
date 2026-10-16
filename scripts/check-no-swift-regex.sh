#!/usr/bin/env bash
# check-no-swift-regex.sh — Sources/ no usa la Regex de Swift (_StringProcessing).
# Por qué: en el CI de #45 (runner de 3 núcleos) la `Regex` de Swift se
# reconstruía en cada llamada y, sincrónica en el pool cooperativo, dejaba sin
# hilos a la suite (los `eventually` de 10 s se vencían a ~13 s). Toda regex va
# por `ICURegex` / `NSRegularExpression` precompilada (`static let`) con un corte
# barato antes de evaluarla.
#
# Falla con: literales `/…/` o `#/…/#` en contexto de regex, `Regex(`, `Regex<`,
# `.firstMatch(of:`, `.wholeMatch(of:`, `.prefixMatch(of:`, `.matches(of:`,
# `.ranges(of: /`, `.firstRange(of: /`, `.contains(/`, `.replacing(/`,
# `.trimmingPrefix(/`, `.split(separator: /`, `.starts(with: /`, `.ignoresCase()`.
#
# ALLOWLIST: "ruta|fragmento exacto de la línea" + por qué no es camino caliente.
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWLIST=(
  # FoundationModels exige un `Regex` de Swift para `.pattern` (GenerationGuide);
  # solo se arma al describir una tool con patrón para el modelo local.
  "Sources/AnimaKit/Provider/OnDeviceProvider.swift|guard let regex = try? Regex(pattern) else { return DynamicGenerationSchema(type: String.self) }"
)

PATTERN='(\bRegex *[(<]|\.(firstMatch|wholeMatch|prefixMatch|matches)\(of:|\.(ranges|firstRange)\(of: *#?/|\.(contains|replacing|trimmingPrefix|starts)\((with: *)?#?/|\.split\(separator: *#?/|\.ignoresCase\(\)|#/[^/]|[=(,:?] *#?/[^/* ][^"]*/#?($|[ ,)!.]))'

status=0
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest#*:}"
  code="$(printf '%s' "$line" | sed -E 's#^[[:space:]]*##')"
  # Comentarios de línea completa: no son código.
  [[ "$code" == //* ]] && continue
  allowed=0
  for entry in "${ALLOWLIST[@]}"; do
    [[ "$file" == "${entry%%|*}" && "$line" == *"${entry#*|}"* ]] && allowed=1
  done
  (( allowed )) && continue
  echo "::error file=$file::Regex de Swift en Sources/ (usa ICURegex precompilada): ${hit#*:}"
  status=1
done < <(grep -rnE "$PATTERN" Sources --include='*.swift' || true)

if (( status == 0 )); then echo "check-no-swift-regex: OK (sin Regex de Swift en Sources/)"; fi
exit $status
