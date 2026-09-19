import Contacts
import Foundation

/// Owns the shared CNContactStore and its permission handling. Contacts is a
/// separate TCC domain from EventKit ("AddressBook"), but the disclaim shim in
/// main.swift makes this binary the responsible process for it too, so the
/// grant is durable across MCP hosts.
final class ContactsStore {
    static let shared = ContactsStore()
    let store = CNContactStore()

    private init() {}

    /// Keys we fetch/read. Deliberately excludes `CNContactNoteKey`, which
    /// requires the special `com.apple.developer.contacts.notes` entitlement and
    /// throws if requested without it.
    static let keys: [CNKeyDescriptor] = {
        var k: [CNKeyDescriptor] = [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactFamilyNameKey,
            CNContactNamePrefixKey,
            CNContactNameSuffixKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactDepartmentNameKey,
            CNContactJobTitleKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactPostalAddressesKey,
            CNContactUrlAddressesKey,
            CNContactBirthdayKey
        ].map { $0 as CNKeyDescriptor }
        k.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))
        return k
    }()

    /// Ensure access, requesting it if needed. Mirrors the EventKit re-check
    /// pattern: never trust a single callback; re-read the authoritative status.
    func ensureAccess() throws {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return }

        let semaphore = DispatchSemaphore(value: 0)
        var callbackGranted = false
        var callbackError: Error?
        store.requestAccess(for: .contacts) { granted, error in
            callbackGranted = granted
            callbackError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 60)

        // Authoritative re-check (same defensive pattern as EventKit).
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return }
        if callbackGranted && callbackError == nil { return }

        throw ToolError("""
        Contacts access is not granted. Grant it in System Settings ▸ Privacy & Security ▸ Contacts \
        and enable "Apple MCP Bridge" (or "Homeport"). If it is missing or stuck, reset and retry: \
        `tccutil reset AddressBook` then trigger this tool again.
        """)
    }

    func contact(byId id: String) throws -> CNContact {
        do {
            return try store.unifiedContact(withIdentifier: id, keysToFetch: ContactsStore.keys)
        } catch {
            throw ToolError("Contact not found for id: \(id)")
        }
    }
}
