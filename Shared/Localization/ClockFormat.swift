import Foundation

/// Which clock Barosense prints times on — and, more precisely, whether the reader's *region*
/// or their *language* gets to decide.
///
/// ## The bug this exists for
///
/// `LanguageController.locale` keeps the device's region on purpose and swaps only the language
/// subtag, so someone in the United States who switches the app to Ukrainian keeps their week,
/// their separators — and, until this type, their clock. The result was `uk_US`: Ukrainian copy
/// with an American reading, a dose taken at 16:45 filed as "4:45 пп". Nobody writes that in
/// Ukrainian.
///
/// ## The rule
///
/// A language that has no 12-hour form of its own gets a 24-hour clock whatever the region says.
/// A language that does write 12-hour times is left entirely alone — its region decides, and so
/// does the device's own 24-Hour Time switch, exactly as before this type existed.
///
/// Read out of the language's own region-less locale rather than listed here, so the rule is one
/// question asked of CLDR rather than a table to maintain: `uk` answers 24 and is pinned, `en`
/// answers 12 and is untouched — which leaves `en_US` on 12 hours and `en_GB` on 24, both of
/// them right. A third shipped language needs no edit to this file.
///
/// The alternative — one 24-hour clock for everyone — was tried first and rejected once it was
/// clear what it cost: it overrides the device's 12/24 switch for readers whose language uses
/// that switch, which is a system preference this app has no standing to overrule.
enum ClockFormat {

    /// `locale` with its language's clock pinned onto it, or `locale` unchanged when the
    /// language leaves the question to the region.
    ///
    /// Everything else — region, calendar, separators, first day of the week — is untouched in
    /// both cases.
    ///
    /// This is also what decides whether the medication sheet's time wheel shows an AM/PM
    /// column: that column keys on the locale's own template for a bare time
    /// (`TimeWheel.usesPeriod`), which resolves to `HH` exactly when this pins. The picker and
    /// the row it fills in therefore cannot end up on different clocks.
    static func applied(to locale: Locale) -> Locale {
        guard let cycle = languageCycle(of: locale) else { return locale }

        var components = Locale.Components(locale: locale)
        components.hourCycle = cycle
        return Locale(components: components)
    }

    /// The cycle `locale`'s **language** writes times in, and only when that cycle is a
    /// 24-hour one — `nil` otherwise, which is the signal to leave the locale alone.
    ///
    /// Both 24-hour cycles count. `h23` is the common one (`uk`, `de`, `fr`); `h24` is Japanese
    /// and a handful of others, and treating it as 12-hour because it is not `h23` would put a
    /// future translation back on the clock this type exists to correct.
    private static func languageCycle(of locale: Locale) -> Locale.HourCycle? {
        guard let code = locale.language.languageCode?.identifier else { return nil }

        let cycle = Locale(identifier: code).hourCycle
        return cycle == .zeroToTwentyThree || cycle == .oneToTwentyFour ? cycle : nil
    }
}
