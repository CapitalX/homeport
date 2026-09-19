import Foundation

/// Reusable prompt templates exposed via MCP `prompts/list` + `prompts/get`.
struct PromptTemplate {
    let name: String
    let description: String
    let arguments: [(name: String, description: String, required: Bool)]
    let body: (JSONObject) -> String

    func render(_ args: JSONObject) -> String { body(args) }

    var advertised: JSONObject {
        [
            "name": name,
            "description": description,
            "arguments": arguments.map { arg in
                [
                    "name": arg.name,
                    "description": arg.description,
                    "required": arg.required
                ] as JSONObject
            }
        ]
    }

    static let all: [PromptTemplate] = [
        PromptTemplate(
            name: "daily-agenda",
            description: "Summarize today's calendar events and due reminders into a clear agenda.",
            arguments: [(name: "date", description: "Day to summarize (yyyy-MM-dd). Defaults to today.", required: false)],
            body: { args in
                let day = args.string("date") ?? "today"
                return """
                Build my agenda for \(day).

                1. Call calendar_query for \(day) (start of day to end of day) across all calendars.
                2. Call reminders_query for reminders due on or before \(day) that are not completed.
                3. Present a single chronological agenda: timed events first with times and locations, \
                then all-day events, then a prioritized reminders checklist (high priority first).
                Flag any scheduling conflicts.
                """
            }
        ),
        PromptTemplate(
            name: "weekly-planning",
            description: "Review the coming week across calendar and reminders and propose a plan.",
            arguments: [(name: "start", description: "Week start date (yyyy-MM-dd). Defaults to today.", required: false)],
            body: { args in
                let start = args.string("start") ?? "today"
                return """
                Help me plan the week starting \(start).

                1. calendar_query for the 7 days from \(start).
                2. reminders_query for incomplete reminders due within that window (and any overdue).
                3. Identify the busiest days, any conflicts, and reminders with no scheduled time.
                4. Propose time blocks for the unscheduled high-priority reminders around my existing events.
                """
            }
        ),
        PromptTemplate(
            name: "capture-reminder",
            description: "Turn a natural-language request into a well-formed reminder.",
            arguments: [(name: "request", description: "What to be reminded about, in plain language.", required: true)],
            body: { args in
                let request = args.string("request") ?? "(describe the reminder)"
                return """
                Create a reminder from this request: "\(request)"

                Infer a concise title, a due date/time if one is implied, and a priority \
                (high/medium/low) if the language suggests urgency. Ask me which list to use only if \
                it is ambiguous; otherwise use the default list. Then call reminders_create and confirm \
                what you created.
                """
            }
        ),
        PromptTemplate(
            name: "inbox-triage",
            description: "Review overdue and unscheduled reminders and help triage them.",
            arguments: [],
            body: { _ in
                """
                Triage my reminders.

                1. reminders_query for all incomplete reminders.
                2. Group them: overdue, due today, due this week, no due date.
                3. For the overdue and no-due-date groups, suggest for each: complete it, reschedule it \
                (with a concrete new due date), or delete it. Wait for my confirmation before making changes.
                """
            }
        )
    ]
}
