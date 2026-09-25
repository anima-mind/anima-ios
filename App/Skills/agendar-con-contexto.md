---
name: agendar-con-contexto
description: Crea eventos en el calendario revisando antes conflictos y contexto del día
when: agendar reunión, crear evento, programar cita o llamada, bloquear tiempo en el calendario
requires_tools: [calendar]
surfaces: [phoneChat]
steps:
  - calendar.list(days_ahead=7)
  - calendar.search(query=<título o persona>)
  - calendar.create(title, start, end)
---
1. Antes de crear, revisa la agenda del día pedido (y el día siguiente si el
   evento cruza medianoche): busca eventos que se solapen con el horario.
2. Si hay conflicto, NO crees nada todavía: di cuál es el choque y propone el
   hueco libre más cercano (antes o después) con la misma duración.
3. Si no hay hora de fin, asume 30 minutos para llamadas y 1 hora para reuniones.
4. Si el evento es con una persona, busca si ya existe uno parecido esa semana
   para no duplicarlo.
5. Crear es una acción eferente: el dueño confirma siempre. Resume en una línea
   qué vas a crear (título, día, hora) antes de pedir la confirmación.
