import Contacts
import Foundation

/// Matching and de-duplication helpers for Contacts.
///
/// `CNContact.predicateForContacts(matchingName:)` only matches names, which is
/// the single biggest gap in practice: `messages_query` hands back phone
/// numbers, so without number matching there is no way to answer "who is
/// +15555550101?" and every message-driven workflow dead-ends.
enum ContactMatching {

    /// Reduce a phone number to comparable digits.
    ///
    /// The same person is stored as "(555) 555-0101", "555-555-0101",
    /// "+1 555 555 0101" and "5555550101" across devices and imports, so a
    /// literal comparison finds nothing. Compare the last 10 digits: that
    /// ignores country-code and trunk-prefix variation without colliding, since
    /// two different US numbers cannot share all 10.
    static func normalizePhone(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    static func normalizeEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Fold a name for comparison: case, diacritics and punctuation all vary
    /// between a hand-typed contact and an imported one.
    static func normalizeName(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Does this contact match a free-text query across every field a person
    /// would plausibly search by?
    static func matches(_ contact: CNContact, query: String) -> Bool {
        let q = normalizeName(query)
        guard !q.isEmpty else { return true }

        // A query that is mostly digits is a phone number; compare it as one
        // rather than as text, so "555-555-0101" finds "+15555550101".
        if let queryDigits = normalizePhone(query), query.filter(\.isNumber).count >= 7 {
            for phone in contact.phoneNumbers
            where normalizePhone(phone.value.stringValue) == queryDigits {
                return true
            }
        }

        var haystack: [String] = [
            contact.givenName, contact.familyName, contact.middleName,
            contact.nickname, contact.organizationName, contact.departmentName,
            contact.jobTitle,
        ]
        haystack.append(CNContactFormatter.string(from: contact, style: .fullName) ?? "")
        haystack += contact.emailAddresses.map { $0.value as String }
        haystack += contact.phoneNumbers.map { $0.value.stringValue }

        return haystack.contains { normalizeName($0).contains(q) }
    }

    // MARK: - Duplicates

    /// Why two contacts were grouped together.
    enum Reason: String {
        case phone
        case email
        case name
    }

    struct DuplicateGroup {
        let reason: Reason
        let key: String
        let contacts: [CNContact]
    }

    /// Group contacts that appear to be the same person.
    ///
    /// A shared phone number or email is strong evidence. A shared normalized
    /// full name is weaker — real people share names — so it is reported as a
    /// separate, lower-confidence reason rather than merged into the same
    /// bucket, letting the caller decide how much to trust it.
    static func duplicates(in contacts: [CNContact], includeNameOnly: Bool) -> [DuplicateGroup] {
        var byPhone: [String: [CNContact]] = [:]
        var byEmail: [String: [CNContact]] = [:]
        var byName: [String: [CNContact]] = [:]

        for c in contacts {
            for p in c.phoneNumbers {
                if let key = normalizePhone(p.value.stringValue) {
                    byPhone[key, default: []].append(c)
                }
            }
            for e in c.emailAddresses {
                let key = normalizeEmail(e.value as String)
                if !key.isEmpty { byEmail[key, default: []].append(c) }
            }
            let name = normalizeName(CNContactFormatter.string(from: c, style: .fullName) ?? "")
            if !name.isEmpty { byName[name, default: []].append(c) }
        }

        var groups: [DuplicateGroup] = []
        var alreadyPaired = Set<String>()   // "idA|idB", so one pair is reported once

        func add(_ reason: Reason, _ key: String, _ list: [CNContact]) {
            // A single contact listing the same number twice is not a duplicate.
            var unique: [CNContact] = []
            var seen = Set<String>()
            for c in list where !seen.contains(c.identifier) {
                seen.insert(c.identifier); unique.append(c)
            }
            guard unique.count > 1 else { return }
            let ids = unique.map(\.identifier).sorted().joined(separator: "|")
            guard !alreadyPaired.contains(ids) else { return }
            alreadyPaired.insert(ids)
            groups.append(DuplicateGroup(reason: reason, key: key, contacts: unique))
        }

        for (k, v) in byPhone { add(.phone, k, v) }
        for (k, v) in byEmail { add(.email, k, v) }
        if includeNameOnly { for (k, v) in byName { add(.name, k, v) } }
        return groups
    }

    // MARK: - Normalization for output

    /// Best-effort E.164, or nil when the value is not a dialable number.
    ///
    /// Deliberately conservative: it only claims E.164 when it can justify one.
    /// A wrong "+1" on a foreign number would be worse than no answer at all,
    /// given the next step is usually an irreversible send.
    static func e164(_ raw: String) -> String? {
        // Extensions ("555.555.0104;223") are not part of the dialable number.
        let trunk = raw.split(whereSeparator: { ";,".contains($0) }).first.map(String.init) ?? raw
        let digits = trunk.filter(\.isNumber)
        guard !isShortcode(trunk) else { return nil }

        if trunk.hasPrefix("+") {
            return digits.count >= 8 ? "+" + digits : nil
        }
        // North America is the only region we can infer safely from length.
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return nil
    }

    /// SMS shortcodes (banks, 2FA, marketing) are 3-8 digits with no country
    /// code. They live in the same field as real numbers and are NOT dialable
    /// in the usual sense, so flagging them stops a caller treating one as a
    /// truncated phone number.
    static func isShortcode(_ raw: String) -> Bool {
        guard !raw.contains("+") else { return false }
        let digits = raw.filter(\.isNumber)
        return digits.count >= 3 && digits.count <= 8 && digits.count == raw.filter { !$0.isWhitespace }.count
    }
}
