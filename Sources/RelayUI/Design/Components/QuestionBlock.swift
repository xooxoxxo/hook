import RelayCore
import SwiftUI

/// What a step's question block needs: the question, the sent answer, and the draft
/// binding into the model (memory only). `readOnly` on a closed ask (R5).
public struct StepQuestion {
    public var question: Question
    public var answer: Answer?
    public var draft: Binding<AnswerDraft?>
    public var readOnly: Bool

    public init(question: Question, answer: Answer?, draft: Binding<AnswerDraft?>, readOnly: Bool) {
        self.question = question
        self.answer = answer
        self.draft = draft
        self.readOnly = readOnly
    }

    /// The draft if there is one, else the sent answer: what a control starts from.
    var current: AnswerDraft? { draft.wrappedValue ?? AnswerDrafts.draft(of: answer) }

    var picks: [String] {
        if case .picked(let picks)? = current { return picks }
        return []
    }

    var isUnsent: Bool { AnswerDrafts.isUnsent(draft.wrappedValue, question: question, answer: answer) }
}

/// Design/QuestionBlock: a step's question under its text and above its sub-steps.
/// The prompt, then a stock control (segmented or radio pick, checkboxes, or a text field),
/// then the answered line and "Not sent" for a draft that differs from it. Read-only: the
/// answered line, or "Not answered", and no control.
public struct QuestionBlock: View {
    let model: StepQuestion

    public init(_ model: StepQuestion) {
        self.model = model
    }

    private var question: Question { model.question }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.stepPart) {
            Text(verbatim: prose(question.prompt))
                .font(DS.Font.prose)
                .foregroundStyle(DS.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.readOnly { control }
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var control: some View {
        if question.isFreeText {
            // The owner's own text is not sanitized while editing.
            TextField("Your answer", text: textBinding, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(line(question.prompt))
        } else if question.allowsMany {
            VStack(alignment: .leading, spacing: DS.Space.stepPart) {
                ForEach(question.options, id: \.self) { choice in
                    Toggle(line(choice), isOn: pickBinding(choice))
                        .toggleStyle(.checkbox)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(line(question.prompt))
        } else if AnswerDrafts.usesSegments(question) {
            Picker(selection: singleBinding) {
                ForEach(question.options, id: \.self) { choice in
                    Text(verbatim: line(choice)).tag(Optional(choice))
                }
            } label: {
                Text(verbatim: line(question.prompt))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } else {
            Picker(selection: singleBinding) {
                ForEach(question.options, id: \.self) { choice in
                    Text(verbatim: line(choice)).tag(Optional(choice))
                }
            } label: {
                Text(verbatim: line(question.prompt))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusLine: some View {
        let unsent = !model.readOnly && model.isUnsent
        if model.answer != nil || unsent || model.readOnly {
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
    }

    /// A single pick: the draft's pick, else the sent one; nil (nothing selected) before either.
    private var singleBinding: Binding<String?> {
        Binding(get: { model.picks.first },
                set: { model.draft.wrappedValue = $0.map { .picked([$0]) } })
    }

    /// One checkbox of a multi pick; the picks stay in choice order.
    private func pickBinding(_ choice: String) -> Binding<Bool> {
        let options = question.options
        return Binding(
            get: { model.picks.contains(choice) },
            set: { on in
                var picks = Set(model.picks)
                if on { picks.insert(choice) } else { picks.remove(choice) }
                model.draft.wrappedValue = .picked(options.filter(picks.contains))
            })
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
