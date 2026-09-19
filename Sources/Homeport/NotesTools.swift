import Foundation

enum NotesTools {
    static let all: [Tool] = [foldersTool, queryTool, readTool, createTool, appendTool]

    // MARK: notes_folders

    private static let foldersTool = Tool(
        name: "notes_folders",
        description: "List Apple Notes folders across all accounts, with the note count in each. Use this to confirm a destination folder exists before notes_create.",
        inputSchema: Schema.object([:]),
        handler: { _ in
            ["folders": try NotesStore.folders()]
        }
    )

    // MARK: notes_query

    private static let queryTool = Tool(
        name: "notes_query",
        description: """
        Search notes by title and body, or list them. Returns METADATA AND A SNIPPET ONLY, never \
        full bodies — a Notes account can hold megabytes of HTML and returning it would swamp the \
        response for no benefit. Each result carries an `id`; pass that to notes_read for the full \
        text. Filter with `search` (case-sensitive substring across title and body), `folder`, and \
        `limit`. `characters` tells you how long the real body is before you fetch it.
        """,
        inputSchema: Schema.object([
            "search": Schema.string("Substring to match in title or body. Omit to list notes."),
            "folder": Schema.string("Restrict to one folder name"),
            "limit": Schema.integer("Max results (default 25, max 200)"),
            "searchBody": Schema.boolean("Also match note bodies. SLOW: requires reading every note. Default false (title only).")
        ]),
        handler: { args in
            let limit = min(max(1, args.int("limit") ?? 25), 200)
            // A typo'd folder previously came back as a silent empty result,
            // indistinguishable from "that folder has no matching notes".
            if let folder = args.string("folder"), !folder.isEmpty {
                let known = try NotesStore.folders().compactMap { $0.string("folder") }
                if !known.contains(folder) {
                    let near = known.filter {
                        $0.lowercased().contains(folder.lowercased())
                            || folder.lowercased().contains($0.lowercased())
                    }
                    throw ToolError(
                        "No folder named \(folder)."
                        + (near.isEmpty
                            ? " Available folders: \(known.sorted().joined(separator: ", "))."
                            : " Did you mean: \(near.joined(separator: ", "))?"))
                }
            }

            let notes = try NotesStore.search(query: args.string("search"),
                                              folder: args.string("folder"),
                                              limit: limit,
                                              searchBody: args.bool("searchBody") ?? false)
            var out: JSONObject = ["count": notes.count, "notes": notes]
            // AppleScript stops at `limit`, so a full page means there may be
            // more. Say so rather than letting a caller assume it saw everything.
            if notes.count == limit {
                out["truncated"] = true
                out["message"] = "Stopped at the \(limit)-note limit; there may be more. "
                    + "Raise `limit` or narrow with `search`/`folder`."
            }
            if notes.isEmpty {
                out["message"] = args.string("search").map {
                    "No note matched \($0) in note titles. Search is case-sensitive; set searchBody:true to search bodies too."
                } ?? "No notes found."
            }
            return out
        }
    )

    // MARK: notes_read

    private static let readTool = Tool(
        name: "notes_read",
        description: """
        Read one note's full body by `id` (get ids from notes_query). Returns plain text by \
        default; set `html` true for the original markup, which is much larger and only worth it \
        if you need formatting or embedded links.
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Note id from notes_query"),
            "html": Schema.boolean("Return HTML instead of plain text (default false)")
        ], required: ["id"]),
        handler: { args in
            let id = try requireString(args, "id", "note id")
            return try NotesStore.body(id: id, html: args.bool("html") ?? false)
        }
    )

    // MARK: notes_create

    private static let createTool = Tool(
        name: "notes_create",
        description: "Create a note in Apple Notes. `folder` must already exist (see notes_folders). `body` is HTML — use <h2>, <ul>/<li>, <b>, <br>. Notes has no scriptable checklist type, so action items render as bullets; use reminders_create for anything that needs to be checked off.",
        inputSchema: Schema.object([
            "folder": Schema.string("Destination folder name, e.g. Work or Ideas"),
            "title": Schema.string("Note title; becomes the first heading in the body"),
            "body": Schema.string("Note body as HTML"),
            "account": Schema.string("Account name (default: the folder is looked up across accounts)")
        ], required: ["folder", "title", "body"]),
        handler: { args in
            let folder = try requireString(args, "folder", "destination folder name")
            let title = try requireString(args, "title", "note title")
            let body = try requireString(args, "body", "note body as HTML")
            return ["created": try NotesStore.create(
                folder: folder,
                account: args.string("account"),
                title: title,
                bodyHTML: body)]
        }
    )

    // MARK: notes_append

    private static let appendTool = Tool(
        name: "notes_append",
        description: "Append HTML to an existing note, located by `noteId` (from notes_create) or by exact `title` plus optional `folder`.",
        inputSchema: Schema.object([
            "noteId": Schema.string("Note id returned by notes_create"),
            "title": Schema.string("Exact note title, if you do not have the id"),
            "folder": Schema.string("Folder to search when using `title`"),
            "account": Schema.string("Account name, when using `title` with `folder`"),
            "html": Schema.string("HTML fragment to append")
        ], required: ["html"]),
        handler: { args in
            let html = try requireString(args, "html", "HTML fragment to append")
            return ["note": try NotesStore.append(
                noteId: args.string("noteId"),
                title: args.string("title"),
                folder: args.string("folder"),
                account: args.string("account"),
                html: html)]
        }
    )
}
