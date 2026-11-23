import SwiftUI
import AppPreferences
import LocalStreamProxy

@main
struct AuraTVApp: App {
    private let settings = AppSettings()
    private let proxyInfo = LocalStreamProxyInfo()

    var body: some Scene {
        WindowGroup {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.043, green: 0.055, blue: 0.078),
                        Color(red: 0.078, green: 0.098, blue: 0.137)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 28) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 84, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("AuraTV Phase 0 Ready")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(.white)

                    Text("MediaCoreKit \(proxyInfo.version) · Cache \(settings.readAheadCacheLimitMB) MB · MX Seek Ready")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(60)
            }
        }
    }
}
