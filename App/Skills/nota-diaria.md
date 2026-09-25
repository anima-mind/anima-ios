---
# Gramática de `steps` (la corre el SkillRunner cuando la skill llega a
# automatizada — 5 éxitos seguidos; con 3 es "practicada" y solo se inyecta):
#   tool.operación(clave=valor, …)   args fijos; enteros y true/false tipados
#   {hoy}    → fecha local AAAA-MM-DD      {turno} → el texto de tu pedido
#   ? al final → paso opcional: si falla, se anota "sin resultado" y sigue
#   `clave` sola o `<descripción>` → lo decide el modelo: la skill no corre
#   sola ese turno y vuelve a inyectarse como conocimiento.
# Solo se auto-ejecutan lecturas (list/search/read, phone_context.*); las
# escrituras (create/append/delete/complete) SIEMPRE te piden ok.
name: nota-diaria
description: Lleva una nota diaria con lo importante del día, sin duplicarla
when: nota diaria, anotar o apuntar en el diario, registro del día, bitácora de hoy
requires_tools: [notes]
surfaces: [phoneChat]
steps:
  - notes.list()
  - notes.read(name=diario-{hoy})?
  - notes.append(name=diario-{hoy}, content)
---
- Una sola nota por día, nombrada `diario-AAAA-MM-DD` (fecha local del dueño).
- Si la nota de hoy ya existe, AGREGA al final (append); jamás la sobrescribas.
- Si no existe, créala con un encabezado de la fecha y luego agrega la entrada.
- Cada entrada va en una línea que empieza con la hora (HH:MM) y es breve:
  qué pasó, qué se decidió, qué quedó pendiente.
- Si el dueño pide "lo de hoy", lee la nota del día y resume en 3 viñetas.
