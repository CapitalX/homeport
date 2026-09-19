import Contacts
import Foundation

enum ContactTools {
    private static var cs: ContactsStore { ContactsStore.shared }

    static let all: [Tool] = [
        queryTool,
        createTool,
        updateTool,
        deleteTool,
        groupsTool,
        duplicatesTool,
        mergeTool
    ]

    // MARK: contacts_query

    private static let queryTool = Tool(
        name: "contacts_query",
        description: """
        Search contacts, or list all. `search` matches across name, nickname, organization, job \
        title, EMAIL and PHONE NUMBER — so a phone number from messages_query can be resolved to a \
        person. Phone matching ignores formatting: "555-555-0101", "(555) 555-0101" and \
        "+15555550101" all match the same contact. Matching is substring and case/accent \
        insensitive. Returns `total` alongside `count`, and sets `truncated` when `limit` cut the \
        results short. Notes fields are not included (requires a special Apple entitlement).
        """,
        inputSchema: Schema.object([
            "search": Schema.string("Text to match against name, nickname, organization, email or phone. Omit to list everyone."),
            "limit": Schema.integer("Max results (default 100, 0 for no limit)")
        ]),
        handler: { args in
            try cs.ensureAccess()
            let limit = max(0, args.int("limit") ?? 100)
            let search = args.string("search")

            // Always enumerate and filter in-process rather than using
            // predicateForContacts(matchingName:), which cannot see phone or
            // email at all.
            var all: [CNContact] = []
            let request = CNContactFetchRequest(keysToFetch: ContactsStore.keys)
            request.sortOrder = .givenName
            try cs.store.enumerateContacts(with: request) { contact, _ in
                all.append(contact)
            }

            let matched = (search?.isEmpty == false)
                ? all.filter { ContactMatching.matches($0, query: search!) }
                : all

            let capped = limit == 0 ? matched : Array(matched.prefix(limit))
            var out: JSONObject = [
                "count": capped.count,
                "total": matched.count,
                "contacts": capped.map { contactJSON($0) }
            ]
            // Silent truncation previously hid part of the address book behind
            // the default limit with nothing to indicate it had happened.
            if capped.count < matched.count {
                out["truncated"] = true
                out["message"] = "Showing \(capped.count) of \(matched.count) matches. "
                    + "Raise `limit` or narrow `search` to see the rest."
            }
            if matched.isEmpty, let search, !search.isEmpty {
                out["message"] = "No contact matches \(search). Searched name, nickname, "
                    + "organization, job title, email and phone."
            }
            return out
        }
    )

    // MARK: contacts_create

    private static let createTool = Tool(
        name: "contacts_create",
        description: "Create a contact. At least one of `givenName`, `familyName`, `organization` is required. Optional: `middleName`, `nickname`, `jobTitle`, `department`, `phones` [{label,value}], `emails` [{label,value}], `urls` [{label,value}], `birthday` {month,day,year?}. Labels: home|work|mobile|iphone|main|other or any custom string.",
        inputSchema: Schema.object([
            "givenName": Schema.string("First name"),
            "familyName": Schema.string("Last name"),
            "middleName": Schema.string("Middle name"),
            "nickname": Schema.string("Nickname"),
            "organization": Schema.string("Company / organization"),
            "department": Schema.string("Department"),
            "jobTitle": Schema.string("Job title"),
            "phones": Schema.array("Phone numbers", items: Schema.freeObject("{label,value}")),
            "emails": Schema.array("Email addresses", items: Schema.freeObject("{label,value}")),
            "urls": Schema.array("URLs", items: Schema.freeObject("{label,value}")),
            "birthday": Schema.freeObject("{month, day, year?}")
        ]),
        handler: { args in
            try cs.ensureAccess()
            let contact = CNMutableContact()
            try applyContactFields(contact, args, isCreate: true)
            // On create there is nothing to preserve, so the plain `phones` /
            // `emails` / `urls` lists are simply the initial values -- route
            // them through the same set* path the edit helpers implement.
            var seeded = args
            for (from, to) in [("phones", "setPhones"), ("emails", "setEmails"), ("urls", "setUrls")] {
                if let v = args.array(from) { seeded[to] = v }
            }
            try applyPhoneEdits(contact, seeded)
            try applyEmailEdits(contact, seeded)
            try applyUrlEdits(contact, seeded)

            guard !contact.givenName.isEmpty || !contact.familyName.isEmpty || !contact.organizationName.isEmpty else {
                throw ToolError("Provide at least one of givenName, familyName, or organization.")
            }

            let save = CNSaveRequest()
            save.add(contact, toContainerWithIdentifier: nil)
            try cs.store.execute(save)
            return ["created": contactJSON(contact)]
        }
    )

    // MARK: contacts_update

    private static let updateTool = Tool(
        name: "contacts_update",
        description: """
        Update a contact. Phones, emails and URLs use ADD/REMOVE semantics so an update never \
        destroys values you did not mention: `addPhones` appends (skipping numbers already present), \
        `removePhones` deletes matching entries. Phone comparison ignores formatting. \
        Name/organization fields are set directly when provided.

        `confirmReplace: true` is required for any edit that changes how an existing contact is \
        REACHED — `set*` (discards every entry), `remove*`, or `add*` on a contact that already has \
        an entry of that kind. Adding a first phone or email to a contact that has none is free. \
        Redirecting a saved number or address silently reroutes every future message the user sends \
        from any of their devices, so it takes a deliberate confirmation.
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Contact id"),
            "givenName": Schema.string("First name"),
            "familyName": Schema.string("Last name"),
            "middleName": Schema.string("Middle name"),
            "nickname": Schema.string("Nickname"),
            "organization": Schema.string("Company / organization"),
            "department": Schema.string("Department"),
            "jobTitle": Schema.string("Job title"),
            "addPhones": Schema.array("Phone numbers to ADD", items: Schema.freeObject("{label,value}")),
            "removePhones": Schema.array("Phone numbers to REMOVE (match ignores formatting)", items: Schema.string("number")),
            "setPhones": Schema.array("Replace ALL phones (needs confirmReplace)", items: Schema.freeObject("{label,value}")),
            "addEmails": Schema.array("Emails to ADD", items: Schema.freeObject("{label,value}")),
            "removeEmails": Schema.array("Emails to REMOVE", items: Schema.string("address")),
            "setEmails": Schema.array("Replace ALL emails (needs confirmReplace)", items: Schema.freeObject("{label,value}")),
            "addUrls": Schema.array("URLs to ADD", items: Schema.freeObject("{label,value}")),
            "removeUrls": Schema.array("URLs to REMOVE", items: Schema.string("url")),
            "setUrls": Schema.array("Replace ALL URLs (needs confirmReplace)", items: Schema.freeObject("{label,value}")),
            "confirmReplace": Schema.boolean("Required for set*, remove*, or add* onto an existing phone/email/URL"),
            "birthday": Schema.freeObject("{month,day,year}")
        ], required: ["id"]),
        handler: { args in
            try cs.ensureAccess()
            let id = try requireString(args, "id", "contact id")
            let existing = try cs.contact(byId: id)
            guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                throw ToolError("Could not open contact for editing.")
            }

            let confirmed = args.bool("confirmReplace") == true
            for field in ["setPhones", "setEmails", "setUrls"] where args.array(field) != nil {
                guard confirmed else {
                    throw ToolError(
                        "`\(field)` discards every existing entry on this contact. "
                        + "Pass confirmReplace: true if that is intended, or use "
                        + "`\(field.replacingOccurrences(of: "set", with: "add"))` / "
                        + "`\(field.replacingOccurrences(of: "set", with: "remove"))` to change "
                        + "individual entries without touching the others.")
                }
            }

            // Editing a contact's EXISTING reachability is as consequential as
            // replacing it wholesale, and until now it was the one write in this
            // server with no confirmation at all.
            //
            // The concern is not lost data, it is misdirection: change the number
            // on "Mom" and every future message you send by tapping her name in
            // Messages goes somewhere else. That damage is done by hand, on a
            // device this bridge never touches, long after the edit — iCloud has
            // already synced it everywhere. `messages_send` cannot catch it
            // either: the allowlist matches the literal handle, so the bridge
            // would refuse, and you would still be redirected in Messages.app.
            //
            // Adding a first phone to a contact that has none is pure enrichment
            // and stays free. Removing one, or adding one alongside existing
            // entries (which makes "her number" ambiguous), needs a human to say
            // so.
            try requireConfirmationForReachabilityEdits(
                args: args, existing: existing, confirmed: confirmed)

            try applyContactFields(mutable, args, isCreate: false)
            try applyPhoneEdits(mutable, args)
            try applyEmailEdits(mutable, args)
            try applyUrlEdits(mutable, args)

            let save = CNSaveRequest()
            save.update(mutable)
            try cs.store.execute(save)
            return ["updated": contactJSON(mutable)]
        }
    )

    // MARK: contacts_delete

    private static let deleteTool = Tool(
        name: "contacts_delete",
        description: """
        Delete a contact by `id`. IRREVERSIBLE — the contact is removed from iCloud and every synced \
        device. `confirmDelete` must be explicitly true; without it this returns what WOULD be \
        deleted so you can check it is the right person first.
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Contact id"),
            "confirmDelete": Schema.boolean("Must be true to actually delete. Omit to preview.")
        ], required: ["id"]),
        handler: { args in
            try cs.ensureAccess()
            let id = try requireString(args, "id", "contact id")
            let existing = try cs.contact(byId: id)

            // Deleting the wrong contact on a vague instruction is unrecoverable
            // and syncs everywhere, so the default must be a preview.
            guard args.bool("confirmDelete") == true else {
                return [
                    "deleted": false,
                    "wouldDelete": contactJSON(existing),
                    "message": "Not deleted. Re-call with confirmDelete: true to remove this "
                        + "contact. It syncs to iCloud and cannot be undone."
                ]
            }
            guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                throw ToolError("Could not open contact for deletion.")
            }
            let name = CNContactFormatter.string(from: existing, style: .fullName) ?? ""
            let save = CNSaveRequest()
            save.delete(mutable)
            try cs.store.execute(save)
            return ["deleted": ["id": id, "name": name]]
        }
    )

    // MARK: contacts_duplicates

    private static let duplicatesTool = Tool(
        name: "contacts_duplicates",
        description: """
        Find contacts that look like the same person. Groups by shared phone number (formatting \
        ignored) or shared email — strong evidence — and optionally by identical full name, which is \
        weaker since real people share names. Read-only: it proposes groups, it does not merge. \
        Feed a group's ids to contacts_merge.
        """,
        inputSchema: Schema.object([
            "includeNameOnly": Schema.boolean("Also group contacts that merely share a full name (default false, lower confidence)"),
            "limit": Schema.integer("Max groups to return (default 50)")
        ]),
        handler: { args in
            try cs.ensureAccess()
            let includeNameOnly = args.bool("includeNameOnly") ?? false
            let limit = max(1, args.int("limit") ?? 50)

            var all: [CNContact] = []
            let request = CNContactFetchRequest(keysToFetch: ContactsStore.keys)
            request.sortOrder = .givenName
            try cs.store.enumerateContacts(with: request) { c, _ in all.append(c) }

            let groups = ContactMatching.duplicates(in: all, includeNameOnly: includeNameOnly)
            let shown = Array(groups.prefix(limit))
            var out: JSONObject = [
                "scanned": all.count,
                "groupCount": groups.count,
                "groups": shown.map { g -> JSONObject in
                    [
                        "matchedOn": g.reason.rawValue,
                        "key": g.reason == .phone ? "…\(g.key.suffix(4))" : g.key,
                        "confidence": g.reason == .name ? "low" : "high",
                        "contacts": g.contacts.map { contactJSON($0) }
                    ]
                }
            ]
            if groups.count > shown.count { out["truncated"] = true }
            if groups.isEmpty {
                out["message"] = includeNameOnly
                    ? "No duplicates found."
                    : "No duplicates by phone or email. Try includeNameOnly: true for weaker name-only matches."
            }
            return out
        }
    )

    // MARK: contacts_merge

    private static let mergeTool = Tool(
        name: "contacts_merge",
        description: """
        Merge several contacts into one. The contact named by `keepId` survives and receives the \
        UNION of every phone, email, URL and postal address across the others; name and organization \
        fields are filled in only where the surviving contact is empty, so its own values are never \
        overwritten. The other contacts are then DELETED. IRREVERSIBLE and syncs to iCloud — \
        `confirmMerge` must be explicitly true, and without it this returns a full preview of the \
        merged result and what would be deleted.
        """,
        inputSchema: Schema.object([
            "keepId": Schema.string("Id of the contact to keep"),
            "mergeIds": Schema.array("Ids to merge into it and then delete", items: Schema.string("contact id")),
            "confirmMerge": Schema.boolean("Must be true to actually merge. Omit to preview.")
        ], required: ["keepId", "mergeIds"]),
        handler: { args in
            try cs.ensureAccess()
            let keepId = try requireString(args, "keepId", "contact id to keep")
            guard let rawIds = args.array("mergeIds"), !rawIds.isEmpty else {
                throw ToolError("`mergeIds` is required and must list at least one contact id.")
            }
            let mergeIds = rawIds.compactMap { $0 as? String }.filter { $0 != keepId }
            guard !mergeIds.isEmpty else {
                throw ToolError("`mergeIds` contained only the keepId; nothing to merge.")
            }

            let keeper = try cs.contact(byId: keepId)
            let others = try mergeIds.map { try cs.contact(byId: $0) }
            guard let merged = keeper.mutableCopy() as? CNMutableContact else {
                throw ToolError("Could not open the surviving contact for editing.")
            }

            // Union the multi-value fields, comparing normalized forms so
            // "(555) 555-0101" and "+15555550101" do not both survive.
            var phones = merged.phoneNumbers
            var seenPhones = Set(phones.compactMap { ContactMatching.normalizePhone($0.value.stringValue) })
            var emails = merged.emailAddresses
            var seenEmails = Set(emails.map { ContactMatching.normalizeEmail($0.value as String) })
            var urls = merged.urlAddresses
            var seenUrls = Set(urls.map { ($0.value as String).lowercased() })
            var postals = merged.postalAddresses

            for other in others {
                for p in other.phoneNumbers {
                    guard let n = ContactMatching.normalizePhone(p.value.stringValue), !seenPhones.contains(n)
                    else { continue }
                    seenPhones.insert(n); phones.append(p)
                }
                for e in other.emailAddresses {
                    let n = ContactMatching.normalizeEmail(e.value as String)
                    guard !n.isEmpty, !seenEmails.contains(n) else { continue }
                    seenEmails.insert(n); emails.append(e)
                }
                for u in other.urlAddresses {
                    let n = (u.value as String).lowercased()
                    guard !seenUrls.contains(n) else { continue }
                    seenUrls.insert(n); urls.append(u)
                }
                postals.append(contentsOf: other.postalAddresses)

                // Scalars fill gaps only. Overwriting the keeper's own name with
                // a duplicate's would make the merge lossy in the one direction
                // the caller explicitly chose against.
                if merged.givenName.isEmpty { merged.givenName = other.givenName }
                if merged.familyName.isEmpty { merged.familyName = other.familyName }
                if merged.middleName.isEmpty { merged.middleName = other.middleName }
                if merged.nickname.isEmpty { merged.nickname = other.nickname }
                if merged.organizationName.isEmpty { merged.organizationName = other.organizationName }
                if merged.departmentName.isEmpty { merged.departmentName = other.departmentName }
                if merged.jobTitle.isEmpty { merged.jobTitle = other.jobTitle }
                if merged.birthday == nil { merged.birthday = other.birthday }
            }
            merged.phoneNumbers = phones
            merged.emailAddresses = emails
            merged.urlAddresses = urls
            merged.postalAddresses = postals

            guard args.bool("confirmMerge") == true else {
                return [
                    "merged": false,
                    "wouldKeep": contactJSON(merged),
                    "wouldDelete": others.map { contactJSON($0) },
                    "message": "Not merged. Re-call with confirmMerge: true. This deletes "
                        + "\(others.count) contact(s) and syncs to iCloud; it cannot be undone."
                ]
            }

            let save = CNSaveRequest()
            save.update(merged)
            for other in others {
                guard let m = other.mutableCopy() as? CNMutableContact else { continue }
                save.delete(m)
            }
            try cs.store.execute(save)
            return [
                "merged": true,
                "kept": contactJSON(merged),
                "deleted": others.map { ["id": $0.identifier,
                                         "name": CNContactFormatter.string(from: $0, style: .fullName) ?? ""] }
            ]
        }
    )

    // MARK: contacts_groups

    private static let groupsTool = Tool(
        name: "contacts_groups",
        description: "List Contacts groups (read-only): id and name for each group.",
        inputSchema: Schema.object([:]),
        handler: { _ in
            try cs.ensureAccess()
            let groups = try cs.store.groups(matching: nil)
            return ["groups": groups.map { ["id": $0.identifier, "name": $0.name] }]
        }
    )

    // MARK: - Field application

    private static func applyContactFields(_ contact: CNMutableContact, _ args: JSONObject, isCreate: Bool) throws {
        if let v = args.string("givenName") { contact.givenName = v }
        if let v = args.string("familyName") { contact.familyName = v }
        if let v = args.string("middleName") { contact.middleName = v }
        if let v = args.string("nickname") { contact.nickname = v }
        if let v = args.string("organization") { contact.organizationName = v }
        if let v = args.string("department") { contact.departmentName = v }
        if let v = args.string("jobTitle") { contact.jobTitle = v }

        if let birthday = args.object("birthday") {
            var comps = DateComponents()
            comps.month = birthday.int("month")
            comps.day = birthday.int("day")
            comps.year = birthday.int("year")
            contact.birthday = comps
        }
    }

    // MARK: - Labels

    private static func phoneLabel(_ raw: String?) -> String? {
        switch (raw ?? "").lowercased() {
        case "": return CNLabelPhoneNumberMain
        case "mobile", "cell": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main": return CNLabelPhoneNumberMain
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other": return CNLabelOther
        case "fax", "homefax": return CNLabelPhoneNumberHomeFax
        case "workfax": return CNLabelPhoneNumberWorkFax
        default: return raw
        }
    }

    private static func genericLabel(_ raw: String?) -> String? {
        switch (raw ?? "").lowercased() {
        case "": return CNLabelOther
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other": return CNLabelOther
        default: return raw
        }
    }

    // MARK: - Contact -> JSON


    // MARK: - Add/remove list edits
    //
    // The previous behavior assigned the whole array (`contact.phoneNumbers =
    // ...`), so "add a work number" silently deleted the mobile. These apply
    // targeted edits instead; `set*` still replaces, but only behind
    // confirmReplace.

    private static func applyPhoneEdits(_ contact: CNMutableContact, _ args: JSONObject) throws {
        if let set = args.array("setPhones") {
            contact.phoneNumbers = set.compactMap { entry in
                guard let obj = entry as? JSONObject, let value = obj.string("value") else { return nil }
                return CNLabeledValue(label: phoneLabel(obj.string("label")),
                                      value: CNPhoneNumber(stringValue: value))
            }
            return
        }
        var current = contact.phoneNumbers

        if let remove = args.array("removePhones") {
            let targets = Set(remove.compactMap { ($0 as? String).flatMap(ContactMatching.normalizePhone) })
            current.removeAll { labeled in
                ContactMatching.normalizePhone(labeled.value.stringValue).map(targets.contains) ?? false
            }
        }
        if let add = args.array("addPhones") {
            let existing = Set(current.compactMap { ContactMatching.normalizePhone($0.value.stringValue) })
            for entry in add {
                guard let obj = entry as? JSONObject, let value = obj.string("value") else { continue }
                // Adding a number the contact already has would create a
                // duplicate that then shows up in contacts_duplicates.
                if let n = ContactMatching.normalizePhone(value), existing.contains(n) { continue }
                current.append(CNLabeledValue(label: phoneLabel(obj.string("label")),
                                              value: CNPhoneNumber(stringValue: value)))
            }
        }
        contact.phoneNumbers = current
    }

    private static func applyEmailEdits(_ contact: CNMutableContact, _ args: JSONObject) throws {
        if let set = args.array("setEmails") {
            contact.emailAddresses = set.compactMap { entry in
                guard let obj = entry as? JSONObject, let value = obj.string("value") else { return nil }
                return CNLabeledValue(label: genericLabel(obj.string("label")), value: value as NSString)
            }
            return
        }
        var current = contact.emailAddresses

        if let remove = args.array("removeEmails") {
            let targets = Set(remove.compactMap { ($0 as? String).map(ContactMatching.normalizeEmail) })
            current.removeAll { targets.contains(ContactMatching.normalizeEmail($0.value as String)) }
        }
        if let add = args.array("addEmails") {
            let existing = Set(current.map { ContactMatching.normalizeEmail($0.value as String) })
            for entry in add {
                guard let obj = entry as? JSONObject, let value = obj.string("value") else { continue }
                if existing.contains(ContactMatching.normalizeEmail(value)) { continue }
                current.append(CNLabeledValue(label: genericLabel(obj.string("label")), value: value as NSString))
            }
        }
        contact.emailAddresses = current
    }

    private static func applyUrlEdits(_ contact: CNMutableContact, _ args: JSONObject) throws {
        if let set = args.array("setUrls") {
            contact.urlAddresses = set.compactMap { entry in
                guard let obj = entry as? JSONObject, let value = obj.string("value") else { return nil }
                return CNLabeledValue(label: genericLabel(obj.string("label")), value: value as NSString)
            }
            return
        }
        var current = contact.urlAddresses

        if let remove = args.array("removeUrls") {
            let targets = Set(remove.compactMap { ($0 as? String)?.lowercased() })
            current.removeAll { targets.contains(($0.value as String).lowercased()) }
        }
        if let add = args.array("addUrls") {
            let existing = Set(current.map { ($0.value as String).lowercased() })
            for entry in add {
                guard let obj = entry as? JSONObject, let value = obj.string("value") else { continue }
                if existing.contains(value.lowercased()) { continue }
                current.append(CNLabeledValue(label: genericLabel(obj.string("label")), value: value as NSString))
            }
        }
        contact.urlAddresses = current
    }

    private static func contactJSON(_ c: CNContact) -> JSONObject {
        var o: JSONObject = ["id": c.identifier]
        o["name"] = CNContactFormatter.string(from: c, style: .fullName) ?? ""
        if isAvailable(c, CNContactGivenNameKey), !c.givenName.isEmpty { o["givenName"] = c.givenName }
        if isAvailable(c, CNContactMiddleNameKey), !c.middleName.isEmpty { o["middleName"] = c.middleName }
        if isAvailable(c, CNContactFamilyNameKey), !c.familyName.isEmpty { o["familyName"] = c.familyName }
        if isAvailable(c, CNContactNicknameKey), !c.nickname.isEmpty { o["nickname"] = c.nickname }
        if isAvailable(c, CNContactOrganizationNameKey), !c.organizationName.isEmpty { o["organization"] = c.organizationName }
        if isAvailable(c, CNContactDepartmentNameKey), !c.departmentName.isEmpty { o["department"] = c.departmentName }
        if isAvailable(c, CNContactJobTitleKey), !c.jobTitle.isEmpty { o["jobTitle"] = c.jobTitle }

        if isAvailable(c, CNContactPhoneNumbersKey), !c.phoneNumbers.isEmpty {
            // Stored formats are wildly inconsistent -- "+15555550102",
            // "(555) 555-0103", "5555550105", "555.555.0104;223" -- and
            // shortcodes like "12345" sit in the same field as real numbers.
            // Resolving a recipient is the step immediately before an
            // irreversible send, so emit a normalized form rather than making
            // every caller reimplement this.
            o["phones"] = c.phoneNumbers.map { labeled -> JSONObject in
                let raw = labeled.value.stringValue
                var entry: JSONObject = ["label": localized(labeled.label), "value": raw]
                if let e164 = ContactMatching.e164(raw) {
                    entry["e164"] = e164
                } else if ContactMatching.isShortcode(raw) {
                    entry["isShortcode"] = true
                }
                return entry
            }
            let e164s = c.phoneNumbers.compactMap { ContactMatching.e164($0.value.stringValue) }
            if !e164s.isEmpty { o["phonesE164"] = Array(NSOrderedSet(array: e164s)) as? [String] ?? e164s }
        }
        if isAvailable(c, CNContactEmailAddressesKey), !c.emailAddresses.isEmpty {
            o["emails"] = c.emailAddresses.map { labeled -> JSONObject in
                ["label": localized(labeled.label), "value": labeled.value as String]
            }
        }
        if isAvailable(c, CNContactUrlAddressesKey), !c.urlAddresses.isEmpty {
            o["urls"] = c.urlAddresses.map { labeled -> JSONObject in
                ["label": localized(labeled.label), "value": labeled.value as String]
            }
        }
        if isAvailable(c, CNContactPostalAddressesKey), !c.postalAddresses.isEmpty {
            o["postalAddresses"] = c.postalAddresses.map { labeled -> JSONObject in
                [
                    "label": localized(labeled.label),
                    "value": CNPostalAddressFormatter.string(from: labeled.value, style: .mailingAddress)
                ]
            }
        }
        if isAvailable(c, CNContactBirthdayKey), let bday = c.birthday {
            var b: JSONObject = [:]
            if let m = bday.month { b["month"] = m }
            if let d = bday.day { b["day"] = d }
            if let y = bday.year { b["year"] = y }
            if !b.isEmpty { o["birthday"] = b }
        }
        return o
    }

    private static func isAvailable(_ c: CNContact, _ key: String) -> Bool {
        c.isKeyAvailable(key)
    }

    private static func localized(_ label: String?) -> String {
        guard let label else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }

    /// Require `confirmReplace` for any edit that removes or shadows a contact's
    /// existing phone/email/URL.
    ///
    /// Split out of the handler because the rule is per-field and the reasoning
    /// is worth reading once rather than three times inline.
    private static func requireConfirmationForReachabilityEdits(
        args: JSONObject, existing: CNContact, confirmed: Bool) throws {

        guard !confirmed else { return }

        // (add key, remove key, how many of this kind the contact already has)
        let fields: [(String, String, Int, String)] = [
            ("addPhones", "removePhones", existing.phoneNumbers.count, "phone number"),
            ("addEmails", "removeEmails", existing.emailAddresses.count, "email address"),
            ("addUrls",   "removeUrls",   existing.urlAddresses.count,   "URL")
        ]

        for (addKey, removeKey, existingCount, label) in fields {
            if let removals = args.array(removeKey), !removals.isEmpty {
                throw ToolError(
                    "`\(removeKey)` deletes a \(label) this contact already has. "
                    + "Changing how someone is reached silently redirects every future "
                    + "message you send them from any device. Pass confirmReplace: true "
                    + "to proceed.")
            }
            if let additions = args.array(addKey), !additions.isEmpty, existingCount > 0 {
                throw ToolError(
                    "`\(addKey)` adds a \(label) to a contact that already has "
                    + "\(existingCount). That makes which one is \"theirs\" ambiguous for "
                    + "anything picking automatically. Pass confirmReplace: true to proceed, "
                    + "or edit the contact by hand.")
            }
        }
    }
}
