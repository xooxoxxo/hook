import SwiftUI

/// Address, Token file + Choose…, Context: shared by Settings → Queue and Welcome.
/// The three fields start on one x (Token file + inline + Choose… add up to `width`).
public struct MailboxFields: View {
    public static let addressPrompt = "https://mailbox.example:8790"
    public static let tokenHelp = "Hook reads this file only to talk to the mailbox and never shows what it holds."
    public static let contextHelp = "Sent with every request, so one mailbox can serve several Macs or setups. Leave it empty for personal."

    @Binding var address: String
    @Binding var tokenFile: String
    @Binding var context: String
    let addressError: String?
    let tokenFileError: String?
    let onChooseTokenFile: () -> Void
    /// The fields' width: Settings' `fieldWide`, narrower in the setup window.
    let width: CGFloat

    public init(address: Binding<String>, tokenFile: Binding<String>, context: Binding<String>,
                addressError: String?, tokenFileError: String?, width: CGFloat = DS.Metric.fieldWide,
                onChooseTokenFile: @escaping () -> Void) {
        _address = address
        _tokenFile = tokenFile
        _context = context
        self.addressError = addressError
        self.tokenFileError = tokenFileError
        self.onChooseTokenFile = onChooseTokenFile
        self.width = width
    }

    public var body: some View {
        SettingsRow("Address", error: addressError) {
            TextField("Address", text: $address, prompt: Text(Self.addressPrompt))
                .settingsField(width: width)
                .alignmentProbe(.mailboxField)
        }
        SettingsRow("Token file", help: Self.tokenHelp, error: tokenFileError) {
            HStack(spacing: DS.Space.inline) {
                TextField("Token file", text: $tokenFile, prompt: Text("Path to the token file"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .alignmentProbe(.mailboxField)
                Button("Choose…", action: onChooseTokenFile).fixedSize()
            }
            .frame(width: width)
        }
        SettingsRow("Context", help: Self.contextHelp) {
            TextField("Context", text: $context, prompt: Text("personal"))
                .settingsField(width: width)
                .alignmentProbe(.mailboxField)
        }
    }
}
