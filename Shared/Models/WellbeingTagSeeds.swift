import Foundation

extension WellbeingTag {

    /// The tags a fresh install starts with. Inserted once, then owned by the user — any
    /// of them can be renamed or retired, and the set is not a limit on what they can add.
    ///
    /// This is also the list onboarding offers on its second step (Figma `7:398`): the
    /// user keeps the ones that apply and the rest are archived, so "what a fresh install
    /// starts with" and "what onboarding shows" cannot drift apart.
    ///
    /// **This file is app copy.** Unlike the rest of `Shared/`, every `name` here is text
    /// the app puts in front of a user and an App Review reader. Editing one is a copy
    /// decision under `.claude/skills/appstore_compliance/SKILL.md`, not a refactor —
    /// which is why the shipped defaults live in one file of their own rather than inside
    /// the model. These are the base-language defaults; a localised build resolves the
    /// display text from the slug instead, and a `name` that still equals the default
    /// counts as "not renamed".
    ///
    /// The slugs are a different thing entirely: they are storage identity and are frozen.
    /// Order is the order onboarding renders them in.
    static let seeds: [WellbeingTag] = [
        WellbeingTag(id: .seeded("headache"), name: "Headache"), // barosense:copy-allow default
        WellbeingTag(id: .seeded("migraine"), name: "Migraine"), // barosense:copy-allow default
        WellbeingTag(id: .seeded("fatigue"), name: "Fatigue"),
        WellbeingTag(id: .seeded("joints"), name: "Joints"),
        WellbeingTag(id: .seeded("sleep"), name: "Sleep"),
        WellbeingTag(id: .seeded("mood"), name: "Mood"),
        WellbeingTag(id: .seeded("dizziness"), name: "Dizziness")
    ]
}
