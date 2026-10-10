import XCTest
import Darwin
import MochiKernel
@testable import MochiCore

final class PersistenceRemediationTests: XCTestCase {
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-persistence-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }

    // MARK: Data folder (H2)

    func testStrayFilesWithoutAnOlderLibraryNeverBlockStartup() throws {
        let parent = temporary(), mochi = parent.appendingPathComponent(AppIdentity.name)
        try FileManager.default.createDirectory(at:mochi,withIntermediateDirectories:true)
        for name in ["builtin-preview.wav",".DS_Store",".library-write-\(UUID()).json"] { try Data([1]).write(to:mochi.appendingPathComponent(name)) }
        XCTAssertEqual(try AppIdentity.prepareDataDirectory(in:parent).path,mochi.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath:mochi.appendingPathComponent("builtin-preview.wav").path))
    }
    func testStrayFilesBlockOnlyAMigrationAndTheMessageSaysWhy() throws {
        let parent = temporary(), mochi = parent.appendingPathComponent(AppIdentity.name)
        var library = Library(); library.conversations = [Conversation(title:"Old")]
        try LibraryStore(root:parent.appendingPathComponent(AppIdentity.legacyDataDirectory)).save(library)
        try FileManager.default.createDirectory(at:mochi,withIntermediateDirectories:true)
        try Data([1]).write(to:mochi.appendingPathComponent("builtin-preview.wav"))
        XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in:parent)) { error in
            XCTAssertTrue(AppFailure.message(for:error,fallback:"").contains(AppIdentity.legacyDataDirectory))
        }
        XCTAssertEqual(AppIdentity.recoveryFolder(in:parent).path,mochi.path)
    }
    func testRecoveryFolderIsTheOlderLibraryWhenTheMochiFolderIsEmpty() throws {
        let parent = temporary(), legacy = parent.appendingPathComponent(AppIdentity.legacyDataDirectory)
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        XCTAssertEqual(AppIdentity.recoveryFolder(in:parent).path,legacy.path)
    }

    // MARK: Saving (H1, L2)

    func testUnchangedLibraryIsNotReReadButAnExternalChangeIs() throws {
        let root = temporary(), store = LibraryStore(root:root)
        var library = Library(); library.conversations = [Conversation(title:"First")]
        // A new library settles its one-time upgrade copies on the second save.
        try store.save(library); try store.save(library)
        // A file Mochi wrote itself is replaced without being read, even when it is unreadable.
        XCTAssertEqual(chmod(store.file.path,0),0)
        library.conversations[0].title = "Second"
        XCTAssertNoThrow(try store.save(library))
        XCTAssertEqual(try store.load().conversations[0].title,"Second")
        // A file changed by someone else is read first, and an unreadable one is never overwritten.
        try Data("not a library".utf8).write(to:store.file)
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try String(contentsOf:store.file),"not a library")
    }
    func testEarlierCopyIsKeptAndRestoreSetsTheUnreadableFileAside() throws {
        let root = temporary(), store = LibraryStore(root:root)
        var library = Library(); library.conversations = [Conversation(title:"Kept")]
        try store.save(library)
        library.conversations[0].title = "Latest"; try store.save(library)
        XCTAssertEqual(try store.loadPrevious().conversations[0].title,"Kept")
        try Data("damaged".utf8).write(to:store.file)
        XCTAssertThrowsError(try LibraryStore(root:root).load())
        let restored = try LibraryStore(root:root).restorePrevious()
        XCTAssertEqual(restored.conversations[0].title,"Kept")
        XCTAssertEqual(try LibraryStore(root:root).load().conversations[0].title,"Kept")
        let aside = try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix("library-unreadable-") }
        XCTAssertEqual(aside.count,1)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(aside[0])),"damaged")
    }
    func testSaveLeavesNoStagingFilesAndWritesPrivately() throws {
        let root = temporary(), store = LibraryStore(root:root)
        var library = Library(); library.conversations = [Conversation()]
        try store.save(library); try store.save(library)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".") })
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:store.file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testRecoveryFileNamesAreNeverRecordingNames() {
        for name in ["library.previous.json","library-unreadable-1-x.json"] {
            var library = Library(); var chat = Conversation(); chat.messages = [Message(role:"user",text:"",audio:name)]
            library.conversations = [chat]
            XCTAssertThrowsError(try library.validate(),name)
        }
    }
    func testInvalidInMemoryLibraryIsReportedAsAnInvariantViolation() throws {
        let root = temporary(), store = LibraryStore(root:root)
        let chat = Conversation(); var library = Library(); library.conversations = [chat,chat]
        XCTAssertThrowsError(try store.save(library)) { error in
            XCTAssertTrue((error as? AppFailure)?.underlying is LibraryInvariantViolation)
        }
    }
    func testLargeLibrarySaveCost() throws {
        let root = temporary(), store = LibraryStore(root:root)
        var library = Library()
        library.conversations = (0..<100).map { n in
            var chat = Conversation(title:"Conversation \(n)")
            chat.messages = (0..<50).map { Message(role:$0.isMultiple(of:2) ? "user" : "assistant",text:"Message \($0) in a realistic sentence of moderate length.") }
            return chat
        }
        try store.save(library)
        measure { try? store.save(library) }
    }

    // MARK: Error classification (M3)

    func testOutOfSpaceIsRecognisedThroughTheCauseChain() {
        XCTAssertTrue(ErrorChain.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(ErrorChain.isOutOfSpace(POSIXError(.ENOSPC)))
        XCTAssertTrue(ErrorChain.isOutOfSpace(AppFailure("Could not save.",underlying:POSIXError(.EDQUOT))))
        XCTAssertFalse(ErrorChain.isOutOfSpace(POSIXError(.EACCES)))
        XCTAssertFalse(ErrorChain.isOutOfSpace(AppFailure("The disk is full.")))
    }
}
