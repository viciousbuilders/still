import SwiftUI
import BlockerCore

struct GardenView: View {
    @ObservedObject var focus: FocusModel
    let now: Date
    @Environment(\.colorScheme) private var scheme
    private var garden: FocusGarden { focus.visibleGarden }
    private var accent: Color { StillStyle.accent(scheme) }
    private var secondary: Color { StillStyle.secondary(scheme) }
    private var hasWeekHistory: Bool {
        let beginning = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
        return garden.records.filter { $0.date >= beginning && $0.date <= now }.reduce(0) { $0 + $1.seconds } >= 60
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Garden").font(.system(size: 20, weight: .semibold))
                    }
                    Spacer()
                    Label("\(garden.treeCount)", systemImage: "tree.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                        .accessibilityLabel("\(garden.treeCount) trees grown")
                }
                HStack(spacing: 28) {
                    metric("Today", minutes: Int(garden.seconds(on: now) / 60))
                    Divider().frame(height: 38)
                    metric("Total focus", minutes: Int(garden.focusSeconds / 60))
                }
                VStack(spacing: 20) {
                    if garden.treeCount == 0 {
                        TreeProgressView(progress: garden.saplingProgress).frame(width: 90, height: 110).padding(.top, 12)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 20) {
                            ForEach(0..<min(60, garden.treeCount), id: \.self) { _ in
                                Image(systemName: "tree.fill").font(.system(size: 29)).foregroundStyle(accent).accessibilityHidden(true)
                            }
                        }.padding(.vertical, 12)
                        if garden.treeCount > 60 { Text("\(garden.treeCount) trees in your garden").font(.system(size: 12)).foregroundStyle(secondary) }
                    }
                    ProgressView(value: garden.saplingProgress).tint(accent).accessibilityLabel("Next tree progress")
                    Text("25 focus minutes per tree. Partial progress carries over.")
                        .font(.system(size: 12)).foregroundStyle(secondary).multilineTextAlignment(.center)
                }.padding(20).frame(maxWidth: .infinity)
                    .background(StillStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                if hasWeekHistory {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("This week").font(.system(size: 13, weight: .semibold))
                        ForEach((0..<7).reversed(), id: \.self) { offset in
                            let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now
                            let minutes = Int(garden.seconds(on: date) / 60)
                            HStack {
                                Text(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.wide)))
                                    .font(.system(size: 12)).foregroundStyle(secondary).frame(width: 82, alignment: .leading)
                                GeometryReader { geometry in
                                    Capsule().fill(accent.opacity(0.7)).frame(width: geometry.size.width * min(1, Double(minutes) / 120))
                                }.frame(height: 5).accessibilityHidden(true)
                                Text("\(minutes) min").font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary).frame(width: 45, alignment: .trailing)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
            }.padding(20)
        }
    }

    private func metric(_ title: String, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(minutes)").font(.system(size: 27, weight: .light)).monospacedDigit()
                Text("min").font(.system(size: 12)).foregroundStyle(secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
