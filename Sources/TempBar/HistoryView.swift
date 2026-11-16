import Charts
import SwiftUI
import TempBarCore

/// The popover's second page: inside and outside temperature over the last 12 hours.
struct HistoryView: View {
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverDate: Date?

    private struct Series: Identifiable {
        let name: String
        let color: Color
        let samples: [TemperatureSample]
        var id: String { name }
    }

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-AppModel.historyWindow)
        let series = series(from: start, to: now)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 12 hours").font(.headline)
                Spacer()
                Text(hoverDate ?? now, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            legend(series, at: hoverDate)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            chart(series, domain: start...now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.haStatus == .connected) { await model.refreshIndoorHistory() }
    }

    private func series(from start: Date, to now: Date) -> [Series] {
        var inside = model.indoorHistory.starting(at: start)
        // Recorder rows mark changes; a steady reading still runs to the right edge.
        if !inside.isEmpty, let current = model.indoorF {
            inside.append(TemperatureSample(date: now, fahrenheit: current))
        }
        let outside = (model.outdoor?.history ?? []).starting(at: start)
        // Palette checked for color-blind separation and contrast in both appearances.
        let dark = colorScheme == .dark
        return [
            Series(name: "Inside", color: Color(hex: dark ? 0xD95926 : 0xEB6834), samples: inside),
            Series(name: "Outside", color: Color(hex: dark ? 0x3987E5 : 0x2A78D6), samples: outside),
        ]
    }

    private var notice: String? {
        if model.indoorHistory.isEmpty, let error = model.historyError { return "No inside history: \(error)" }
        if model.outdoor == nil { return "No outside history yet" }
        return nil
    }

    /// Doubles as the readout: current values, or the values under the pointer.
    private func legend(_ series: [Series], at date: Date?) -> some View {
        HStack(spacing: 14) {
            ForEach(series) { item in
                let value = date.map { item.samples.value(at: $0) } ?? item.samples.last?.fahrenheit
                HStack(spacing: 5) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.name).foregroundStyle(.secondary)
                    Text(Format.degrees(value)).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    private func chart(_ series: [Series], domain: ClosedRange<Date>) -> some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.samples.indices, id: \.self) { index in
                    LineMark(
                        x: .value("Time", item.samples[index].date),
                        y: .value("Temperature", item.samples[index].fahrenheit),
                        series: .value("Place", item.name)
                    )
                    .foregroundStyle(item.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            if let hoverDate {
                RuleMark(x: .value("Time", hoverDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(series) { item in
                    if let value = item.samples.value(at: hoverDate) {
                        PointMark(x: .value("Time", hoverDate), y: .value("Temperature", value))
                            .foregroundStyle(item.color)
                            .symbolSize(60)
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain(series))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 3)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let degrees = mark.as(Double.self) { Text(Format.degrees(degrees)) }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $hoverDate)
        .frame(minHeight: 170)
    }
}

private extension HistoryView {
    /// Snug to the data, on 5° steps; the default scale pads out to round tens.
    private func yDomain(_ series: [Series]) -> ClosedRange<Double> {
        let values = series.flatMap(\.samples).map(\.fahrenheit)
        guard let low = values.min(), let high = values.max() else { return 30...80 }
        return (((low - 1) / 5).rounded(.down) * 5)...(((high + 1) / 5).rounded(.up) * 5)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
