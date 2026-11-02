import Foundation
import Testing

@testable import trailmix

/// The SOP library as the start prompt lists it and offers it in the Role
/// and Objective boxes. Reads a tree laid out the way the convention says
/// and checks the kinds and the lists; the window on top of this is checked
/// by hand.
@Suite("SOPTree")
struct SOPTreeTests {

    private static let layout = SessionNaming.Layout.default

    private func make(_ root: URL, _ path: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true
        )
    }

    @Test("no library yet reads as nil")
    func missingLibrary() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            #expect(SOPTree.read(root: root, layout: Self.layout) == nil)
        }
    }

    @Test("folders are classified by their place in the tree, drafts listed first")
    func kinds() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let lib = Self.layout.sopRoot
            try make(root, "\(lib)/Need To build SOP/EBOS-Create Material Roof Estimate/Bidding.9.30.26")
            try make(root, "\(lib)/Need To build SOP/EBOS-Create Material Roof Estimate/notes")
            try make(root, "\(lib)/Admin-Onboarding/Day one-Accounts.10.1.26")
            try make(root, "\(lib)/.hidden/x")

            let tree = try #require(SOPTree.read(root: root, layout: Self.layout))
            #expect(tree.kind == .sopRoot)
            #expect(tree.children.map(\.name) == ["Need To build SOP", "Admin-Onboarding"])
            #expect(tree.children.map(\.kind) == [.drafts, .roleObjective])

            let drafts = tree.children[0]
            #expect(drafts.children.map(\.name) == ["EBOS-Create Material Roof Estimate"])
            #expect(drafts.children[0].kind == .roleObjective)
            #expect(drafts.children[0].children.map(\.kind) == [.session, .other])

            #expect(tree.children[1].children.map(\.kind) == [.session])
        }
    }

    @Test("roles and objectives are collected across finalized and draft folders")
    func rolesAndObjectives() async throws {
        try await SessionFixtures.inTemporaryDirectory { root in
            let lib = Self.layout.sopRoot
            try make(root, "\(lib)/Need To build SOP/EBOS-Create Material Roof Estimate")
            try make(root, "\(lib)/Need To build SOP/EBOS-Review Full Reroof")
            try make(root, "\(lib)/Admin-Onboarding")
            try make(root, "\(lib)/EBOS-Create Material Roof Estimate")   // finalized copy of the same process

            let tree = try #require(SOPTree.read(root: root, layout: Self.layout))
            #expect(SOPTree.roles(in: tree) == ["Admin", "EBOS"])
            #expect(SOPTree.objectives(in: tree, forRole: "EBOS") == ["Create Material Roof Estimate", "Review Full Reroof"])
            #expect(SOPTree.objectives(in: tree, forRole: "ebos") == ["Create Material Roof Estimate", "Review Full Reroof"])
            #expect(SOPTree.objectives(in: tree, forRole: "Nobody") == ["Create Material Roof Estimate", "Onboarding", "Review Full Reroof"])
            #expect(SOPTree.objectives(in: tree, forRole: nil).count == 3)
        }
    }
}
