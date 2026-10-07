import Foundation
import Testing
import GRDB
@testable import AnimaKit

/// 0xdead10cc: la base del App Group se suspende al quedar sin dueños y se
/// reanuda antes de cualquier acceso (primer plano, BGTask, acción).
@Suite struct DatabaseSuspensionTests {

    static func make() -> (DatabaseSuspension, Locked<[String]>) {
        let posted = Locked<[String]>([])
        let suspension = DatabaseSuspension(post: { name in
            posted.mutate { $0.append(name == Database.suspendNotification ? "suspend" : "resume") }
        })
        return (suspension, posted)
    }

    @Test func appDatabaseObservesSuspensionNotifications() throws {
        let queue = try AnimaDatabase.temporary()
        #expect(queue.configuration.observesSuspensionNotifications)
        try queue.close()
    }

    @Test func backgroundSuspendsAfterTheFlushAndForegroundResumes() async {
        let (suspension, posted) = Self.make()
        suspension.enterForeground()
        suspension.enterForeground()
        #expect(posted.value.isEmpty)
        suspension.enterBackground()
        #expect(!suspension.isSuspended)
        suspension.end()
        #expect(posted.value == ["suspend"])
        #expect(suspension.isSuspended)
        suspension.enterForeground()
        #expect(posted.value == ["suspend", "resume"])
        #expect(!suspension.isSuspended)
    }

    @Test func aRunningBackgroundTaskKeepsTheDatabaseAwake() async {
        let (suspension, posted) = Self.make()
        suspension.enterForeground()
        suspension.begin()
        suspension.enterBackground()
        suspension.end()
        #expect(posted.value.isEmpty)
        suspension.end()
        #expect(posted.value == ["suspend"])
    }

    @Test func backgroundWakeResumesAndSuspendsAgainWhenDone() async {
        let (suspension, posted) = Self.make()
        suspension.enterBackground()
        suspension.end()
        let value = await suspension.awake { () -> Int in
            #expect(!suspension.isSuspended)
            return 7
        }
        #expect(value == 7)
        #expect(posted.value == ["suspend", "resume", "suspend"])
    }

    @Test func expirationSuspendsImmediatelyEvenWithWorkInFlight() async {
        let (suspension, posted) = Self.make()
        suspension.begin()
        suspension.expire()
        suspension.expire()
        #expect(posted.value == ["suspend"])
        suspension.end()
        #expect(posted.value == ["suspend"])
        suspension.begin()
        #expect(posted.value == ["suspend", "resume"])
    }

    /// Un BGTask que expira con la app abierta no suspende la base bajo el chat.
    @Test func expirationWithTheAppInForegroundNeverSuspends() {
        let (suspension, posted) = Self.make()
        suspension.enterForeground()
        suspension.begin()
        suspension.expire()
        suspension.end()
        #expect(!suspension.isSuspended)
        #expect(posted.value.isEmpty)
        // Ya en background, la expiración sí suspende.
        suspension.begin()
        suspension.enterBackground()
        suspension.end()
        suspension.expire()
        #expect(suspension.isSuspended)
        suspension.end()
        #expect(posted.value == ["suspend"])
    }

    /// background → inactive/active antes de que termine el vaciado: la escena
    /// recupera su hold y el fin del vaciado no suspende la base abierta.
    @Test func returningToForegroundBeforeTheFlushEndsKeepsTheDatabaseAwake() {
        let (suspension, posted) = Self.make()
        suspension.enterForeground()
        suspension.enterBackground()
        suspension.enterForeground()
        suspension.enterForeground()
        suspension.end()
        #expect(!suspension.isSuspended)
        #expect(posted.value.isEmpty)
        suspension.enterBackground()
        suspension.end()
        #expect(suspension.isSuspended)
    }

    @Test func endWithoutBeginNeverGoesNegative() {
        let (suspension, posted) = Self.make()
        suspension.end()
        suspension.end()
        suspension.begin()
        #expect(posted.value == ["suspend", "resume"])
        #expect(DatabaseSuspension.shared.isSuspended == false)
    }
}
