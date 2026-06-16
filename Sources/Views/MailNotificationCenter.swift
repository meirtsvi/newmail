import SwiftUI

/// The stack of new-mail popups shown in the floating top-right panel.
struct NotificationStackView: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(vm.notifications) { note in
                MailNotificationCard(note: note)
            }
        }
        .padding(12)
    }
}

/// A single new-mail card: sender, subject, snippet, and a Reply button that
/// expands into an inline plain-text reply editor.
private struct MailNotificationCard: View {
    @Environment(MailboxViewModel.self) private var vm
    let note: MailNotification

    @State private var replying = false
    @State private var replyText = ""
    @State private var sending = false
    @FocusState private var replyFocused: Bool

    private var header: MessageHeader { note.header }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                // Tapping the message area opens the app focused on this message.
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(header.subject.isEmpty ? "(no subject)" : header.subject)
                            .font(.headline)
                            .lineLimit(1)
                        Text(header.from.display)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(header.snippet)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await vm.focusMessage(note) } }

                Button { vm.dismissNotification(note.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if replying {
                replyEditor
            } else {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        Task { await vm.deleteNotification(note) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                    Button {
                        vm.cancelAutoDismiss(note.id)
                        replying = true
                        replyFocused = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
    }

    private var replyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To \(header.from.display)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextEditor(text: $replyText)
                .font(.body)
                .frame(height: 80)
                .focused($replyFocused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Cancel") {
                    replying = false
                    replyText = ""
                }
                .controlSize(.small)
                Spacer()
                Button {
                    sending = true
                    Task {
                        await vm.sendQuickReply(note, text: replyText)
                        sending = false
                    }
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Label("Send", systemImage: "paperplane.fill") }
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
