import XCTest
@testable import NetworkVFS

final class VFSModelsTests: XCTestCase {
    func testFileTypeDetection() {
        let video = VFSFileItem(id: "1", name: "Dune.2024.2160p.DV.mkv", path: "/Dune.mkv", isDirectory: false, size: 1024)
        let sub = VFSFileItem(id: "2", name: "Dune.2024.chs.ass", path: "/Dune.ass", isDirectory: false, size: 512)
        let dir = VFSFileItem(id: "3", name: "Movies.mkv", path: "/Movies.mkv", isDirectory: true, size: 0)

        XCTAssertTrue(video.isVideo)
        XCTAssertFalse(video.isSubtitle)
        XCTAssertTrue(sub.isSubtitle)
        XCTAssertFalse(sub.isVideo)
        XCTAssertFalse(dir.isVideo)
    }
}
