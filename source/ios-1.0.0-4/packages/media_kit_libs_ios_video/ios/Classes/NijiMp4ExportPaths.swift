import Darwin
import Foundation

/// Dartが検査・コピーした正規パスだけを専用変換APIへ通す。
enum NijiMp4ExportPaths {
  static func isValid(_ input: String, _ output: String, cache: URL) -> Bool {
    guard input.hasPrefix("/"), output.hasPrefix("/"),
      !input.utf8.contains(0), !output.utf8.contains(0),
      cache.isFileURL, let cachePath = canonicalPath(cache.path),
      canonicalPath(input) == input else { return false }

    let directory = cachePath + "/nijineko-secure-video"
    let sourceName = URL(fileURLWithPath: input).lastPathComponent
    let targetName = URL(fileURLWithPath: output).lastPathComponent
    guard input == directory + "/" + sourceName,
      output == directory + "/" + targetName,
      canonicalPath(directory) == directory,
      sourceName.range(of: "\\A[0-9a-f]{32}\\.(webm|mov|mp4)\\z", options: .regularExpression) != nil,
      targetName.range(of: "\\A[0-9a-f]{32}\\.mp4\\z", options: .regularExpression) != nil else { return false }

    var info = stat()
    guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      lstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
    // fileExistsはリンク先がないsymlinkも「不存在」にするため使用しない。
    return lstat(output, &info) == -1 && errno == ENOENT
  }

  private static func canonicalPath(_ path: String) -> String? {
    // FoundationのresolvingSymlinksInPathは/privateを省略することがある。
    // DartのresolveSymbolicLinksと同じPOSIX realpathで比較し、
    // OSのCaches別名だけを解決する。入力側の任意symlinkは許可しない。
    guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
