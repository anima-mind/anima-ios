// TalkRequestBridge.swift — "Hablar con Anima" (control, App Shortcut, Siri)
// pide el mic DIRECTO al proceso de la app, sin URL. Campo build 27: el intent
// devolvía OpenURLIntent(anima://chat?mic=1) y iOS lo rechazaba ("The provided
// URL scheme `anima` is unsupported; launch is prohibited"): la app abría, la
// URL nunca llegaba y el mic no arrancaba.
//
// La app instala `handler` al lanzar. Si el perform corre antes de eso (el
// intent despertó el proceso en frío), el pedido queda pendiente y se entrega
// al instalarlo. En la extensión nadie lo instala y no pasa nada.

import Foundation

public final class TalkRequestBridge: @unchecked Sendable {
    public static let shared = TalkRequestBridge()

    private let lock = NSLock()
    private var installed: (@Sendable () async -> Void)?
    private var pending = false

    public init() {}

    /// ¿Hay un pedido esperando a que la app instale el handler?
    public var hasPending: Bool { lock.withLock { pending } }

    /// La app: instala el handler y entrega lo que llegó antes.
    public func install(_ handler: @escaping @Sendable () async -> Void) async {
        let deliver = lock.withLock { () -> Bool in
            installed = handler
            defer { pending = false }
            return pending
        }
        if deliver { await handler() }
    }

    /// El intent: pide el mic (o lo deja pendiente si la app aún no cableó).
    public func request() async {
        let handler = lock.withLock { () -> (@Sendable () async -> Void)? in
            if installed == nil { pending = true }
            return installed
        }
        if let handler { await handler() }
    }
}
