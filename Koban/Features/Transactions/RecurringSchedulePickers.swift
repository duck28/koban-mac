import SwiftUI

// Start-week / start-month pickers for recurring rules and the fixed-cost anchor icon.
// Port of the schedule controls in src/components/RecurringView.tsx.

/// Lucide "anchor" (the icon the Windows build uses), drawn on a 24×24 grid so it needs no
/// SF Symbol.
struct AnchorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // Ring: circle cx=12 cy=5 r=3
        path.addEllipse(in: CGRect(x: rect.minX + 9 * s, y: rect.minY + 2 * s, width: 6 * s, height: 6 * s))
        // Shaft: 12,22 → 12,8
        path.move(to: p(12, 22))
        path.addLine(to: p(12, 8))
        // Arms: M5 12H2 a10 10 0 0 0 20 0 h-3
        path.move(to: p(5, 12))
        path.addLine(to: p(2, 12))
        path.addArc(center: p(12, 12), radius: 10 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: p(19, 12))
        return path
    }
}

/// Anchor icon sized like ZIcon.
struct AnchorIcon: View {
    var size: CGFloat = 13
    var lineWidth: CGFloat = 1.6

    var body: some View {
        AnchorShape()
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size * 0.86, height: size * 0.86)
            .frame(width: size, height: size)
    }
}

/// A boxed "‹ value ›" control used for the start week and start month.
struct ScheduleStepper: View {
    let text: String
    var missing = false
    var height: CGFloat = 28
    var fontSize: CGFloat = 11
    let help: String
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { onStep(-1) } label: {
                ZIcon("chevron.left", size: 11).foregroundStyle(Zen.ink2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(text)
                .font(.zen(fontSize))
                .monospacedDigit()
                .foregroundStyle(missing ? Zen.accent : Zen.ink)
                .lineLimit(1)
                .frame(minWidth: 84)
            Button { onStep(1) } label: {
                ZIcon("chevron.right", size: 11).foregroundStyle(Zen.ink2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(height: height)
        .background(missing ? Zen.accent.opacity(0.06) : Zen.raised, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(missing ? Zen.accent.opacity(0.7) : Zen.line, lineWidth: 1))
        .help(help)
        .fixedSize()
    }
}

enum ScheduleFormat {
    /// "Week 47, 2026" for a YYYY-MM-DD start date.
    static func weekLabel(_ startDate: String?) -> String? {
        guard let day = RecurringSchedule.dayNumber(startDate) else { return nil }
        let w = RecurringSchedule.isoWeek(day)
        return "\(L10n.t("recurring.startWeekLabel")) \(w.week), \(w.year)"
    }

    /// "Nov 2026" for a YYYY-MM start month.
    static func monthLabel(_ startMonth: String?) -> String? {
        guard let startMonth, startMonth.count == 7,
              let y = Int(startMonth.prefix(4)), let m = Int(startMonth.suffix(2)), (1...12).contains(m)
        else { return nil }
        let f = DateFormatter()
        f.locale = L10n.intlLocale
        f.setLocalizedDateFormatFromTemplate("MMM yyyy")
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else { return startMonth }
        return f.string(from: date)
    }

    /// Short day + month ("20 Nov") for a YYYY-MM-DD date.
    static func shortDate(_ iso: String) -> String {
        guard let day = RecurringSchedule.dayNumber(iso) else { return iso }
        let f = DateFormatter()
        f.locale = L10n.intlLocale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("dd MMM")
        return f.string(from: Date(timeIntervalSince1970: Double(day) * 86400))
    }

    /// Weekday options Mon…Sun in the UI language.
    static var weekdayOptions: [(Int, String)] {
        let f = DateFormatter()
        f.locale = L10n.intlLocale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEE")
        // 2024-01-01 was a Monday
        let monday = RecurringSchedule.dayNumber(year: 2024, month: 1, day: 1) ?? 0
        return (0..<7).map { i in (i, f.string(from: Date(timeIntervalSince1970: Double(monday + i) * 86400))) }
    }

    /// Moves a start date by whole weeks, keeping its weekday.
    static func shiftWeeks(_ startDate: String?, by weeks: Int) -> String {
        let base = RecurringSchedule.dayNumber(startDate)
            ?? RecurringSchedule.dayNumber(RecurringSchedule.todayISO()) ?? 0
        return RecurringSchedule.isoDate(base + weeks * 7)
    }

    /// Same ISO week, another weekday (Mon = 0).
    static func withWeekday(_ startDate: String?, _ weekday: Int) -> String {
        let base = RecurringSchedule.dayNumber(startDate)
            ?? RecurringSchedule.dayNumber(RecurringSchedule.todayISO()) ?? 0
        return RecurringSchedule.isoDate(base - RecurringSchedule.weekday(base) + min(6, max(0, weekday)))
    }

    /// Moves a YYYY-MM month by `delta` months (falls back to `fallback`).
    static func shiftMonth(_ startMonth: String?, by delta: Int, fallback: String) -> String {
        let key = startMonth ?? fallback
        guard key.count == 7, let y = Int(key.prefix(4)), let m = Int(key.suffix(2)) else { return fallback }
        let idx = y * 12 + (m - 1) + (startMonth == nil ? 0 : delta)
        return MonthKey.format(year: idx / 12, month: idx % 12 + 1)
    }

    /// Fields a rule needs when switching frequency, pre-filled so the picker shows a value.
    static func defaults(for frequency: RecurrenceFrequency, startDate: String?, startMonth: String?,
                         monthKey: String) -> (startDate: String?, startMonth: String?) {
        switch frequency {
        case .biweekly where startDate == nil:
            let today = RecurringSchedule.todayISO()
            return (today.hasPrefix(monthKey) ? today : "\(monthKey)-01", nil)
        case .bimonthly, .quarterly, .yearly:
            return (nil, startMonth == nil ? monthKey : nil)
        default:
            return (nil, nil)
        }
    }
}

/// Start week + weekday (bi-weekly) or start month (bi-monthly / quarterly / yearly).
struct RecurringStartPickers: View {
    let frequency: RecurrenceFrequency
    let startDate: String?
    let startMonth: String?
    let monthKey: String
    var compact = true
    let onStartDate: (String) -> Void
    let onStartMonth: (String) -> Void

    var body: some View {
        let height: CGFloat = compact ? 28 : 32
        let fontSize: CGFloat = compact ? 11 : 12
        switch frequency {
        case .biweekly:
            HStack(spacing: 6) {
                ScheduleStepper(text: ScheduleFormat.weekLabel(startDate) ?? L10n.t("recurring.setStart"),
                                missing: startDate == nil, height: height, fontSize: fontSize,
                                help: startDate == nil ? L10n.t("recurring.startMissingTip") : L10n.t("recurring.startWeekLabel")) { delta in
                    onStartDate(startDate == nil ? ScheduleFormat.withWeekday(nil, 4)
                                                 : ScheduleFormat.shiftWeeks(startDate, by: delta))
                }
                TxSelect(options: ScheduleFormat.weekdayOptions,
                         selection: Binding(get: { RecurringSchedule.dayNumber(startDate).map(RecurringSchedule.weekday) ?? 4 },
                                            set: { onStartDate(ScheduleFormat.withWeekday(startDate, $0)) }),
                         height: height, radius: 4, fontSize: fontSize, textColor: Zen.ink, fullWidth: false)
                    .help(L10n.t("recurring.weekdayLabel"))
            }
            .fixedSize()
        case .bimonthly, .quarterly, .yearly:
            ScheduleStepper(text: ScheduleFormat.monthLabel(startMonth) ?? L10n.t("recurring.setStart"),
                            missing: startMonth == nil, height: height, fontSize: fontSize,
                            help: startMonth == nil ? L10n.t("recurring.startMissingTip") : L10n.t("recurring.startMonthLabel")) { delta in
                onStartMonth(ScheduleFormat.shiftMonth(startMonth, by: delta, fallback: monthKey))
            }
        case .monthly:
            EmptyView()
        }
    }
}
