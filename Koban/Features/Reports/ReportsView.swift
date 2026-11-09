import SwiftUI

/// Port of src/components/ReportsChartsView.tsx — KPI cards, outflow donut, budget vs. actual bars,
/// 12-month cashflow, top expense categories and the freelancer tax / VAT / client summary.
struct ReportsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var hoveredSlice: String?
    @State private var contentWidth: CGFloat = 1000

    var body: some View {
        let state = store.state
        let workspace = state.settings.activeWorkspace
        let currency = state.settings.currency
        let summary = store.monthSummary(monthKey: state.activeMonthKey, workspace: workspace)
        let series = store.annualSeries(year: state.settings.activeYear, workspace: workspace)
        let data = ReportsData(state: state, summary: summary, annualSeries: series, workspace: workspace)
        // Tailwind breakpoints are viewport based: approximate the window width.
        let viewport = contentWidth + 48 + (store.isSidebarOpen ? 256 : 0)
        let lg = viewport >= 1024
        let sm = viewport >= 640

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Financial Reports, Breakdowns & Charts")
                            .font(.zen(20))
                            .foregroundStyle(Zen.ink)
                        Text("Visual analysis of monthly budgets vs. actuals, category allocations, 12-month cashflow, and tax reserves (\(summary.monthKey)).")
                            .font(.zen(12))
                            .foregroundStyle(Zen.ink2)
                    }

                    kpiGrid(summary, currency: currency, columns: lg ? 4 : (sm ? 2 : 1))

                    if lg {
                        let col = (contentWidth - 11 * 24) / 12
                        HStack(alignment: .top, spacing: 24) {
                            donutCard(summary, data: data, currency: currency)
                                .frame(width: max(0, col * 5 + 4 * 24))
                                .frame(maxHeight: .infinity)
                            budgetVsActualCard(data)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        donutCard(summary, data: data, currency: currency)
                        budgetVsActualCard(data)
                    }

                    annualCard(series, summary: summary, data: data, currency: currency,
                               year: state.settings.activeYear)
                        .id("annual")

                    if lg {
                        HStack(alignment: .top, spacing: 24) {
                            topCategoriesCard(data, summary: summary, currency: currency)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            freelancerCard(summary, data: data, currency: currency)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .id("bottom")
                    } else {
                        topCategoriesCard(data, summary: summary, currency: currency)
                        freelancerCard(summary, data: data, currency: currency).id("bottom")
                    }
                }
                .padding(24)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 - 48 }
            }
            .scrollContentBackground(.hidden)
            .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
                switch note.userInfo?["name"] as? String {
                case "reports.annual": proxy.scrollTo("annual", anchor: .top)
                case "reports.bottom": proxy.scrollTo("bottom", anchor: .bottom)
                default: break
                }
            }
        }
    }

    // MARK: - 1. KPI cards

    private func kpiGrid(_ s: MonthSummaryMetrics, currency: String, columns: Int) -> some View {
        let cards: [AnyView] = [
            AnyView(kpiCard("Monthly Income", icon: "chart.line.uptrend.xyaxis", iconColor: Zen.positive,
                            value: KobanFormat.currency(s.incomeActual, code: currency), valueColor: Zen.positive) {
                Text("Planned Budget: \(KobanFormat.currency(s.incomeBudget, code: currency))")
            }),
            AnyView(kpiCard("Total Outflow", icon: "chart.line.downtrend.xyaxis", iconColor: Zen.accent,
                            value: KobanFormat.currency(s.totalOutflowActual, code: currency), valueColor: Zen.ink) {
                let diff = s.totalOutflowDifference
                Text("Budget: \(KobanFormat.currency(s.totalOutflowBudget, code: currency)) (")
                    + Text("\(diff >= 0 ? "+" : "")\(KobanFormat.number(diff)) diff")
                        .foregroundColor(diff >= 0 ? Zen.positive : Zen.accent)
                    + Text(")")
            }),
            AnyView(kpiCard("Net Surplus / Cashflow",
                            icon: s.netActual >= 0 ? "checkmark.circle" : "exclamationmark.triangle",
                            iconColor: s.netActual >= 0 ? Zen.positive : Zen.accent,
                            value: KobanFormat.currency(s.netActual, code: currency),
                            valueColor: s.netActual >= 0 ? Zen.positive : Zen.accent) {
                Text("Planned Net: \(KobanFormat.currency(s.netBudget, code: currency))")
            }),
            AnyView(kpiCard("Savings & Retention Rate", icon: "chart.pie", iconColor: Zen.indigo,
                            value: String(format: "%.1f%%", s.savingsRatePct), valueColor: Zen.indigo) {
                Text("Of total income retained or saved")
            }),
        ]
        return Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: cards.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, cards.count), id: \.self) { i in
                        cards[i].frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private func kpiCard<Sub: View>(_ label: String, icon: String, iconColor: Color, value: String,
                                    valueColor: Color, @ViewBuilder sub: () -> Sub) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased()).tracking(0.96)
                Spacer(minLength: 4)
                ZIcon(icon, size: 16).foregroundStyle(iconColor)
            }
            .font(.zen(12))
            .foregroundStyle(Zen.ink3)
            Text(value)
                .font(.zen(20, .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            sub()
                .font(.zen(11))
                .monospacedDigit()
                .foregroundStyle(Zen.ink2)
        }
        .zenCard(padding: 16)
    }

    // MARK: - 2a. Donut

    private func donutCard(_ s: MonthSummaryMetrics, data: ReportsData, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outflow Breakdown by Group")
                    .font(.zen(14, .medium))
                    .foregroundStyle(Zen.ink)
                Text("Share of total monthly expenses & savings (\(KobanFormat.currency(s.totalOutflowActual, code: currency)))")
                    .font(.zen(11))
                    .foregroundStyle(Zen.ink3)
            }

            Spacer(minLength: 0)

            DonutChart(slices: data.activeSpendingGroups.map {
                DonutChart.Slice(id: $0.group.id, fraction: $0.totalActual / data.totalOutflowActual,
                                 color: Color(hexString: $0.group.color))
            }, hovered: $hoveredSlice) {
                VStack(spacing: 2) {
                    Text("TOTAL OUTFLOW")
                        .font(.zen(10))
                        .tracking(0.5)
                        .foregroundStyle(Zen.ink3)
                    Text(KobanFormat.currency(s.totalOutflowActual, code: currency))
                        .font(.zen(14, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Zen.ink)
                    Text(s.incomeActual > 0
                         ? "\(Int((s.totalOutflowActual / s.incomeActual * 100).rounded()))% of income" : "")
                        .font(.zen(11))
                        .monospacedDigit()
                        .foregroundStyle(Zen.positive)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
            .frame(width: 192, height: 192)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                ForEach(data.activeSpendingGroups) { gs in
                    let pct = String(format: "%.1f", gs.totalActual / data.totalOutflowActual * 100)
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hexString: gs.group.color)).frame(width: 10, height: 10)
                            Text(gs.group.name).foregroundStyle(Zen.ink).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 12) {
                            Text("\(pct)%").font(.zen(11)).foregroundStyle(Zen.ink3)
                            Text(KobanFormat.number(gs.totalActual))
                                .font(.zen(12, .medium))
                                .foregroundStyle(Zen.ink)
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                        .monospacedDigit()
                    }
                    .font(.zen(12))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(hoveredSlice == gs.group.id ? Zen.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredSlice = gs.group.id } else if hoveredSlice == gs.group.id { hoveredSlice = nil }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: - 2b. Budget vs. actual bars

    private func budgetVsActualCard(_ data: ReportsData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Budget vs. Actual by Category Group")
                        .font(.zen(14, .medium))
                        .foregroundStyle(Zen.ink)
                    Text("Planned budget (top bar) compared against actual spending (bottom bar)")
                        .font(.zen(11))
                        .foregroundStyle(Zen.ink3)
                }
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    LegendSwatch(color: Zen.ink3.opacity(0.4), label: "Budget")
                    LegendSwatch(color: Zen.indigo, label: "Actual")
                }
            }

            VStack(spacing: 14) {
                ForEach(data.outflowGroups) { gs in
                    let budgetPct = min(1, gs.totalBudget / data.maxGroupBarValue)
                    let actualPct = min(1, gs.totalActual / data.maxGroupBarValue)
                    let overBudget = gs.totalActual > gs.totalBudget && gs.totalBudget > 0
                    VStack(spacing: 4) {
                        HStack {
                            Text(gs.group.name).font(.zen(12, .medium)).foregroundStyle(Zen.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(spacing: 12) {
                                Text("Budget: \(KobanFormat.number(gs.totalBudget))").foregroundStyle(Zen.ink3)
                                Text("Actual: \(KobanFormat.number(gs.totalActual))")
                                    .fontWeight(.medium).foregroundStyle(Zen.ink)
                                Text("\(gs.totalDifference >= 0 ? "+" : "")\(KobanFormat.number(gs.totalDifference))")
                                    .fontWeight(.medium)
                                    .foregroundStyle(gs.totalDifference >= 0 ? Zen.positive : Zen.accent)
                                    .frame(minWidth: 64, alignment: .trailing)
                            }
                            .font(.zen(11))
                            .monospacedDigit()
                        }
                        VStack(spacing: 4) {
                            ProgressTrack(fraction: budgetPct, height: 8, fill: Zen.ink3.opacity(0.45))
                            ProgressTrack(fraction: actualPct, height: 10,
                                          fill: overBudget ? Zen.accent : Color(hexString: gs.group.color))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    // MARK: - 3. 12-month cashflow

    private func annualCard(_ series: [AnnualMonthPoint], summary: MonthSummaryMetrics, data: ReportsData,
                            currency: String, year: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let title = HStack(spacing: 8) {
                ZIcon("chart.bar", size: 16).foregroundStyle(Zen.indigo)
                VStack(alignment: .leading, spacing: 0) {
                    Text("12-Month Cashflow & Net Trajectory (\(String(year)))")
                        .font(.zen(14, .medium))
                        .foregroundStyle(Zen.ink)
                    Text("Monthly Income vs. Total Outflow across all 12 months of the year")
                        .font(.zen(11))
                        .foregroundStyle(Zen.ink3)
                }
            }.fixedSize()
            let legend = HStack(spacing: 16) {
                LegendSwatch(color: Zen.positive, label: "Income")
                LegendSwatch(color: Zen.accent.opacity(0.8), label: "Expenses")
                LegendSwatch(color: Zen.ink3.opacity(0.3), label: "Planned Budget")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { title; Spacer(minLength: 8); legend }
                VStack(alignment: .leading, spacing: 8) { title; legend }
            }

            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(series) { pt in
                        AnnualMonthColumn(point: pt, maxValue: data.maxAnnualValue,
                                          isCurrent: pt.monthKey == summary.monthKey, currency: currency)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
                Rectangle().fill(Zen.line).frame(height: 1)
            }
            .frame(height: 208) // h-56 minus pt-4
            .padding(.top, 16)
        }
        .zenCard(padding: 20)
    }

    // MARK: - 4a. Top categories

    private func topCategoriesCard(_ data: ReportsData, summary: MonthSummaryMetrics, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Top Individual Expense Categories")
                    .font(.zen(14, .medium))
                    .foregroundStyle(Zen.ink)
                Text("Largest cost drivers in \(summary.monthKey) ranked by actual spend")
                    .font(.zen(11))
                    .foregroundStyle(Zen.ink3)
            }

            VStack(spacing: 0) {
                ForEach(Array(data.topExpenseCategories.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                    let share = summary.totalOutflowActual > 0
                        ? String(format: "%.1f", row.actual / summary.totalOutflowActual * 100) : "0.0"
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hexString: row.group.color)).frame(width: 8, height: 8)
                            (Text(row.category.name).font(.zen(12, .medium)).foregroundColor(Zen.ink)
                             + Text("  " + row.group.name.uppercased()).font(.zen(10)).foregroundColor(Zen.ink3))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 12) {
                            Text("\(share)%").font(.zen(11)).foregroundStyle(Zen.ink3)
                            Text("B: \(KobanFormat.number(row.budget))")
                                .foregroundStyle(Zen.ink2)
                                .frame(minWidth: 64, alignment: .trailing)
                            Text(KobanFormat.currency(row.actual, code: currency))
                                .fontWeight(.semibold)
                                .foregroundStyle(Zen.ink)
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                        .font(.zen(12))
                        .monospacedDigit()
                        .fixedSize()
                    }
                    .padding(.vertical, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .zenCard(padding: 20)
    }

    // MARK: - 4b. Freelancer tax / VAT / clients

    private func freelancerCard(_ s: MonthSummaryMetrics, data: ReportsData, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ZIcon("briefcase", size: 16).foregroundStyle(Zen.indigo)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Freelancer Tax, VAT & Client Breakdown")
                        .font(.zen(14, .medium))
                        .foregroundStyle(Zen.ink)
                    Text("Tax-deductible business expenses, VAT settlement & client revenue")
                        .font(.zen(11))
                        .foregroundStyle(Zen.ink3)
                }
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    taxTile("Deductible Expenses", KobanFormat.currency(s.deductibleExpensesActual, code: currency),
                            color: Zen.indigo, weight: .semibold, valueColor: Zen.indigo)
                    taxTile("Net VAT Payable", KobanFormat.currency(s.netVatPayable, code: currency),
                            color: Zen.ink, weight: .semibold, valueColor: Zen.ink)
                }
                GridRow {
                    taxTile("VAT Collected (Output)", KobanFormat.currency(s.vatCollected, code: currency),
                            color: Zen.ink2, weight: .medium, valueColor: Zen.ink2)
                    taxTile("Input VAT Credit", KobanFormat.currency(s.vatPaidOnExpenses, code: currency),
                            color: Zen.positive, weight: .medium, valueColor: Zen.positive)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("INCOME SOURCES / CLIENTS (\(s.monthKey))")
                    .font(.zen(11, .medium))
                    .tracking(0.55)
                    .foregroundStyle(Zen.ink3)
                if data.clientRevenue.isEmpty {
                    Text("No income entries logged for this month yet.")
                        .font(.zen(12))
                        .foregroundStyle(Zen.ink3)
                        .padding(.vertical, 8)
                } else {
                    ForEach(data.clientRevenue, id: \.name) { item in
                        HStack {
                            Text(item.name).foregroundStyle(Zen.ink)
                            Spacer(minLength: 8)
                            Text(KobanFormat.currency(item.amount, code: currency))
                                .fontWeight(.medium)
                                .monospacedDigit()
                                .foregroundStyle(Zen.positive)
                        }
                        .font(.zen(12))
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
            Spacer(minLength: 0)
        }
        .zenCard(padding: 20)
    }

    private func taxTile(_ label: String, _ value: String, color: Color, weight: Font.Weight,
                         valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.zen(10)).foregroundStyle(Zen.ink3)
            Text(value).font(.zen(14, weight)).monospacedDigit().foregroundStyle(valueColor).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.app, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }
}

// MARK: - Pieces

/// inline-flex gap-1.5: w-2.5 h-2.5 rounded-xs swatch + label (text-[11px] text-ink-2).
private struct LegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
        .font(.zen(11))
        .foregroundStyle(Zen.ink2)
        .fixedSize()
    }
}

/// h-2 bg-raised rounded-full track with a rounded fill.
private struct ProgressTrack: View {
    let fraction: Double
    let height: CGFloat
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(fill)
                .frame(width: geo.size.width * max(0, min(1, fraction)))
        }
        .frame(height: height)
        .background(Zen.raised)
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

/// SVG donut (r = 72, stroke 20 in a 180 viewBox drawn at 192 px), slices clockwise from 12 o'clock.
private struct DonutChart<Center: View>: View {
    struct Slice: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    let slices: [Slice]
    @Binding var hovered: String?
    @ViewBuilder let center: () -> Center

    private let scale: CGFloat = 192.0 / 180.0
    private var radius: CGFloat { 72 * scale }

    var body: some View {
        let starts = slices.reduce(into: [Double]()) { acc, s in acc.append((acc.last ?? 0) + s.fraction) }
        ZStack {
            Circle()
                .stroke(Zen.line, lineWidth: 20 * scale)
                .frame(width: radius * 2, height: radius * 2)
            ForEach(Array(slices.enumerated()), id: \.element.id) { idx, slice in
                let from = idx == 0 ? 0 : starts[idx - 1]
                Circle()
                    .trim(from: from, to: min(1, from + slice.fraction))
                    .stroke(slice.color, lineWidth: (hovered == slice.id ? 24 : 20) * scale)
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: hovered)
            }
            center().allowsHitTesting(false)
        }
        .frame(width: 192, height: 192)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hovered = sliceId(at: p, starts: starts)
            case .ended:
                hovered = nil
            }
        }
    }

    private func sliceId(at p: CGPoint, starts: [Double]) -> String? {
        let dx = p.x - 96, dy = p.y - 96
        let dist = sqrt(dx * dx + dy * dy)
        guard abs(dist - radius) <= 12 * scale else { return nil }
        // Angle clockwise from 12 o'clock, 0…1.
        var a = atan2(dx, -dy) / (2 * .pi)
        if a < 0 { a += 1 }
        for (idx, end) in starts.enumerated() where a < end { return slices[idx].id }
        return nil
    }
}

/// One month of the 12-month chart: income + outflow bars (h-40), month label.
private struct AnnualMonthColumn: View {
    let point: AnnualMonthPoint
    let maxValue: Double
    let isCurrent: Bool
    let currency: String
    @State private var hovering = false

    var body: some View {
        let inc = point.incomeActual != 0 ? point.incomeActual : point.incomeBudget
        let out = point.outflowActual != 0 ? point.outflowActual : point.outflowBudget
        let incH = max(4, (inc / maxValue * 160).rounded())
        let outH = max(4, (out / maxValue * 160).rounded())

        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                    .fill(point.incomeActual > 0 ? Zen.positive : Zen.positive.opacity(0.35))
                    .frame(width: 12, height: incH)
                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                    .fill(point.outflowActual > 0 ? Zen.accent : Zen.accent.opacity(0.35))
                    .frame(width: 12, height: outH)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160, alignment: .bottom)
            Text(point.monthLabel)
                .font(.zen(11, isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Zen.ink : Zen.ink2)
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(isCurrent ? Zen.raised.opacity(0.8) : (hovering ? Zen.raised.opacity(0.4) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isCurrent { RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(point.monthLabel): Income \(KobanFormat.currency(inc, code: currency)) | Outflow \(KobanFormat.currency(out, code: currency)) | NET \(KobanFormat.currency(inc - out, code: currency))")
    }
}
