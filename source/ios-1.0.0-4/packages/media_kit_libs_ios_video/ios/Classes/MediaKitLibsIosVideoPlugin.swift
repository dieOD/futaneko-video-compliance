import Flutter
import UIKit

public final class MediaKitLibsIosVideoPlugin: NSObject, FlutterPlugin {
  private var job: UnsafeMutableRawPointer?
  private var operation: String?
  private let queue = DispatchQueue(label: "com.dieod.nijineko.mp4-export", qos: .utility)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MediaKitLibsIosVideoPlugin()
    let channel = FlutterMethodChannel(name: "com.dieod.nijineko/mp4-export", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: String] ?? [:]
    switch call.method {
    case "progress":
      result(args["id"] == operation ? nijineko_video_export_progress(job) : 0)
    case "cancel":
      if args["id"] == operation { nijineko_video_export_cancel(job) }
      result(nil)
    case "convert":
      guard job == nil else {
        result(FlutterError(code: "busy", message: "別の動画を変換中です", details: nil)); return
      }
      guard let id = args["id"], let input = args["input"], let output = args["output"],
        validPaths(input, output), let current = nijineko_video_export_create() else {
        result(FlutterError(code: "input", message: "検査済みのローカル動画ではありません", details: nil)); return
      }
      job = current; operation = id
      queue.async {
        let status = input.withCString { source in
          output.withCString { destination in nijineko_video_export_mp4(current, source, destination) }
        }
        DispatchQueue.main.async {
          self.job = nil; self.operation = nil
          nijineko_video_export_destroy(current)
          result(Int(status))
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func validPaths(_ input: String, _ output: String) -> Bool {
    guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
    return NijiMp4ExportPaths.isValid(input, output, cache: cache)
  }
}
