import SwiftUI
import TokenBarCore

/// Fleet mode separates source selection from the analysis lenses below it.
/// The original runtime retains its scrolling/drag-reordering row.
///
/// Client tab row (Overview + one tab per present client), port of
/// DashboardTabs.tsx: horizontal scroll, active tab kept in view. SVG agent
/// icons arrive in a later phase — tabs show a brand-color disc with the
/// client's initial, the registry fallback the web app uses for icon-less
/// agents.
///
/// Client tabs are drag-reorderable in place; the drop writes the same
/// `tabOrderKey` the settings list and the quota cards share. Overview is
/// pinned first — it is neither draggable nor a drop target, so no drag can
/// move a client ahead of it.
struct DashboardTabs: View {
    /// Clients currently visible in the row.
    let clients: [String]
    /// Every currently present client, including tabs hidden from this row.
    let presentClients: [String]
    @Binding var active: String
    /// Show ⌘1…⌘9 pins while Cmd is held (the discoverability overlay).
    var kbdHints = false

    /// Shared client order (top tabs + quota cards). Written on drop, and
    /// observed so the row re-sorts the instant a reorder lands.
    @AppStorage(ClientRegistry.tabOrderKey) private var orderRaw = ""

    // Drag state, scoped to this row.
    @SyrtisState private var dragId: String?
    @SyrtisState private var overId: String?
    @SyrtisState private var tabFrames: [String: CGRect] = [:]
    @Namespace private var thumb

    private static let dragSpace = "client-tabs-row"

    private struct TabFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    var body: some View {
        if FleetMode.enabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("数据来源")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { active = "overview" } label: {
                        HStack(spacing: 5) {
                            Image(systemName: active == "overview" ? "checkmark.circle.fill" : "square.grid.2x2")
                            Text("全部 Agent")
                            if kbdHints { Text("⌘1").font(.caption2.monospacedDigit()) }
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                    }
                    .buttonStyle(FleetSourceButtonStyle(selected: active == "overview"))
                    .accessibilityAddTraits(active == "overview" ? .isSelected : [])
                    .help("汇总所有已显示的 Agent")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(clients.enumerated()), id: \.element) { i, id in
                        Button { active = id } label: {
                            HStack(spacing: 5) {
                                AgentIconView(clientId: id, size: 14)
                                Text(id == "agy" ? "Antigravity" : ClientRegistry.tabLabel(id))
                                    .font(.system(size: 11, weight: active == id ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                                Spacer(minLength: 0)
                                if kbdHints && i + 2 <= 9 {
                                    Text("⌘\(i + 2)").font(.system(size: 9).monospacedDigit())
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .semibold))
                                        .opacity(active == id ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 7)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(FleetSourceButtonStyle(selected: active == id))
                        .accessibilityLabel(ClientRegistry.tabLabel(id))
                        .accessibilityAddTraits(active == id ? .isSelected : [])
                        .help(ClientRegistry.tabLabel(id) + " · 右键调整顺序")
                        .contextMenu {
                            Button("向前移动") { moveClient(id, by: -1) }.disabled(i == 0)
                            Button("向后移动") { moveClient(id, by: 1) }.disabled(i == clients.count - 1)
                        }
                    }
                }
            }
            .padding(10)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.07)))
            .fixedSize(horizontal: false, vertical: true)
        } else {
            scrollingTabs
        }
    }

    private func moveClient(_ id: String, by offset: Int) {
        guard let index = clients.firstIndex(of: id),
              clients.indices.contains(index + offset) else { return }
        let full = Self.completeOrder(ClientRegistry.parseIdList(orderRaw), present: presentClients)
        orderRaw = ClientRegistry.mergeReorder(
            full: full, visible: clients, from: id, to: clients[index + offset])
            .joined(separator: ",")
    }

    private var scrollingTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tab(id: "overview", label: "Overview".localized, color: nil, index: 1)
                    ForEach(Array(clients.enumerated()), id: \.element) { i, id in
                        let style = ClientRegistry.style(id)
                        tab(
                            id: id, label: ClientRegistry.tabLabel(id),
                            color: style.color, index: i + 2)
                            // Only client tabs publish a frame, so Overview can
                            // never be picked as a drop target.
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TabFramesKey.self,
                                        value: [id: geo.frame(in: .named(Self.dragSpace))])
                                })
                            .opacity(dragId == id ? 0.5 : 1)
                            .overlay(alignment: dropAlignment(for: id)) {
                                if let edge = dropEdge(for: id) {
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: 2)
                                        .padding(.vertical, 1)
                                        .offset(x: edge == .leading ? -3 : 3)
                                }
                            }
                            .help("Drag to reorder")
                            // Once the pointer has moved far enough to recognize
                            // a drag, it takes precedence over the Button press.
                            // A normal click still uses the native control path.
                            .highPriorityGesture(dragGesture(for: id))
                    }
                }
                .panelSelectionSlide(active)
                .coordinateSpace(name: Self.dragSpace)
                .onPreferenceChange(TabFramesKey.self) { tabFrames = $0 }
                // Let a plain vertical mouse wheel scroll this horizontal row.
                .background(HorizontalWheelScroll())
            }
            .onChange(of: active) { _, next in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(next, anchor: nil)
                }
            }
        }
    }

    private func tab(id: String, label: String, color: String?, index: Int) -> some View {
        Button {
            active = id
        } label: {
            HStack(spacing: 5) {
                if color != nil {
                    AgentIconView(clientId: id, size: 14)
                }
                Text(label)
                    .font(.caption.weight(active == id ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                if kbdHints && index <= 9 {
                    Text("⌘\(index)")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .foregroundStyle(active == id ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(SelectionBackground(
                isSelected: active == id, shape: Capsule(), namespace: thumb))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active == id ? .isSelected : [])
        .id(id)
    }

    // MARK: - Drag reorder

    /// Fill an incomplete persisted order with current clients before a visible-
    /// subset reorder, so a hidden tab keeps its implicit slot on first drag.
    nonisolated static func completeOrder(_ saved: [String], present: [String]) -> [String] {
        var seen = Set(saved)
        return saved + present.filter { seen.insert($0).inserted }
    }

    /// Which edge of the hovered tab the drop line sits on, matching
    /// `ClientRegistry.reorder`'s direction-aware insert (dragging right drops
    /// after the target, left drops before it). Static and pure so SelfTest can
    /// assert the direction mapping.
    nonisolated static func dropEdge(
        dragId: String?, overId: String?, tabId: String, in clients: [String]
    ) -> HorizontalEdge? {
        guard let dragId, overId == tabId, dragId != tabId,
              let fromI = clients.firstIndex(of: dragId),
              let toI = clients.firstIndex(of: tabId)
        else { return nil }
        return fromI < toI ? .trailing : .leading
    }

    private func dropEdge(for id: String) -> HorizontalEdge? {
        Self.dropEdge(dragId: dragId, overId: overId, tabId: id, in: clients)
    }

    private func dropAlignment(for id: String) -> Alignment {
        dropEdge(for: id) == .leading ? .leading : .trailing
    }

    /// `minimumDistance` keeps a click a click: below the threshold the drag
    /// never starts and the Button's native press selects the tab instead.
    private func dragGesture(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                dragId = id
                let over = tabFrames.first { $0.value.contains(value.location) }?.key
                overId = (over != nil && over != id) ? over : nil
            }
            .onEnded { _ in
                if let over = overId, over != id {
                    // `clients` is a subset of the shared order (it excludes
                    // hidden clients and quota-only ids). Complete a fresh or
                    // partial saved order with present clients first, then merge
                    // the visible reorder so every known off-screen slot survives.
                    let full = Self.completeOrder(
                        ClientRegistry.parseIdList(orderRaw), present: presentClients)
                    let merged = ClientRegistry.mergeReorder(
                        full: full, visible: clients, from: id, to: over)
                    orderRaw = merged.joined(separator: ",")
                }
                dragId = nil
                overId = nil
            }
    }
}


/// Stable mouse targets with distinct hover, pressed and selected states.
private struct FleetSourceButtonStyle: ButtonStyle {
    let selected: Bool
    @SyrtisState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(
                selected ? Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.12)
                    : Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.065 : 0.025),
                in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(hovered ? 0.18 : 0.08)))
            .onHover { hovered = $0 }
    }
}
