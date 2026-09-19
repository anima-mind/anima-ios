// FirebaseConfigProvider.swift — implementación de RemoteConfigProviding (§4.8)
// con FirebaseRemoteConfig. Reglas duras: snapshot CONGELADO por sesión
// (activar a mitad de sesión invalidaría el prompt cache del prefijo);
// minimumFetchInterval 12h prod / 0 DEBUG; defaults bundled obligatorios
// (RemoteConfigDefaults.plist) para el perfil edge sin red.

import Foundation
import AnimaKit
import FirebaseRemoteConfig

final class FirebaseConfigProvider: RemoteConfigProviding {
    private let frozen: ConfigSnapshot

    init(snapshot: ConfigSnapshot) {
        self.frozen = snapshot
    }

    func snapshot() -> ConfigSnapshot { frozen }

    /// Fetch+activate una vez al arrancar y congela el snapshot para la sesión.
    static func bootstrap() async -> FirebaseConfigProvider {
        let rc = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 12 * 60 * 60
        #endif
        rc.configSettings = settings
        rc.setDefaults(fromPlist: "RemoteConfigDefaults")

        _ = try? await rc.fetchAndActivate()

        let snapshot = buildSnapshot { key in rc.configValue(forKey: key).dataValue }
            stringLookup: { key in rc.configValue(forKey: key).stringValue }
        return FirebaseConfigProvider(snapshot: snapshot)
    }

    /// Construye el ConfigSnapshot desde los parámetros de Remote Config.
    /// Forward-compatible vía ProviderConfigParser (providers/turns futuros se ignoran).
    static func buildSnapshot(dataLookup: (String) -> Data,
                              stringLookup: (String) -> String) -> ConfigSnapshot {
        let providerConfigData = dataLookup("provider_config")
        let parsed = (try? ProviderConfigParser.parse(providerConfigData)) ?? [:]
        var providers: [ModelProvider: ProviderConfig] = [:]
        for (provider, entry) in parsed {
            let base = stringLookup(ProviderConfigParser.promptKey(for: provider))
            providers[provider] = ProviderConfig(systemPromptBase: base, api: entry.api, routes: entry.routes)
        }
        return ConfigSnapshot(providers: providers)
    }
}
