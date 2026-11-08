import Charts
import SwiftUI

/// A chart the model drew, in a message bubble.
struct ChartCardView: View {
    var chart: Card.ChartData

    /// Concrete colours: Charts draws with resolved colours, and dynamic ones
    /// came out empty before.
    static let palette: [Color] = [
        Color(.sRGB, red: 0.69, green: 0.32, blue: 0.87),   // purple, the accent
        Color(.sRGB, red: 0.40, green: 0.45, blue: 0.95),   // indigo
        Color(.sRGB, red: 0.33, green: 0.72, blue: 1.00),   // sky
        Color(.sRGB, red: 0.30, green: 0.82, blue: 0.62),   // mint
        Color(.sRGB, red: 1.00, green: 0.66, blue: 0.30),   // orange
        Color(.sRGB, red: 0.98, green: 0.84, blue: 0.30),   // yellow
    ]

    private struct Point: Identifiable {
        var id: String { "\(series)|\(index)" }
        var series: String
        var index: Int
        var label: String
        var value: Double
    }

    private var points: [Point] {
        chart.series.flatMap { series in
            series.values.enumerated().compactMap { index, value in
                chart.labels.indices.contains(index)
                    ? Point(series: series.name, index: index, label: chart.labels[index], value: value) : nil
            }
        }
    }

    private var many: Bool { chart.series.count > 1 }

    var body: some View {
        // The Moon style: the chart on a pane of glass, as wide as a reply.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chart.title).font(.headline).foregroundStyle(Ink.text)
                if let subtitle = chart.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Ink.muted)
                }
            }
            if chart.kind == .horizontalBar {
                RankedBars(chart: chart)
            } else {
                plot.frame(height: 220)
            }
            if many && chart.kind != .pie && chart.kind != .donut { legend }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(chart.title))
    }

    @ViewBuilder
    private var plot: some View {
        switch chart.kind {
        case .pie, .donut:
            HStack(alignment: .center, spacing: 18) {
                Chart(points.filter { $0.series == chart.series.first?.name }) { point in
                    SectorMark(angle: .value("Value", point.value),
                               innerRadius: .ratio(chart.kind == .donut ? 0.58 : 0),
                               angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(Self.palette[point.index % Self.palette.count])
                }
                .chartLegend(.hidden)
                .frame(width: 200)
                VStack(alignment: .leading, spacing: 6) {
                    let first = points.filter { $0.series == chart.series.first?.name }
                    let total = max(1, first.map(\.value).reduce(0, +))
                    ForEach(first) { point in
                        HStack(spacing: 6) {
                            Circle().fill(Self.palette[point.index % Self.palette.count]).frame(width: 8, height: 8)
                            Text(point.label).font(.caption).foregroundStyle(Ink.text).lineLimit(1)
                            Text("\(Int((point.value / total * 100).rounded()))%")
                                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Ink.muted)
                        }
                    }
                }
            }
        case .scatter:
            Chart(points) { point in
                PointMark(x: .value("X", Double(point.label) ?? Double(point.index)), y: .value(unitName, point.value))
                    .foregroundStyle(color(point.series))
                    .symbolSize(60)
            }
            .chartLegend(.hidden)
            .axisStyle()
        case .line, .area:
            Chart(points) { point in
                if chart.kind == .area {
                    AreaMark(x: .value("Label", point.label), y: .value(unitName, point.value),
                             stacking: many ? .standard : .unstacked)
                        .foregroundStyle(color(point.series).opacity(0.35))
                        .interpolationMethod(.catmullRom)
                }
                LineMark(x: .value("Label", point.label), y: .value(unitName, point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if chart.labels.count <= 24 {
                    PointMark(x: .value("Label", point.label), y: .value(unitName, point.value))
                        .foregroundStyle(by: .value("Series", point.series))
                        .symbolSize(24)
                }
            }
            .chartForegroundStyleScale(domain: chart.series.map(\.name), range: Array(Self.palette.prefix(chart.series.count)))
            .chartLegend(.hidden)
            .axisStyle()
        case .horizontalBar:
            RankedBars(chart: chart)
        case .bar, .stackedBar:
            Chart(points) { point in
                if chart.kind == .bar {
                    BarMark(x: .value("Label", point.label), y: .value(unitName, point.value), width: .ratio(0.7))
                        .foregroundStyle(by: .value("Series", point.series))
                        // Side by side only when there is more than one series.
                        .position(by: .value("Series", many ? point.series : ""))
                        .cornerRadius(4)
                } else {
                    BarMark(x: .value("Label", point.label), y: .value(unitName, point.value), width: .ratio(0.7))
                        .foregroundStyle(by: .value("Series", point.series))
                        .cornerRadius(4)
                }
            }
            .chartForegroundStyleScale(domain: chart.series.map(\.name), range: Array(Self.palette.prefix(chart.series.count)))
            .chartLegend(.hidden)
            .axisStyle()
        }
    }

    private var unitName: String { chart.unit ?? "Value" }

    private func color(_ series: String) -> Color {
        let index = chart.series.firstIndex { $0.name == series } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(chart.series.enumerated()), id: \.offset) { index, series in
                HStack(spacing: 5) {
                    Circle().fill(Self.palette[index % Self.palette.count]).frame(width: 8, height: 8)
                    Text(series.name).font(.caption).foregroundStyle(Ink.muted)
                }
            }
        }
    }
}

/// A ranking, read like a list: the name, its bar, its number, one row each.
/// Charts' categorical axis put names between bars and drew hairline bars;
/// rows keep every name beside its own bar.
private struct RankedBars: View {
    var chart: Card.ChartData

    private var top: Double {
        max(1, chart.series.flatMap(\.values).max() ?? 1)
    }

    /// Every row the same height, so the three columns line up.
    private let row: CGFloat = 22

    var body: some View {
        // Three columns: names as wide as the longest name (long ones
        // shortened), bars in the rest, numbers at the end.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(chart.labels.enumerated()), id: \.offset) { _, label in
                    Text(label.count > 26 ? label.prefix(25) + "…" : label)
                        .font(.callout)
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                        .frame(height: row)
                        .help(Text(label))
                }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(chart.labels.indices), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(chart.series.enumerated()), id: \.offset) { seriesIndex, series in
                            let value = series.values.indices.contains(index) ? series.values[index] : 0
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(ChartCardView.palette[seriesIndex % ChartCardView.palette.count])
                                    .frame(width: max(6, geometry.size.width * value / top))
                            }
                            .frame(height: chart.series.count > 1 ? 7 : 12)
                        }
                    }
                    .frame(height: row)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(chart.labels.indices), id: \.self) { index in
                    Text(values(at: index))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.muted)
                        .frame(height: row)
                }
            }
            .fixedSize()
        }
    }

    private func values(at index: Int) -> String {
        chart.series.map { series in
            guard series.values.indices.contains(index) else { return "–" }
            return series.values[index].formatted(.number.precision(.fractionLength(0...1)))
        }.joined(separator: " / ")
    }
}

private extension View {
    /// Quiet axes: muted labels, faint grid.
    func axisStyle() -> some View {
        chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().foregroundStyle(Ink.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Ink.muted.opacity(0.25))
                AxisValueLabel().foregroundStyle(Ink.muted)
            }
        }
    }
}
