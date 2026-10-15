#!/usr/bin/env bash
# ITMS-90626: Apple rechaza el binario si la metadata de un App Intent (título,
# descripción, frases, diálogos) contiene "Siri". Revisa los string literals de
# todo archivo de App/ que importe AppIntents (sin comentarios).
set -euo pipefail
status=0
while IFS= read -r file; do
  hits=$(sed -E 's#//.*$##' "$file" | grep -noE '"[^"]*"' | grep -i 'siri' || true)
  if [ -n "$hits" ]; then
    echo "::error file=$file::String con \"Siri\" en un archivo de App Intents (ITMS-90626):"
    echo "$hits"
    status=1
  fi
done < <(grep -rl '^import AppIntents' App --include='*.swift')
exit $status
