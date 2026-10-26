import XCTest
@testable import DSMSSH

final class FingerprintTests: XCTestCase {
    func testMatchesOpenSSHFormat() {
        // Expected value computed independently: sha256 of the base64-decoded blob, unpadded base64.
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@nas"
        XCTAssertEqual(sshFingerprint(openSSHKey: key), "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
        XCTAssertNil(sshFingerprint(openSSHKey: "garbage"))
    }

    func testConnectFailureMessages() {
        struct Fake: Error, CustomStringConvertible { let description: String }
        XCTAssertEqual(SSHSession.describeConnectFailure(Fake(description: "connection reset (error set): Connection refused (errno: 61)")),
                       "端口拒绝连接（SSH 未启用或端口不对）")
        XCTAssertTrue(SSHSession.describeConnectFailure(Fake(description: "connectTimeout(NIOCore.TimeAmount(nanoseconds: 1))")).hasPrefix("连接超时"))
    }
}
