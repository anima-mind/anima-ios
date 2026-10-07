# anima-ios

**Perfil edge del harness [Anima](https://github.com/anima-mind/anima)** — un asistente personal iOS modelado sobre cómo el lenguaje forma la mente. La mente vive en el teléfono; las [gafas Meta son un segundo cuerpo opcional](https://github.com/anima-mind/anima/blob/main/docs/05-meta-glasses-plan.md).

> Una mente = LLM (dotación) + harness (desarrollo) + historia (experiencia).

## Estado

**Pre-Fase 0.** Este repo contiene `AnimaKit` (SPM package — el core puro y testeable) arrancando por el primer invariante cross-runtime del blueprint: la [fórmula de plasticidad](Sources/AnimaKit/Plasticity.swift) del SelfModel (spec §B.4). Los mismos valores canónicos se assertan en [`animad`](https://github.com/anima-mind/animad) (Go) — la prueba viva de la matriz de portabilidad (spec §C.1).

## Mapa

- **Blueprint (el contrato)**: [anima-mind/anima](https://github.com/anima-mind/anima) — spec (doc 03) y plan de implementación iOS (doc 04, fases 0→4).
- **Arquitectura objetivo**: `AnimaKit` (dominio puro, sin UI ni IO — testeable en CI de macOS) + app shell SwiftUI (Xcode, se agrega en Fase 0) + capa DAT humilde para gafas (track G).
- **Runtime hermano**: [`animad`](https://github.com/anima-mind/animad) — perfil server en Go.

## Dev

```bash
swift build && swift test
```

- Stack: Swift 6 / SwiftUI · GRDB · NLEmbedding · BGTaskScheduler · Claude API directa (URLSession + SSE).
- **La API key jamás entra al repo** — vive en Keychain (plan doc 04 §8). CD a TestFlight: pendiente (requiere certs de Apple; ver plan).

## Widgets y App Group

- App Group `group.com.joshuamoreno1.anima.widgets` (app + extensión `com.joshuamoreno1.anima.widgets`; constante única en `AppGroup.identifier`).
- **Base de datos**: `anima.sqlite` vive en `<grupo>/Database/`. La mudanza desde `Documents` corre UNA vez al arrancar (`DatabaseRelocation`): checkpoint del WAL → copia con la API de backup de SQLite → `integrity_check` + mismo esquema + mismas filas en TODAS las tablas → rename atómico; la vieja queda como `Documents/anima.sqlite.migrated` y se purga recién tras 3 aperturas buenas de la base del grupo en arranques posteriores. Si la base ya vive en el grupo y el binario no alcanza el grupo (sin entitlement), la app NO abre ninguna base (ni vacía ni la `.migrated`) y muestra el error. Cualquier fallo antes de instalar ⇒ se sigue con la de `Documents` intacta y se reintenta el próximo arranque. En el grupo va en rollback journal (sin `-shm` con lock vivo al suspender). `Documents/skills` no se mueve.
- **Widgets** (`App/Widgets`, vistas e intents compartidos en `App/WidgetsShared`): leen SOLO `<grupo>/Widgets/WidgetSnapshot.json`, que la app reescribe tras cada sync proactivo, al cerrar una noche y al ir a background. La extensión jamás abre GRDB: linkea solo `AnimaWidgetCore` (snapshot, copy, deep links, tema, BreathMark, cola de botones; sin GRDB), que `AnimaKit` re-exporta.
- **Botones** ("Hecho", "Sí, avancé"): cada tap queda durable en `<grupo>/Widgets/Actions/` (un archivo por acción) y el widget se repinta optimista; la app los aplica con el mismo `ProactiveActionHandler` de las notificaciones — de inmediato si iOS corre el intent en su proceso (`LiveActivityIntent`), o al abrir / volver / en el pulso de background.
- Deep links: `anima://reminders`, `anima://goals[?id=]`, `anima://chat?mic=1` (Centro de control / botón de Acción).

## Licencia

MIT
