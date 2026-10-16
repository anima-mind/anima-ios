import Foundation
import Testing
@testable import AnimaKit

/// Campo build 27: el control "Hablar con Anima" abría el chat sin escuchar.
/// El "abrir con mic" espera escena `.active` + chat cableado.
@Suite("Hablar con Anima — mic pendiente hasta .active")
@MainActor
struct TalkLaunchGateTests {

    @MainActor final class Rig {
        var clock = Date(timeIntervalSince1970: 1_000)
        var starts = 0
        lazy var gate = TalkLaunchGate(settle: .zero, expiry: 60, coalesce: 3,
                                       now: { [unowned self] in self.clock },
                                       sleep: { _ in }) { [unowned self] in self.starts += 1 }
    }

    @Test func elPendienteSeAplicaAlPasarAActiveYNoAntes() async {
        let rig = Rig()
        rig.gate.setReady(true)
        rig.gate.request()                 // llega con la escena .inactive (Centro de control)
        await settle()
        #expect(rig.starts == 0)
        #expect(rig.gate.isPending)
        rig.gate.setActive(true)           // inactive → active
        #expect(await eventually { await MainActor.run { rig.starts == 1 } })
        #expect(!rig.gate.isPending)
    }

    @Test func enFrioEsperaAlChatCableado() async {
        let rig = Rig()
        rig.gate.request()
        rig.gate.setActive(true)
        await settle()
        #expect(rig.starts == 0)           // sin chat aún: no hay a quién abrirle el mic
        rig.gate.setReady(true)
        #expect(await eventually { await MainActor.run { rig.starts == 1 } })
    }

    @Test func enCalienteArrancaYa() async {
        let rig = Rig()
        rig.gate.setReady(true)
        rig.gate.setActive(true)
        rig.gate.request()
        #expect(await eventually { await MainActor.run { rig.starts == 1 } })
    }

    @Test func perderActiveDuranteElRespiroNoArranca() async {
        let rig = Rig()
        rig.gate.setReady(true)
        rig.gate.setActive(true)
        rig.gate.request()
        rig.gate.setActive(false)          // la transición se devolvió antes del respiro
        await settle()
        #expect(rig.starts == 0)
        #expect(rig.gate.isPending)
        rig.gate.setActive(true)
        #expect(await eventually { await MainActor.run { rig.starts == 1 } })
        // Un re-cableado del chat (ready false → true) no re-dispara lo ya hecho.
        rig.gate.setReady(false)
        rig.gate.setReady(true)
        await settle()
        #expect(rig.starts == 1)
    }

    @Test func elDuplicadoDelMismoTapNoAbreDosEscuchas() async {
        let rig = Rig()
        rig.gate.setReady(true)
        rig.gate.request()                 // intent en la app…
        rig.gate.request()                 // …y el OpenURLIntent
        rig.gate.setActive(true)
        #expect(await eventually { await MainActor.run { rig.starts == 1 } })
        rig.clock.addTimeInterval(1)
        rig.gate.request()                 // llega tarde, dentro de la ventana
        await settle()
        #expect(rig.starts == 1)
        rig.clock.addTimeInterval(5)
        rig.gate.request()                 // otro tap de verdad
        #expect(await eventually { await MainActor.run { rig.starts == 2 } })
    }

    @Test func unPedidoViejoCaduca() async {
        let rig = Rig()
        rig.gate.request()
        rig.clock.addTimeInterval(120)     // la app nunca llegó a activarse
        #expect(!rig.gate.isPending)
        rig.gate.setReady(true)
        rig.gate.setActive(true)
        await settle()
        #expect(rig.starts == 0)
        #expect(TalkLaunchGate.defaultSettle == .milliseconds(350))
        _ = TalkLaunchGate { }             // defaults reales construyen
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Campo build 27: el intent pedía el mic con OpenURLIntent(anima://…) e iOS lo
/// rechazaba. Ahora lo pide directo a la app, sin URL.
@Suite("Hablar con Anima — el intent pide el mic sin URL")
struct TalkRequestBridgeTests {
    @Test func conLaAppCableadaElPedidoLlegaDirecto() async {
        let bridge = TalkRequestBridge()
        let calls = Locked(0)
        await bridge.install { calls.mutate { $0 += 1 } }
        await bridge.request()
        #expect(calls.value == 1)
        #expect(!bridge.hasPending)
    }

    @Test func enFrioElPedidoEsperaAlHandlerYSeEntregaUnaVez() async {
        let bridge = TalkRequestBridge()
        await bridge.request()               // el perform corrió antes que App.init
        await bridge.request()
        #expect(bridge.hasPending)
        let calls = Locked(0)
        await bridge.install { calls.mutate { $0 += 1 } }
        #expect(calls.value == 1)
        #expect(!bridge.hasPending)
        await bridge.install { calls.mutate { $0 += 10 } }   // re-instalar no re-entrega
        #expect(calls.value == 1)
        #expect(TalkRequestBridge.shared !== bridge)
    }
}
