import AppKit
import RelayCore
import SwiftUI

// Design/Setup: the setup window's parts. The footer (dots over a full-width Continue,
// Back beside it after the first page) and the hero; the pages' rows are `SetupRow`s
// in a grouped Form, System Settings style.

/// Progress dots: the current page in the accent colour. One element for VoiceOver.
public struct SetupDots: View {
    let page: Int
    let count: Int

    public init(page: Int, count: Int) {
        self.page = page
        self.count = count
    }

    public var body: some View {
        HStack(spacing: DS.Space.inline) {
            ForEach(1...max(count, 1), id: \.self) { n in
                Circle()
                    .fill(n == page ? AnyShapeStyle(DS.Color.dotCurrent) : DS.Color.dotOther)
                    .frame(width: DS.Metric.setupDot, height: DS.Metric.setupDot)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Self.accessibilityText(page: page, count: count))
    }

    public static func accessibilityText(page: Int, count: Int) -> String { "Page \(page) of \(count)" }
}

/// The setup footer: dots, then Back (after the first page) and a full-width Continue.
public struct SetupFooter: View {
    let page: Int
    let count: Int
    let title: String
    let showsBack: Bool
    let busy: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    public init(page: Int, count: Int, title: String = "Continue", showsBack: Bool, busy: Bool = false,
                onBack: @escaping () -> Void, onContinue: @escaping () -> Void) {
        self.page = page
        self.count = count
        self.title = title
        self.showsBack = showsBack
        self.busy = busy
        self.onBack = onBack
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(spacing: DS.Space.setupFooter) {
            SetupDots(page: page, count: count)
            HStack(spacing: DS.Space.inline) {
                if showsBack {
                    Button("Back", action: onBack)
                        .keyboardShortcut(.cancelAction)
                        .disabled(busy)
                }
                Button(action: onContinue) {
                    HStack(spacing: DS.Space.inline) {
                        if busy {
                            ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Connecting")
                        }
                        Text(title)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
            .controlSize(DS.Control.action)
        }
        .padding(.horizontal, DS.Space.setupPad)
        .padding(.bottom, DS.Space.setupPad)
    }
}

/// The app icon, or a symbol placeholder while the bundle has none. It bounces once on
/// appear, unless Reduce Motion is on.
public struct SetupAppIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    public init() {}

    public var body: some View {
        Group {
            if Self.bundleHasIcon {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: DS.Metric.appIcon, height: DS.Metric.appIcon)
            } else {
                RoundedRectangle(cornerRadius: DS.Metric.appIconRadius, style: .continuous)
                    .fill(LinearGradient(colors: [DS.Color.appIconTop, DS.Color.appIconBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: DS.Metric.appIcon, height: DS.Metric.appIcon)
                    .overlay {
                        Image(systemName: DS.Symbol.menuBar)
                            .font(DS.Font.appSymbol)
                            .foregroundStyle(DS.Color.appIconSymbol)
                            .symbolEffect(.bounce, value: bounce)
                    }
            }
        }
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { bounce += 1 } }
    }

    static var bundleHasIcon: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
            || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil
    }
}

/// A centred page: the icon (or a symbol), the title and one line.
public struct SetupHero<Icon: View, Extra: View>: View {
    let title: String
    let line: String
    let icon: Icon
    let extra: Extra

    public init(title: String, line: String, @ViewBuilder icon: () -> Icon, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.line = line
        self.icon = icon()
        self.extra = extra()
    }

    public var body: some View {
        VStack(spacing: DS.Space.step) {
            Spacer(minLength: 0)
            icon
            Text(title)
                .font(DS.Font.welcomeTitle)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(DS.Font.prose)
                .foregroundStyle(DS.Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Space.setupPad)
        .padding(.top, DS.Space.setupPad)
    }
}

/// The Done page's symbol: a large tick that bounces once, unless Reduce Motion is on.
public struct SetupDoneSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    public init() {}

    public var body: some View {
        Image(systemName: DS.Symbol.setupDone)
            .font(DS.Font.heroSymbol)
            .foregroundStyle(DS.Color.done)
            .symbolEffect(.bounce, value: bounce)
            .accessibilityHidden(true)
            .onAppear { if !reduceMotion { bounce += 1 } }
    }
}

/// A form page's heading: the title and one line, as the first section's header.
public struct SetupHeading: View {
    let title: String
    let line: String

    public init(_ title: String, line: String) {
        self.title = title
        self.line = line
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.rowLine) {
            Text(title)
                .font(DS.Font.welcomeTitle)
                .foregroundStyle(DS.Color.primary)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(DS.Font.prose)
                .foregroundStyle(DS.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
        .padding(.bottom, DS.Space.inline)
    }
}

/// One setup row: a symbol and the title (its "?" after it), the control on the trailing
/// edge, and a status or error caption under the control.
public struct SetupRow<Control: View>: View {
    let symbol: String
    let title: String
    let help: String?
    let error: String?
    let control: Control

    public init(_ title: String, symbol: String, help: String? = nil, error: String? = nil,
                @ViewBuilder control: () -> Control) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.error = error
        self.control = control()
    }

    public var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: DS.Space.rowLine) {
                control
                if let error {
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.error)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            HStack(spacing: DS.Space.inline) {
                Image(systemName: symbol)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: DS.Metric.setupSymbol)
                    .accessibilityHidden(true)
                Text(title)
                if let help {
                    HelpButton(rowLabel: title, text: help)
                }
            }
        }
    }
}

/// A row's done mark: a green tick and a word ("Connected", "Installed").
public struct SetupDone: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Label {
            Text(text).foregroundStyle(DS.Color.secondary)
        } icon: {
            Image(systemName: DS.Symbol.answered).foregroundStyle(DS.Color.done)
        }
    }
}
