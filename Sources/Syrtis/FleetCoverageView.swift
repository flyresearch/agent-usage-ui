import AppKit
import SwiftUI
import UsageCore

struct FleetCoverageView: View {
    let report: CoverageReport
    var body: some View {
        Button {
            FleetCoverageWindowController.shared.show(report: report)
        } label: {
            HStack {
                Label(report.title, systemImage: report.complete ? "checkmark.circle" : "exclamationmark.circle")
                Spacer()
                Text("查看诊断")
                Image(systemName: "chevron.right")
            }
            .font(.caption)
            .foregroundStyle(report.complete ? Color.secondary : Color.orange)
        }
        .buttonStyle(.plain)
    }
}

/// A captured report: refreshing the dashboard cannot move rows while reading.
struct FleetCoverageDetails: View {
    let report: CoverageReport
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("覆盖诊断").font(.headline)
                Spacer()
                Button("返回概览", action: close)
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("以下诊断涵盖所选机器的全部来源和日期，不随图表的 Agent、模型或日期筛选缩小。同步成功不代表历史用量完整。")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(report.unavailableHosts, id: \.self) { host in
                        Text("\(host)：尚无当前配置的可用快照").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(report.sources) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(source.host) / \(source.source)").font(.caption.bold())
                            Text(source.statusLabel + (source.retained ? " · 上次成功快照" : ""))
                                .font(.caption).foregroundStyle(source.hasGap || source.retained ? Color.orange : Color.secondary)
                            Text("来源文件：\(source.files)").font(.caption2).foregroundStyle(.secondary)
                            ForEach(source.details) { detail in
                                HStack(alignment: .top) {
                                    Text(detail.title)
                                    Spacer()
                                    Text(detail.count.formatted()).monospacedDigit()
                                }.font(.caption2).foregroundStyle(detail.isGap ? Color.orange : Color.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                    if report.available && report.current && !report.complete && !report.sources.contains(where: \.hasGap) {
                        Text("来源报告覆盖不完整；当前快照未提供更细的缺口原因。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }.padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 360, minHeight: 280)
    }
}

@MainActor
final class FleetCoverageWindowController: NSObject, NSWindowDelegate {
    static let shared = FleetCoverageWindowController()
    private var window: NSWindow?

    func show(report: CoverageReport) {
        if let popover = NSApp.keyWindow, popover !== window {
            SettingsWindowController.closeForHandoff(popover)
        }
        DispatchQueue.main.async { self.present(report: report) }
    }

    private func present(report: CoverageReport) {
        let window = self.window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let firstShow = self.window == nil
        window.title = "覆盖诊断"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: FleetCoverageDetails(report: report) { [weak window] in
            window?.performClose(nil)
        })
        window.contentMinSize = NSSize(width: 360, height: 280)
        self.window = window
        if firstShow { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the captured report and view tree while the window is hidden.
        window?.contentViewController = nil
        DispatchQueue.main.async { FleetRuntime.shared.showPopover() }
    }
}
