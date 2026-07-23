// The Life month map (§3.6): season kicker, 88pt month, calendar grid of
// mood-washed cells, legend — and the design's signature move: an entry
// morphs open from its cell (matchedGeometryEffect; fades under Reduce
// Motion). ‹›/arrow keys change months, ESC closes the open entry.
import ReflectCore
import SwiftUI

struct LifeView: View {
    @State private var model = LifeModel()
    @Namespace private var morphSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyMonitor: Any?

    private var morphAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.66)
    }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    weekdayRow.padding(.top, 40)
                    grid.padding(.top, 10)
                    legend.padding(.top, 48)
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 76)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity)
            }

            if let selected = model.selected {
                // Scrim (design: ink 28% + blur behind the opened entry)
                Theme.ink.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { close() }

                EntryReadView(
                    entry: selected,
                    mood: model.days.first { $0.entry?.id == selected.id }?.mood,
                    onClose: { close() },
                    onPrev: { withAnimation(.easeInOut(duration: 0.25)) { model.selectNeighbor(-1) } },
                    onNext: { withAnimation(.easeInOut(duration: 0.25)) { model.selectNeighbor(1) } },
                    onTrash: {
                        try? AppServices.entries.softDelete(id: selected.id)
                        close()
                        model.load()
                    }
                )
                .matchedGeometryEffect(id: selected.id, in: morphSpace)
                .padding(24)
            }
        }
        .background(Theme.paper)
        .onAppear {
            model.load()
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Kicker(text: "\(model.seasonName) · \(model.yearText)")
                Text(model.monthName)
                    .font(Typography.serif(88, weight: .light))
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            HStack(spacing: 6) {
                roundNavButton("chevron.left") { model.shift(-1) }
                roundNavButton("chevron.right") { model.shift(1) }
            }
            .padding(.bottom, 12)
        }
    }

    private func roundNavButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.paper))
                .overlay(Circle().stroke(Theme.hair, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8), count: 7)

    private var weekdayRow: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                Text(day.uppercased())
                    .font(Typography.sans(10))
                    .tracking(1.4)
                    .foregroundStyle(Theme.ink4)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(0..<model.leadingBlanks, id: \.self) { _ in
                Color.clear.frame(height: 1)
            }
            ForEach(model.days) { item in
                if let entry = item.entry, model.selected?.id != entry.id {
                    DayCell(item: item) { open(entry) }
                        .matchedGeometryEffect(id: entry.id, in: morphSpace)
                } else {
                    DayCell(item: item) {
                        if let entry = item.entry { open(entry) }
                    }
                    .opacity(item.entry != nil ? 0 : 1)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 26) {
            legendItem("Photographed") {
                RoundedRectangle(cornerRadius: 1).fill(Theme.ink3)
                    .frame(width: 8, height: 8)
            }
            legendItem("Milestone") {
                Rectangle().fill(Theme.accent)
                    .frame(width: 8, height: 8).rotationEffect(.degrees(45))
            }
            legendItem("Today") {
                RoundedRectangle(cornerRadius: 2).stroke(Theme.accent, lineWidth: 1.4)
                    .frame(width: 10, height: 10)
            }
            Spacer()
        }
        .padding(.top, 26)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    private func legendItem<Mark: View>(
        _ label: String, @ViewBuilder mark: () -> Mark
    ) -> some View {
        HStack(spacing: 9) {
            mark()
            Text(label).font(Typography.sans(11.5)).foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Morph open/close

    private func open(_ entry: Entry) {
        withAnimation(morphAnimation) { model.selected = entry }
    }

    private func close() {
        withAnimation(morphAnimation) { model.selected = nil }
    }

    // MARK: - Keyboard (←/→ months, ESC closes)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53 where model.selected != nil:  // ESC
                close()
                return nil
            case 123 where model.selected == nil:  // ←
                model.shift(-1)
                return nil
            case 124 where model.selected == nil:  // →
                model.shift(1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let item: LifeModel.DayItem
    let action: () -> Void
    @State private var hovering = false

    private static let barWidths: [CGFloat] = [1.0, 0.78, 0.9, 0.64]

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text("\(item.day)")
                        .font(Typography.sans(12, weight: .medium))
                        .foregroundStyle(numberColor)
                    Spacer()
                    if item.entry?.isMilestone == true {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(width: 7, height: 7)
                            .rotationEffect(.degrees(45))
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if item.hasEntry {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<item.density, id: \.self) { index in
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(barColor)
                                    .frame(
                                        width: proxy.size.width
                                            * Self.barWidths[index % 4],
                                        height: 2)
                            }
                            .frame(height: 2)
                        }
                    }
                    HStack(spacing: 4) {
                        if item.hasPhoto {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Theme.ink3).frame(width: 7, height: 7)
                        }
                    }
                    .frame(height: 9)
                    .padding(.top, 5)
                }
            }
            .padding(9)
            .aspectRatio(1, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(item.mood?.wash ?? (item.hasEntry ? Theme.paper2 : Theme.paper))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(item.isToday ? Theme.accent : Theme.hair, lineWidth: 1)
            )
            .opacity(item.hasEntry || item.isToday ? 1 : 0.55)
            .offset(y: hovering && item.hasEntry ? -3 : 0)
            .shadow(
                color: hovering && item.hasEntry
                    ? Theme.ink.opacity(0.18) : .clear,
                radius: 12, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.hasEntry)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.22)) { hovering = inside }
        }
    }

    private var numberColor: Color {
        if item.isToday { return Theme.accent }
        return item.isFuture ? Theme.ink4 : Theme.ink2
    }

    private var barColor: Color {
        item.mood?.dot ?? Theme.ink4
    }
}
