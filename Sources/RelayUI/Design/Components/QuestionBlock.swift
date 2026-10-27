import RelayCore
import SwiftUI

/// What a step's question block needs: the question, the sent answer, and the draft
/// binding into the model (memory only). `readOnly` on a closed ask (R5).
public struct StepQuestion {
    public var question: Question
    public var answer: Answer?
    public var draft: Binding<AnswerDraft?>
    public var readOnly: Bool
    /// The block's own Send: sends this step's answer only.
    public var onSend: () -> Void
    /// An answers send for this ask is in flight.
    public var sending: Bool

    public init(question: Question, answer: Answer?, draft: Binding<AnswerDraft?>, readOnly: Bool,
                sending: Bool = false, onSend: @escaping () -> Void = {}) {
        self.question = question
        self.answer = answer
        self.draft = draft
        self.readOnly = readOnly
        self.sending = sending
        self.onSend = onSend
    }

    /// The draft if there is one, else the sent answer: what a control starts from.
    var current: AnswerDraft? { draft.wrappedValue ?? AnswerDrafts.draft(of: answer) }

    var picks: [String] {
        if case .picked(let picks)? = current { return picks }
        return []
    }

    var isUnsent: Bool { AnswerDrafts.isUnsent(draft.wrappedValue, question: question, answer: answer) }

    /// Send is on while the draft would send something new and no send is out.
    var canSend: Bool { !readOnly && !sending && isUnsent }
}

/// Design/QuestionBlock: a step's question under its text and above its sub-steps.
/// The prompt, then the control (OptionRows for a pick, single or multi, or a text field),
/// then the answered line or "Not sent", and the block's own Send (Return sends in the
/// field). Read-only: the answered line, or "Not answered", and no control.
public struct QuestionBlock: View {
    let model: StepQuestion

    public init(_ model: StepQuestion) {
        self.model = model
    }

    private var question: Question { model.question }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.inline) {
            Text(verbatim: prose(question.prompt))
                .font(DS.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            if !model.readOnly { control }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var control: some View {
        if question.isFreeText {
            // The owner's own text is not sanitized while editing.
            TextField("Your answer", text: textBinding, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if model.canSend { model.onSend() } }
                .accessibilityLabel(line(question.prompt))
        } else {
            OptionRows(prompt: question.prompt, options: question.options, multi: question.allowsMany,
                       selected: Set(question.options.indices.filter { model.picks.contains(question.options[$0]) }),
                       onPick: pick)
        }
    }

    /// The status on the left, Send on the right (not on a closed ask).
    @ViewBuilder private var footer: some View {
        if model.readOnly {
            statusLine
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
                statusLine
                Spacer(minLength: DS.Space.inline)
                if model.sending {
                    ProgressView().controlSize(DS.Control.inline).accessibilityLabel("Sending")
                } else {
                    Button("Send", action: model.onSend)
                        .controlSize(DS.Control.form)
                        .disabled(!model.canSend)
                        .help(question.isFreeText ? "Send this answer (Return)" : "Send this answer")
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        let unsent = !model.readOnly && model.isUnsent
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.inline) {
            if let answer = model.answer {
                Label {
                    Text(verbatim: line(AnswerDrafts.answeredText(answer)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: DS.Symbol.answered).foregroundStyle(DS.Color.done)
                }
                .foregroundStyle(DS.Color.secondary)
            } else if model.readOnly {
                Text("Not answered").foregroundStyle(DS.Color.secondary)
            }
            if unsent {
                Text("Not sent").foregroundStyle(DS.Color.warn)
            }
        }
        .font(DS.Font.caption)
    }

    private func pick(_ index: Int) {
        if let next = AnswerDrafts.pick(index, in: question, picks: model.picks) { model.draft.wrappedValue = next }
    }

    /// Free text: the draft, else the sent text. Clearing a never-answered field keeps no draft.
    private var textBinding: Binding<String> {
        let hasAnswer = model.answer != nil
        return Binding(
            get: {
                if case .text(let text)? = model.current { return text }
                return ""
            },
            set: { text in
                model.draft.wrappedValue = text.isEmpty && !hasAnswer ? nil : .text(text)
            })
    }
}
