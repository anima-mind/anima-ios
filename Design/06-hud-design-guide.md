# Diseñar para el HUD de Meta Ray-Ban Display — guía de restricciones (DAT SDK 0.9.0)

> **Para diseñadores (humanos o Claude).** El HUD de las gafas NO es una pantalla libre: es un **vocabulario cerrado de componentes** que renderiza el runtime de las gafas. No hay píxeles, no hay CSS, no hay SwiftUI — hay un árbol de ~10 componentes con opciones enumeradas. **Todo lo que no está en este documento NO EXISTE.** Diseñar fuera de este vocabulario produce diseños no implementables.
>
> Fuente: `.swiftinterface` real del SDK (Wearables Device Access Toolkit 0.9.0) + verificación en hardware (Ray-Ban Display + Neural Band). Complementa el [doc 05](05-meta-glasses-plan.md) (arquitectura).

---

## 1. Modelo mental (léelo dos veces)

1. **La app corre en el iPhone; las gafas solo renderizan.** La app manda un árbol de vistas por Bluetooth; el runtime de las gafas lo dibuja. Nada persiste en las gafas.
2. **Cada envío reemplaza la vista COMPLETA.** No hay updates parciales, no hay transiciones entre estados de una misma vista, no hay animaciones controlables. "Actualizar un contador" = mandar toda la vista de nuevo.
3. **No hay dimensiones.** El SDK no expone resolución ni tamaño de pantalla. El layout es flexbox relativo (dirección, spacing, grow/shrink). **Diseña árboles de componentes, no mockups de píxeles.**
4. **Una vista = una card corta.** El sistema da scroll vertical automático si el contenido excede; el scroll horizontal NO existe. Aun así: el HUD está en la cara — brevedad extrema.
5. **El display duerme por inactividad.** Al despertar, la app re-manda el contenido. Implicación: toda vista debe ser reconstruible desde el estado de la app — nada de estados efímeros "a mitad de algo".

---

## 2. El vocabulario completo (esto es TODO lo que hay)

### Componentes

| Componente | Parámetros (exhaustivo) | Notas |
|---|---|---|
| **FlexBox** | `direction: .column\|.row\|.columnReverse\|.rowReverse` · `spacing: Int` · `alignment` y `crossAlignment: .start\|.center\|.end\|.stretch` · `wrap: Bool` · `padding: EdgeInsets` | El único contenedor. El **root de toda vista es un FlexBox** (o VideoPlayer). Anidable. `.onTap {}` lo hace interactivo. `.background(.none\|.card)` — **solo esos dos fondos**. |
| **Text** | `style: .heading\|.body\|.meta` · `color: .primary\|.secondary` | **3 estilos, 2 colores. Punto.** Sin tamaños custom, sin fuentes, sin negritas selectivas, sin hex. |
| **Icon** | `name: IconName` (catálogo cerrado, §3) · `style: .filled\|.outline` | Solo los ~115 glyphs del catálogo. |
| **Image** | `uri: String` · `sizePreset: .icon\|.fill` · `cornerRadius: .none\|.small\|.medium` | Escape hatch visual: cualquier imagen por URI. Dos tamaños preset, tres radios. |
| **Button** | `label: String` · `style: .primary\|.secondary\|.outline` · `iconName:` opcional · `onClick {}` | La unidad de acción. |
| **ButtonGroup** | `alignment: .start\|.center\|.end` + solo `Button`s adentro | **Sin padding ni spacing propios** — la separación la decide el sistema. Recomendación: ≤3 botones. |
| **VideoPlayer** | `provider: .uri(String)` · `codec: .mp4` · `onError` | Solo como root (vista completa de video). |

Modificadores de layout disponibles: `flexGrow`, `flexShrink`, `alignSelf`, `padding(Edge, Int)`. **Nada más.**

### Lo que NO existe (la lista que rompe los diseños)

- ❌ Colores libres, hex, gradientes, opacidad, sombras, blur, glassmorphism
- ❌ Tipografías custom, tamaños de fuente, line-height, letter-spacing, negritas/itálicas inline
- ❌ Inputs: campos de texto, teclado, toggles, sliders, checkboxes, pickers, steppers
- ❌ Spinners, progress bars, skeletons, badges, chips, avatares (como componente)
- ❌ Animaciones, transiciones, micro-interacciones, haptics, sonido
- ❌ Posicionamiento absoluto, z-index, overlays, modales, sheets, toasts
- ❌ Scroll horizontal, carruseles, tabs, paginación por swipe
- ❌ Updates parciales de vista, contadores animados, streaming de texto token a token
- ❌ Gestos: swipe, long-press, drag, pinch-to-zoom (a nivel de app — ver §4)
- ❌ Íconos custom que no estén en el catálogo (workaround: `Image` con URI)

---

## 3. Catálogo de íconos (cerrado — no existen otros)

Faltantes notables: **no hay** `mic`, `inbox`, `merge`, `github`, `slack`; "warning" es `exclamationTriangle`. Para lo que no hay glyph: el más cercano, o `Image` con URI custom.

```
airplane, arrowDownShallowU, arrowLeft, arrowRight, arrowULeft, arrowUpShallowU, avatar,
avatarOff, bedSide, bell, bellDiagonalRightDot, bellOff, bikeShare, bug, bullhorn, bus,
calendar, campfire, caretDown, caretLeft, caretRight, caretUp, carFrontView, cart,
checkmark, checkmarkCircle, circle8RaysLarge, circleHandle, clock, cloud, cloudCrescentMoon,
cloudDotFourRays, cloudFiveDashes, cloudHookSwirl, cloudLightning, cocktailGlass, code,
coffeeCup, compassNorthUpRed, containerWithLid, crossBriefcase, dropper, envelopeOpen,
exclamationCircle, exclamationTriangle, eye, forkKnife, fourArcsUpFilled,
fourArcsUpGrayscale, fourCornerFrame, gear, globeWesternHemisphere, graduationCap, hashtag,
headphones, heart, house, iCircle, lightBulb, magicWand, metaAi, mountainSquare,
mountainSquareStacked, museumBuilding, musicNote, nineSquaresGrid, padlockClosed,
padlockOpen, palette, paperAirplane, pencil, pencilSquare, person, personCircle, phone,
phoneHandsetArrowDownLeft, phoneHandsetArrowUpRight, phoneSlash, pizzaSlice, plus,
plusCircle, shoppingBag, slidersHorizontal, smartGlasses, smileyCircle, speakerOff,
speakerWithOneArc, speakerWithThreeArcs, speakerWithTwoArcs, speechBubble, speechBubbleOff,
stadium, star, starCircleTriangleAi, taxi, threeDotsHorizontal, threeDotSpeechBubble,
threeHorizontalLines, threeHorizontalLinesStackedDescending, threePeopleOverlapping, train,
tree, triangleLeftVerticalLine, triangleRight, triangleRightCircle,
triangleRightVerticalLine, twoArrowsClockwise, twoLinesParallel,
twoSquaresStackedRightDown, twoTrianglesLeft, twoTrianglesRight, videoCamera,
videoCameraOff, wristband, wristbandSlash, x
```

Mapeos útiles para Anima: propuesta → `bell` · confirmar → `checkmarkCircle` · rechazar/cerrar → `x` · alerta → `exclamationTriangle` · agenda → `calendar` · escuchando/hablar → `speechBubble` (no hay mic) · pensando → `circle8RaysLarge` o `metaAi` · atrás → `arrowLeft` o `caretLeft` · gafas → `smartGlasses`.

---

## 4. Interacción y navegación (el sistema manda)

El usuario controla con la patilla (captouch) y gestos del Neural Band (pinch, scroll, foco). **La app NUNCA recibe gestos crudos** — el SDK lo abstrae todo:

| Lo hace el SISTEMA (no diseñes esto) | Lo hace la APP (diseña esto) |
|---|---|
| Mover el foco entre elementos interactivos | Declarar qué es interactivo (`Button`, FlexBox con `.onTap`) |
| Scroll vertical | Construir el árbol y enviarlo |
| Pinch/tap = seleccionar → dispara el callback | Reaccionar: mandar la siguiente vista |
| **Gesto back → TERMINA la sesión, siempre** | **Botón "Atrás" explícito en toda vista no-raíz** |

Reglas de diseño que salen de esto:

1. **Toda navegación es un swap de vista completa** disparado por un botón/tap. Diseña el grafo de vistas como máquina de estados: vista → acción → vista.
2. **El back del sistema NO navega: mata la sesión.** Si tu diseño depende de "volver atrás" con el gesto, está roto. Botón "Atrás" (`arrowLeft`) renderizado por la app, siempre.
3. Varios elementos interactivos por vista funcionan (el foco los recorre) — pero cada uno es un salto de foco para el usuario: **≤4 interactivos por vista** como regla de oro.
4. No hay hover, no hay estados pressed custom — el sistema pinta el foco.

---

## 5. Cómo diseñar bien adentro de la caja

1. **Jerarquía sin color**: solo tienes `heading/body/meta` × `primary/secondary`. La jerarquía se construye con estructura (orden, agrupación en cards, spacing), no con color ni peso.
2. **Una idea por vista.** Card = título (`heading`) + 1-3 líneas (`body`) + meta opcional (`meta secondary`) + ≤3 acciones (`ButtonGroup`). Presupuesto recomendado: heading ≤40 caracteres, body ≤200 — no es límite del SDK, es respeto por una pantalla en la cara.
3. **Contenido largo = handoff.** Nunca diseñes lectura larga en el HUD: la card termina en un botón "Ver en el teléfono". El teléfono es la superficie rica; el HUD es el vistazo.
4. **"Cargando" sin spinner**: no existe el componente. Patrón: vista con `Text("pensando…", style: .meta, color: .secondary)` + ícono estático (`circle8RaysLarge`). Cuando llegue el resultado, se manda la vista nueva completa.
5. **Sin streaming**: el texto no aparece token a token (cada update sería un re-render completo por Bluetooth). Diseña para respuesta completa: estado "pensando" → card final.
6. **Listas**: FlexBox column de cards (`background: .card`) con `.onTap` cada una. Cortas (3-5 ítems) — más que eso, handoff.
7. **Estados vacíos y de error también son cards** del mismo vocabulario — no hay ilustraciones custom (salvo `Image` por URI, con moderación: cada imagen viaja por Bluetooth).
8. **Diseña en árboles, no en píxeles.** El entregable correcto de una vista es su árbol de componentes, no un PNG:

```
CardPropuesta:
FlexBox(column, spacing: 12, padding: all 16) .background(.card)
├─ FlexBox(row, spacing: 8)
│  ├─ Icon(bell, outline)
│  └─ Text("Propuesta", style: meta, color: secondary)
├─ Text("Tienes un hueco a las 3pm", style: heading)
├─ Text("2 recordatorios vencidos del proyecto X caben ahí.", style: body)
└─ ButtonGroup(alignment: end)
   ├─ Button("Ahora no", style: outline, icon: x)
   └─ Button("Agéndalo", style: primary, icon: checkmarkCircle)
```

(Mockups visuales son bienvenidos como *ilustración* de un árbol válido — nunca al revés.)

---

## 6. Checklist de validación (pásale esto a cada diseño antes de aceptarlo)

- [ ] ¿El root de cada vista es un FlexBox (o VideoPlayer)?
- [ ] ¿Cada elemento del diseño es uno de los 7 componentes del §2, con parámetros del enum exacto?
- [ ] ¿Cero colores/hex/tipografías/sombras/animaciones inventadas?
- [ ] ¿Todos los íconos están en el catálogo del §3 (verificado nombre por nombre)?
- [ ] ¿Toda vista no-raíz tiene botón "Atrás" propio?
- [ ] ¿≤4 elementos interactivos y ≤3 botones por vista?
- [ ] ¿Ninguna interacción depende de swipe/long-press/teclado/input de texto?
- [ ] ¿La vista es reconstruible desde el estado de la app (sobrevive el sueño del display)?
- [ ] ¿El contenido largo tiene handoff al teléfono en vez de scroll infinito?
- [ ] ¿El diseño está entregado como árbol de componentes (§5.8)?

---

*Guía v1 — 2026-09-12 · SDK 0.9.0. Si Meta Connect (sep 23-24) trae 0.10 con componentes nuevos, esta guía se versiona — hasta entonces, este vocabulario es la ley.*
