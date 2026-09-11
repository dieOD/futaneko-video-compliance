import Darwin
import Foundation

/// NijiMp4ExportPaths の実パス境界をmacOS上で確認する単体試験。
///
/// 製品のFlutterやMpvは読み込まず、試験用ディレクトリ以外へ書き込まない。
@main
struct Mp4ExportPathsTest {
  private struct TestFailure: Error, CustomStringConvertible {
    let description: String
  }

  private static let fileManager = FileManager.default
  private static var passed = 0

  static func main() {
    do {
      try run()
      print("MP4パス検証テスト: \(passed)件合格")
    } catch {
      fputs("MP4パス検証テスト: 失敗: \(error)\n", stderr)
      exit(EXIT_FAILURE)
    }
  }

  private static func run() throws {
    let root = try makeTestRoot()
    defer { try? fileManager.removeItem(atPath: root) }

    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
    let secureURL = cacheURL.appendingPathComponent(
      "nijineko-secure-video",
      isDirectory: true
    )
    let outsideURL = rootURL.appendingPathComponent("outside", isDirectory: true)
    let otherURL = cacheURL.appendingPathComponent("other", isDirectory: true)
    for directory in [cacheURL, secureURL, outsideURL, otherURL] {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    guard let canonicalCache = posixRealpath(cacheURL.path),
          let cacheAlias = osAlias(for: canonicalCache),
          posixRealpath(cacheAlias) == canonicalCache else {
      throw TestFailure(description: "macOSの/tmp実エイリアスを作成できません")
    }

    let canonicalSecure = secureURL.path
    let input = path(in: secureURL, name: hex("a") + ".webm")
    let output = path(in: secureURL, name: hex("b") + ".mp4")
    try writeRegularFile(input)

    // cacheだけは /tmp と /private/tmp のOS別名を許容する。
    try expect(
      NijiMp4ExportPaths.isValid(
        input,
        output,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "正規入力・正規出力・cacheの/tmp別名"
    )
    try expect(
      NijiMp4ExportPaths.isValid(
        input,
        output,
        cache: URL(fileURLWithPath: canonicalCache, isDirectory: true)
      ),
      "正規入力・正規出力・cacheのcanonical path"
    )

    // 入力と出力自身の /tmp 別名は、realpath文字列一致を破るため許可しない。
    let inputAlias = try requireAlias(for: input)
    let outputAlias = try requireAlias(for: output)
    try expect(
      !NijiMp4ExportPaths.isValid(
        inputAlias,
        output,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "入力の/tmp別名を拒否"
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        outputAlias,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "出力の/tmp別名を拒否"
    )

    // Dart側が生成する3拡張子をすべて許可する。
    for (letter, fileExtension) in [("c", "webm"), ("d", "mov"), ("e", "mp4")] {
      let source = path(in: secureURL, name: hex(letter) + "." + fileExtension)
      let outputLetter = ["c": "1", "d": "2", "e": "3"][letter]!
      let target = path(in: secureURL, name: hex(outputLetter) + ".mp4")
      try writeRegularFile(source)
      try expect(
        NijiMp4ExportPaths.isValid(
          source,
          target,
          cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
        ),
        "入力拡張子 .\(fileExtension)"
      )
    }

    // 正規化済みの管理領域以外を拒否する。
    let outsideFile = path(in: outsideURL, name: hex("f") + ".webm")
    try writeRegularFile(outsideFile)
    try expect(
      !NijiMp4ExportPaths.isValid(
        outsideFile,
        path(in: secureURL, name: hex("1") + ".mp4"),
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "Caches外の入力を拒否"
    )

    let nestedSecureURL = otherURL.appendingPathComponent(
      "nijineko-secure-video",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: nestedSecureURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let nestedInput = path(in: nestedSecureURL, name: hex("2") + ".webm")
    try writeRegularFile(nestedInput)
    try expect(
      !NijiMp4ExportPaths.isValid(
        nestedInput,
        path(in: nestedSecureURL, name: hex("3") + ".mp4"),
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "Caches直下でない同名管理領域を拒否"
    )

    // 管理ディレクトリ自身のsymlinkを拒否する。
    let linkedCacheURL = rootURL.appendingPathComponent(
      "linked-cache",
      isDirectory: true
    )
    let linkedSecureURL = linkedCacheURL.appendingPathComponent(
      "nijineko-secure-video",
      isDirectory: true
    )
    let linkedTargetURL = outsideURL.appendingPathComponent(
      "linked-secure-video",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: linkedCacheURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try fileManager.createDirectory(
      at: linkedTargetURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try makeSymlink(target: linkedTargetURL.path, at: linkedSecureURL.path)
    let linkedInput = path(in: linkedSecureURL, name: hex("4") + ".webm")
    try writeRegularFile(path(in: linkedTargetURL, name: hex("4") + ".webm"))
    try expect(
      !NijiMp4ExportPaths.isValid(
        linkedInput,
        path(in: linkedSecureURL, name: hex("5") + ".mp4"),
        cache: URL(fileURLWithPath: linkedCacheURL.path, isDirectory: true)
      ),
      "symlink管理ディレクトリを拒否"
    )

    // 入力は通常ファイルかつPOSIX realpathと文字列一致でなければならない。
    let internalLink = path(in: secureURL, name: hex("6") + ".webm")
    try makeSymlink(target: input, at: internalLink)
    try expect(
      !NijiMp4ExportPaths.isValid(
        internalLink,
        path(in: secureURL, name: hex("7") + ".mp4"),
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "管理領域内を指す入力symlinkを拒否"
    )

    let externalLink = path(in: secureURL, name: hex("8") + ".webm")
    try makeSymlink(target: outsideFile, at: externalLink)
    try expect(
      !NijiMp4ExportPaths.isValid(
        externalLink,
        path(in: secureURL, name: hex("9") + ".mp4"),
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "Caches外を指す入力symlinkを拒否"
    )

    let directoryInput = path(in: secureURL, name: hex("0") + ".webm")
    try fileManager.createDirectory(
      atPath: directoryInput,
      withIntermediateDirectories: false,
      attributes: nil
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        directoryInput,
        path(in: secureURL, name: hex("a") + ".mp4"),
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "ディレクトリ入力を拒否"
    )

    // 入力・出力の名前とパス構文を固定する。
    let invalidNames = [
      hex("A") + ".webm", // 大文字hex
      String(repeating: "a", count: 31) + ".webm",
      String(repeating: "a", count: 33) + ".webm",
      hex("a") + ".WEBM",
      hex("a") + ".avi",
      hex("a") + "\n.webm",
      hex("a") + ".webm\n",
      hex("g") + ".webm", // 非hex文字
    ]
    let validOutputLetters = ["1", "2", "3", "4", "5", "6", "7", "8"]
    for (index, name) in invalidNames.enumerated() {
      let invalidInput = path(in: secureURL, name: name)
      try writeRegularFile(invalidInput)
      try expect(
        !NijiMp4ExportPaths.isValid(
          invalidInput,
          path(in: secureURL, name: hex(validOutputLetters[index]) + ".mp4"),
          cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
        ),
        "不正な入力名 \(index + 1)"
      )
    }

    try expect(
      !NijiMp4ExportPaths.isValid(
        "relative/\(hex("a")).webm",
        output,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "相対入力を拒否"
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        secureURL.path + "/../nijineko-secure-video/\(hex("a")).webm",
        output,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "正規ファイルを指す../入力を拒否"
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        input + "\0suffix",
        output,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "NULを含む入力を拒否"
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        output + "\0suffix",
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "NULを含む出力を拒否"
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        "relative/\(hex("b")).mp4",
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "相対出力を拒否"
    )

    let invalidOutputNames = [
      hex("A") + ".mp4", // 大文字hex
      String(repeating: "a", count: 31) + ".mp4",
      hex("a") + ".mov",
      hex("a") + ".mp4\n",
    ]
    for (index, name) in invalidOutputNames.enumerated() {
      try expect(
        !NijiMp4ExportPaths.isValid(
          input,
          path(in: secureURL, name: name),
          cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
        ),
        "不正な出力名 \(index + 1)"
      )
    }

    // 出力は同じ管理ディレクトリ直下かつlstat不存在でなければならない。
    let differentParent = path(in: otherURL, name: hex("c") + ".mp4")
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        differentParent,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "別ディレクトリの出力を拒否"
    )

    let existingOutput = path(in: secureURL, name: hex("d") + ".mp4")
    try writeRegularFile(existingOutput)
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        existingOutput,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "既存通常ファイルの出力を拒否"
    )

    let outputDirectory = path(in: secureURL, name: hex("7") + ".mp4")
    try fileManager.createDirectory(
      atPath: outputDirectory,
      withIntermediateDirectories: false,
      attributes: nil
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        outputDirectory,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "ディレクトリ出力を拒否"
    )

    let linkedOutput = path(in: secureURL, name: hex("9") + ".mp4")
    let linkedOutputTarget = path(in: outsideURL, name: hex("9") + ".mp4")
    try writeRegularFile(linkedOutputTarget)
    try makeSymlink(target: linkedOutputTarget, at: linkedOutput)
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        linkedOutput,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "通常ファイルを指す出力symlinkを拒否"
    )

    let danglingOutput = path(in: secureURL, name: hex("f") + ".mp4")
    try makeSymlink(
      target: path(in: outsideURL, name: "not-created.mp4"),
      at: danglingOutput
    )
    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        danglingOutput,
        cache: URL(fileURLWithPath: cacheAlias, isDirectory: true)
      ),
      "dangling symlink出力を拒否"
    )

    try expect(
      !NijiMp4ExportPaths.isValid(
        input,
        output,
        cache: URL(string: "https://example.invalid/cache")!
      ),
      "file URLでないcacheを拒否"
    )

    // testRoot内の正規ファイルは最後まで残っていることを確認する。
    try expect(fileManager.fileExists(atPath: input), "正規入力を保持")
    try expect(fileManager.fileExists(atPath: canonicalSecure), "管理領域を保持")
  }

  private static func makeTestRoot() throws -> String {
    var template = Array("/private/tmp/nijineko-mp4-export-paths.XXXXXX".utf8)
      .map { Int8(bitPattern: $0) }
    template.append(0)
    guard let root = template.withUnsafeMutableBufferPointer({ buffer -> String? in
      guard let baseAddress = buffer.baseAddress,
            let created = Darwin.mkdtemp(baseAddress) else {
        return nil
      }
      return String(cString: created)
    }) else {
      throw TestFailure(description: "一時試験ディレクトリを作成できません")
    }
    return root
  }

  private static func writeRegularFile(_ path: String) throws {
    guard fileManager.createFile(
      atPath: path,
      contents: Data([0x01]),
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw TestFailure(description: "通常ファイルを作成できません: \(path)")
    }
  }

  private static func makeSymlink(target: String, at path: String) throws {
    guard Darwin.symlink(target, path) == 0 else {
      throw TestFailure(description: "symlinkを作成できません: \(path) errno=\(errno)")
    }
  }

  private static func expect(_ value: Bool, _ label: String) throws {
    guard value else { throw TestFailure(description: label) }
    passed += 1
  }

  private static func path(in directory: URL, name: String) -> String {
    directory.appendingPathComponent(name, isDirectory: false).path
  }

  private static func hex(_ character: String) -> String {
    String(repeating: character, count: 32)
  }

  private static func requireAlias(for path: String) throws -> String {
    guard let alias = osAlias(for: path), alias != path else {
      throw TestFailure(description: "OS別名を作成できません: \(path)")
    }
    return alias
  }

  private static func osAlias(for path: String) -> String? {
    if path.hasPrefix("/private/tmp/") {
      return "/tmp/" + path.dropFirst("/private/tmp/".count)
    }
    if path.hasPrefix("/private/var/") {
      return "/var/" + path.dropFirst("/private/var/".count)
    }
    return nil
  }

  private static func posixRealpath(_ path: String) -> String? {
    guard !path.utf8.contains(0) else { return nil }
    return path.withCString { pointer in
      guard let resolved = Darwin.realpath(pointer, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    }
  }
}
