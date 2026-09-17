// Verify release metadata and Ed25519 archive authenticity using only the shipped public key.
import Foundation
import CryptoKit

final class Feed: NSObject, XMLParserDelegate {
    var version = ""
    var enclosure: [String: String] = [:]
    var itemCount = 0
    private var readingVersion = false
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "item" { itemCount += 1 }
        if element == "sparkle:version" { readingVersion = true }
        if element == "enclosure" { enclosure = attributes }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingVersion { version += string }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "sparkle:version" { readingVersion = false }
    }
}

func verify() throws {
    let args = CommandLine.arguments
    guard args.count == 5 else { throw NSError(domain: "UsageBarUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: verify-update.swift appcast archive public-key expected-version"]) }
    let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: args[1])))
    let feed = Feed()
    parser.delegate = feed
    guard parser.parse(), feed.itemCount == 1, feed.version == args[4] else {
        throw NSError(domain: "UsageBarUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid appcast version or item count"])
    }
    let archive = URL(fileURLWithPath: args[2])
    let data = try Data(contentsOf: archive)
    let expectedURL = "https://github.com/kubilayege/UsageBar/releases/download/v\(args[4])/\(archive.lastPathComponent)"
    guard feed.enclosure["url"] == expectedURL, feed.enclosure["length"] == String(data.count),
          let signature = feed.enclosure["sparkle:edSignature"].flatMap({ Data(base64Encoded: $0) }),
          let key = Data(base64Encoded: try String(contentsOfFile: args[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)),
          try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: data) else {
        throw NSError(domain: "UsageBarUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Archive signature, size, or URL did not match the published update"])
    }
    print("Verified UsageBar \(feed.version): archive signature, version, URL, and size")
}

do { try verify() }
catch { fputs("Update verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
