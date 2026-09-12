# anima-ios

**Perfil edge del harness [Anima](https://github.com/joshuamoreno1/anima)** — un asistente personal iOS modelado sobre cómo el lenguaje forma la mente. La mente vive en el teléfono; las [gafas Meta son un segundo cuerpo opcional](https://github.com/joshuamoreno1/anima/blob/main/docs/05-meta-glasses-plan.md).

> Una mente = LLM (dotación) + harness (desarrollo) + historia (experiencia).

## Estado

**Pre-Fase 0.** Este repo contiene `AnimaKit` (SPM package — el core puro y testeable) arrancando por el primer invariante cross-runtime del blueprint: la [fórmula de plasticidad](Sources/AnimaKit/Plasticity.swift) del SelfModel (spec §B.4). Los mismos valores canónicos se assertan en [`animad`](https://github.com/joshuamoreno1/animad) (Go) — la prueba viva de la matriz de portabilidad (spec §C.1).

## Mapa

- **Blueprint (el contrato)**: [joshuamoreno1/anima](https://github.com/joshuamoreno1/anima) — spec (doc 03) y plan de implementación iOS (doc 04, fases 0→4).
- **Arquitectura objetivo**: `AnimaKit` (dominio puro, sin UI ni IO — testeable en CI de macOS) + app shell SwiftUI (Xcode, se agrega en Fase 0) + capa DAT humilde para gafas (track G).
- **Runtime hermano**: [`animad`](https://github.com/joshuamoreno1/animad) — perfil server en Go.

## Dev

```bash
swift build && swift test
```

- Stack: Swift 6 / SwiftUI · GRDB · NLEmbedding · BGTaskScheduler · Claude API directa (URLSession + SSE).
- **La API key jamás entra al repo** — vive en Keychain (plan doc 04 §8). CD a TestFlight: pendiente (requiere certs de Apple; ver plan).

## Licencia

MIT
