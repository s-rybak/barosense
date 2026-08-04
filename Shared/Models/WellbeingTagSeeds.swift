import Foundation

extension WellbeingTag {

    /// The tags a fresh install starts with. Inserted once, then owned by the user — any
    /// of them can be renamed or retired, and the set is not a limit on what they can add.
    ///
    /// **This file is app copy.** Unlike the rest of `Shared/`, every `name` here is text
    /// the app puts in front of a user and an App Review reader. Editing one is a copy
    /// decision under `.claude/skills/appstore_compliance/SKILL.md`, not a refactor —
    /// which is why the shipped defaults live in one file of their own rather than inside
    /// the model.
    ///
    /// The slugs are a different thing entirely: they are storage identity and are frozen.
    static let seeds: [WellbeingTag] = [
        WellbeingTag(id: .seeded("headache"), name: "Headache"), // barosense:copy-allow default
        WellbeingTag(id: .seeded("fatigue"), name: "Fatigue"),
        WellbeingTag(id: .seeded("joints"), name: "Joints")
    ]
}
