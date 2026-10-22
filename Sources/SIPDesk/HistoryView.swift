import SwiftUI
import SIPCore

struct HistoryView: View {
    @EnvironmentObject private var model: SoftphoneModel
    @State private var query = ""
    @State private var missedOnly = false
    @State private var confirmClear = false

    private var filtered: [CallRecord] {
        model.history.filter {
            (!missedOnly || $0.outcome == .missed) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.remoteURI.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField(L("Find a number or name"), text: $query).textFieldStyle(.plain)
                    }.padding(10).background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
                    Toggle(L("Missed calls"), isOn: $missedOnly).toggleStyle(.checkbox).font(.system(size: 12))
                    Button { confirmClear = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).disabled(model.history.isEmpty).help(L("Clear history"))
                }
                if filtered.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: model.history.isEmpty ? L("History starts with your first call") : L("No calls found"),
                               detail: L("Incoming, outgoing and missed calls in one place."))
                        .frame(minHeight: 340)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { record in
                            Button { model.selectRecent(record) } label: { RecentCallRow(record: record, compact: false).padding(.vertical, 13) }
                                .buttonStyle(.plain).disabled(model.call != nil)
                                .help(L("Insert the number into the keypad without calling automatically"))
                            if record.id != filtered.last?.id { Divider().overlay(Theme.border) }
                        }
                    }
                }
            }
        }.confirmationDialog(L("Clear all call history on this Mac?"), isPresented: $confirmClear) {
            Button(L("Clear history"), role: .destructive) { model.clearHistory() }
        } message: { Text(L("Local records will be deleted, but not the SIP server log.")) }
    }
}

struct RecentCallRow: View {
    let record: CallRecord
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            Image(systemName: record.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(record.outcome == .missed ? Theme.danger : Theme.accent)
                .frame(width: compact ? 33 : 39, height: compact ? 33 : 39)
                .background(record.outcome == .missed ? Theme.danger.opacity(0.07) : Theme.paleAccent, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: compact ? 12 : 14, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(record.outcome == .answered ? record.direction.title : record.outcome.title)
                    .font(.system(size: 10)).foregroundStyle(record.outcome == .missed ? Theme.danger : Theme.muted)
            }
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 5) {
                Text(record.startedAt, format: compact ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                if !compact && record.outcome == .answered {
                    Text(CallRecord.formattedDuration(record.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

