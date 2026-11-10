import Foundation
import Testing
@testable import DuoCore

struct NativeTouchTests {
    @Test func edgeGestureHintIsOptionalAndRejectsUnknownValues() throws {
        let old = Data(#"{"id":1,"x":0.5,"y":1}"#.utf8)
        let contact = try JSONDecoder().decode(NativeTouchContact.self, from: old)
        #expect(contact.edgeGesture == nil)
        let encoded = try JSONEncoder().encode(contact)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["edgeGesture"] == nil)
        let bezel = NativeTouchContact(id: 1, x: 0.5, y: 1, edgeGesture: .dock)
        #expect(try JSONDecoder().decode(NativeTouchContact.self, from: JSONEncoder().encode(bezel)) == bezel)
        let invalid = Data(#"{"id":1,"x":0.5,"y":1,"edgeGesture":"yes"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NativeTouchContact.self, from: invalid) }
    }

    @Test func validatesBoundedDistinctContacts() throws {
        let context = UUID()
        let contacts = (1...5).map { NativeTouchContact(id: UInt8($0), x: Double($0) / 5, y: 0.5) }
        let frame = NativeTouchFrame(contextID: context, contacts: contacts)
        #expect(frame.isValid)
        #expect(try JSONDecoder().decode(NativeTouchFrame.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(NativeTouchFrame(contextID: context, contacts: []).isValid)
        #expect(!NativeTouchFrame(contextID: context, contacts: contacts + [.init(id: 6, x: 0.5, y: 0.5)]).isValid)
        #expect(!NativeTouchFrame(contextID: context, contacts: [contacts[0], contacts[0]]).isValid)
        #expect(!NativeTouchContact(id: 0, x: 0.5, y: 0.5).isValid)
        #expect(!NativeTouchContact(id: 128, x: 0.5, y: 0.5).isValid)
        #expect(!NativeTouchContact(id: 1, x: .nan, y: 0.5).isValid)
        #expect(!NativeTouchContact(id: 1, x: 0.5, y: .infinity).isValid)
        #expect(!NativeTouchContact(id: 1, x: -0.001, y: 0.5).isValid)
        #expect(!NativeTouchContact(id: 1, x: 0.5, y: 1.001).isValid)
    }

    @Test func readyStatusRequiresContextAndNoFailure() {
        #expect(NativeTouchStatus(.ready, contextID: UUID()).isValid)
        #expect(!NativeTouchStatus(.ready).isValid)
        #expect(!NativeTouchStatus(.paused, contextID: UUID()).isValid)
        #expect(!NativeTouchStatus(.ready, contextID: UUID(), failure: .device).isValid)
    }

    @Test func oldHostsDoNotAdvertiseNativeTouch() throws {
        let old = Data(#"{"state":"approved","message":"Connected"}"#.utf8)
        #expect(try JSONDecoder().decode(AuthorizationResult.self, from: old).supportsNativeTouch == nil)
    }
}
