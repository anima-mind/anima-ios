# AnimaUITests

Suite XCUITest de la app en simulador (iOS 26). Categoría aparte del gate de
cobertura del package (`scripts/coverage-gate.sh` no la mide).

```bash
scripts/ui-test.sh            # primer iPhone iOS 26 disponible
scripts/ui-test.sh <UDID>     # simulador concreto
```

## Modo `--uitest`

Los tests lanzan la app con `--uitest` (+ `--uitest-reset` para arrancar limpio).
El shell (`App/UITestSupport.swift`) cablea dobles deterministas y sin red; sin
el argumento nada de esto se activa:

- Config: `StaticConfigProvider` con `RemoteConfigDefaults.plist` (sin Firebase).
- Cuenta: `PreviewAccountProvider` (signedOut).
- Modelo local forzado a `.available`; Claude y on-device responden con
  `UITestScriptedProvider`: streamea una respuesta fija (~3 s) o, si el mensaje
  menciona "calendario", pide la tool `calendar` para ejercitar el TCC real.
- Estado aislado: suite de UserDefaults, servicio de Keychain y SQLite propios;
  `--uitest-reset` los borra al arrancar.
- Sin validar la key contra el API: el paso API key acepta offline con warning.
- `--uitest-seed-goal`: siembra una meta declarada (Metas, check-ins).
- `--uitest-seed-inferred-goal`: siembra una meta inferida por confirmar
  (aviso sobre el chat → Ajustes → Mente → "Por aprobar").
- `--uitest-fresh-session`: el lanzamiento abre sesión nueva (simula >8 h sin
  actividad) — el historial completo debe seguir visible.
- `--uitest-seed-reminder=N`: siembra un recordatorio de Anima a +N s.
- `--uitest-sticky` (solo DEBUG + simulador): notificaciones REALES y el modo
  UI-test persiste en `Library/uitest-sticky.plist`, para que el lanzamiento
  que hace iOS al tocar el push (sin argumentos) siga aislado. Cualquier
  lanzamiento con `--uitest` sin `--uitest-sticky` lo borra.

## Notificaciones

`NotificationUITests` siembra un recordatorio a +20 s, acepta el permiso en
SpringBoard y toca el push con la app terminada (cold launch), en background y
al frente: la app debe abrir el Chat con la card `chat.proactive.reminder`.

## TCC

`PermissionsUITests` usa permisos REALES. Antes de cada test se resetea con
`XCUIApplication.resetAuthorizationStatus(for: .calendar)`; el script además corre

```bash
xcrun simctl privacy <UDID> reset calendar,reminders,contacts com.joshuamoreno1.anima
```

El diálogo lo presenta SpringBoard: se toca explícitamente (reintento acotado si
el tap cae durante la animación) y hay un `addUIInterruptionMonitor` de respaldo.

## Firma

Se corre con firma ad-hoc (`CODE_SIGN_IDENTITY=-`). Con `CODE_SIGNING_ALLOWED=NO`
el Keychain del simulador rechaza la escritura y el camino Anthropic no aterriza.
