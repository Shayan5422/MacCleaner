import AppKit
import SwiftUI

/// Confirmation, then progress and output, of an official cleanup command.
struct DeveloperCommandSheet: View {
    @Bindable var model: DeveloperToolsViewModel

    var body: some View {
        if model.commandRun != nil {
            DeveloperCommandOutputSheet(model: model)
        } else if let item = model.pendingCommand {
            DeveloperCommandConfirmationSheet(
                item: item,
                onRun: { model.runCommand(item) },
                onCancel: { model.pendingCommand = nil }
            )
        }
    }
}

/// Confirmation before an official cleanup command runs. Shows the exact command.
struct DeveloperCommandConfirmationSheet: View {
    let item: DeveloperItem
    var onRun: () -> Void
    var onCancel: () -> Void

    @State private var acknowledged = false

    private var isCaution: Bool { item.safety == .caution }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: isCaution ? "exclamationmark.triangle.fill" : "terminal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isCaution ? Color.red : AppSection.developer.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }

            Text(item.explanation)
                .fixedSize(horizontal: false, vertical: true)

            if let command = item.command {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Cleaner will run this command:")
                        .font(.callout.weight(.medium))
                    HStack(alignment: .top) {
                        Text(command.commandLine)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command.commandLine, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy command")
                        .accessibilityLabel("Copy command")
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("Runs \(PathUtilities.abbreviate(command.executable)) as you, without administrator rights, in your home folder. Files it removes don’t go to the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InfoCallout(style: .info, title: "Afterwards", message: item.regeneration)
            if let warning = item.warning {
                InfoCallout(style: isCaution ? .danger : .warning, message: warning)
            }
            if item.requiresAcknowledgement {
                Toggle("I understand this can’t be undone", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run Command", action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(isCaution ? .red : AppSection.developer.tint)
                    .disabled(item.requiresAcknowledgement && !acknowledged)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var subtitle: String {
        guard item.bytes > 0 else { return item.tool.title }
        return "\(item.tool.title) · \(item.sizeIsUpperBound ? "up to" : "about") \(ByteFormatting.string(item.bytes))"
    }
}

/// Progress and output of a running or finished cleanup command.
struct DeveloperCommandOutputSheet: View {
    @Bindable var model: DeveloperToolsViewModel

    var body: some View {
        if let run = model.commandRun {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    statusIcon(run)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(run)).font(.title3.weight(.semibold))
                        Text(run.command.commandLine)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }

                if run.isRunning {
                    TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                        Text("Running for \(DateFormatting.duration(context.date.timeIntervalSince(run.startedAt))). Some cleanups take a few minutes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        Text(output(run))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 160, maxHeight: 280)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if run.isMeasuring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Measuring again…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let freed = run.freedBytes, run.item.bytes > 0 {
                        InfoCallout(style: .success, message: freed > 0 ? "Freed about \(ByteFormatting.string(freed))." : "The command finished; no measurable space was freed.")
                    }
                }

                HStack {
                    if run.isRunning {
                        Button("Stop", role: .cancel) { model.stopCommand() }
                    }
                    Spacer()
                    Button("Done") { model.dismissCommandRun() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(run.isRunning)
                }
            }
            .padding(24)
            .frame(width: 600)
            .interactiveDismissDisabled(run.isRunning)
        }
    }

    @ViewBuilder
    private func statusIcon(_ run: DeveloperCommandRun) -> some View {
        if run.isRunning {
            ProgressView().controlSize(.regular).frame(width: 30, height: 30)
        } else {
            Image(systemName: run.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(run.succeeded ? .green : .orange)
                .accessibilityHidden(true)
        }
    }

    private func title(_ run: DeveloperCommandRun) -> String {
        switch run.state {
        case .running: return "Running \(run.item.title)…"
        case .finished(let result):
            if result.timedOut { return "The command took too long and was stopped" }
            return result.succeeded ? "Finished" : "The command reported an error"
        case .failed: return "The command couldn’t run"
        case .stopped: return "Stopped"
        }
    }

    private func output(_ run: DeveloperCommandRun) -> String {
        switch run.state {
        case .running:
            return ""
        case .finished(let result):
            let lines = result.combinedOutput.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(400).joined(separator: "\n")
            let text = tail.isEmpty ? "(No output)" : tail
            return result.succeeded ? text : text + "\n\nExit code \(result.exitCode)."
        case .failed(let message):
            return message
        case .stopped:
            return "The command was stopped before it finished. Anything it already removed is gone; the rest is untouched."
        }
    }
}
