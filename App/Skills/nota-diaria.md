---
name: nota-diaria
description: Lleva una nota diaria con lo importante del día, sin duplicarla
when: nota diaria, anotar o apuntar en el diario, registro del día, bitácora de hoy
requires_tools: [notes]
surfaces: [phoneChat]
steps:
  - notes.list()
  - notes.read(name=diario-<AAAA-MM-DD>)
  - notes.append(name=diario-<AAAA-MM-DD>, content)
---
- Una sola nota por día, nombrada `diario-AAAA-MM-DD` (fecha local del dueño).
- Si la nota de hoy ya existe, AGREGA al final (append); jamás la sobrescribas.
- Si no existe, créala con un encabezado de la fecha y luego agrega la entrada.
- Cada entrada va en una línea que empieza con la hora (HH:MM) y es breve:
  qué pasó, qué se decidió, qué quedó pendiente.
- Si el dueño pide "lo de hoy", lee la nota del día y resume en 3 viñetas.
