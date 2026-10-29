import RelayCore
import SwiftUI

/// Hook's About window: the icon, name and version, the project link, Support Hook (only
/// for a valid donation link) and Run Setup Again…, the way back into the setup window
/// once Hook is set up.
public struct AboutView: View {
    let version: String
    let build: String?
    let supportURL: URL?
    let onRunSetup: () -> Void
    @Environment(\.openURL) private var openURL

    public init(version: String, build: String? = nil, supportURL: URL? = ConnectInfo.donationLink(),
                onRunSetup: @escaping () -> Void) {
        self.version = version
        self.build = build
        self.supportURL = supportURL
        self.onRunSetup = onRunSetup
    }

    public var body: some View {
        VStack(spacing: DS.Space.inline) {
            SetupAppIcon()
            Text("Hook")
                .font(DS.Font.welcomeTitle)
                .accessibilityAddTraits(.isHeader)
            Text(Self.versionLine(version: version, build: build))
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.secondary)
                .textSelection(.enabled)
            if let project = ConnectInfo.projectLink {
                Link(ConnectInfo.projectLabel, destination: project)
                    .font(DS.Font.meta)
            }
            HStack(spacing: DS.Space.inline) {
                if let supportURL {
                    Button {
                        openURL(supportURL)
                    } label: {
                        Label("Support Hook", systemImage: DS.Symbol.setupSupport)
                    }
                }
                Button("Run Setup Again…", action: onRunSetup)
            }
            .controlSize(DS.Control.form)
            .padding(.top, DS.Space.step)
        }
        .padding(DS.Space.setupPad)
        .frame(width: DS.Metric.aboutWidth)
    }

    /// "Version 0.9.3", with the build in parentheses only when it differs.
    public static func versionLine(version: String, build: String?) -> String {
        guard let build, !build.isEmpty, build != version else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }
}
