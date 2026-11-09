import Flutter
import UIKit
import UniformTypeIdentifiers

/// "vibeline/phone": the iCloud Drive folder the Mac sends sets to, and
/// copying a set from it onto the phone.
///
/// The folder is chosen once with the Files picker (the app isn't given
/// iCloud Drive otherwise) and remembered as a bookmark. Reading through a
/// file coordinator makes iCloud download a file that's still only in the
/// cloud before handing it over.
final class PhoneFiles: NSObject, UIDocumentPickerDelegate {
  static let shared = PhoneFiles()

  private var channel: FlutterMethodChannel?
  private var pickResult: FlutterResult?
  private let queue = DispatchQueue(label: "vibeline.phonefiles", qos: .userInitiated)
  private let bookmarkKey = "setsFolderBookmark"

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "vibeline/phone", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    self.channel = channel
  }

  private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "documents":
      result(documents.path)
    case "folderName":
      result(folder()?.lastPathComponent)
    case "pickFolder":
      pick(result)
    case "listSets":
      queue.async {
        let sets = self.listSets()
        DispatchQueue.main.async { result(sets) }
      }
    case "download":
      guard let name = args["name"] as? String, let files = args["files"] as? [String] else {
        result(FlutterError(code: "args", message: "name and files are required", details: nil))
        return
      }
      queue.async {
        do {
          let path = try self.download(name, files: files)
          DispatchQueue.main.async { result(path) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "download", message: error.localizedDescription, details: nil)) }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: The folder

  private func pick(_ result: @escaping FlutterResult) {
    guard let top = Self.topController() else {
      result(FlutterError(code: "ui", message: "no window", details: nil))
      return
    }
    pickResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return finishPick(nil) }
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(data, forKey: bookmarkKey)
    }
    finishPick(url.lastPathComponent)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishPick(nil) }

  private func finishPick(_ name: String?) {
    pickResult?(name)
    pickResult = nil
  }

  private func folder() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
      return nil
    }
    if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(fresh, forKey: bookmarkKey)
    }
    return url
  }

  /// The sets in the folder: [{name, json}], json nil while its description
  /// hasn't arrived from iCloud yet. The chosen folder can be D-Jay Noodles
  /// itself or its Sets folder.
  private func listSets() -> [[String: Any]] {
    guard let root = folder() else { return [] }
    let ok = root.startAccessingSecurityScopedResource()
    defer { if ok { root.stopAccessingSecurityScopedResource() } }
    let sets = root.appendingPathComponent("Sets")
    let dir = (try? sets.checkResourceIsReachable()) == true ? sets : root
    let fm = FileManager.default
    let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
    var out: [[String: Any]] = []
    for u in entries where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
      if u.lastPathComponent.hasPrefix(".") { continue }
      let json = u.appendingPathComponent("set.json")
      let placeholder = u.appendingPathComponent(".set.json.icloud")
      guard fm.fileExists(atPath: json.path) || fm.fileExists(atPath: placeholder.path) else { continue }
      var text: String?
      var err: NSError?
      NSFileCoordinator().coordinate(readingItemAt: json, options: [], error: &err) { url in
        text = try? String(contentsOf: url, encoding: .utf8)
      }
      out.append(["name": u.lastPathComponent, "json": text as Any])
    }
    return out
  }

  /// Copies a set's files onto the phone (iCloud downloads them first if
  /// needed), into Documents/Sets/<name>. Returns that folder.
  private func download(_ name: String, files: [String]) throws -> String {
    guard let root = folder() else { throw NSError(domain: "phone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose the D-Jay Noodles folder first"]) }
    let ok = root.startAccessingSecurityScopedResource()
    defer { if ok { root.stopAccessingSecurityScopedResource() } }
    let sets = root.appendingPathComponent("Sets")
    let src = ((try? sets.checkResourceIsReachable()) == true ? sets : root).appendingPathComponent(name)
    let fm = FileManager.default
    let dest = documents.appendingPathComponent("Sets").appendingPathComponent(name)
    let partial = documents.appendingPathComponent("Sets").appendingPathComponent(name + ".part")
    try? fm.removeItem(at: partial)
    try fm.createDirectory(at: partial, withIntermediateDirectories: true)
    let all = files + ["set.json"]
    for (k, f) in all.enumerated() {
      let from = src.appendingPathComponent(f)
      try? fm.startDownloadingUbiquitousItem(at: from)
      var err: NSError?
      var copyError: Error?
      NSFileCoordinator().coordinate(readingItemAt: from, options: [], error: &err) { url in
        do { try fm.copyItem(at: url, to: partial.appendingPathComponent(f)) } catch { copyError = error }
      }
      if let e = err ?? (copyError as NSError?) { throw e }
      DispatchQueue.main.async { self.channel?.invokeMethod("progress", arguments: Double(k + 1) / Double(all.count)) }
    }
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: partial, to: dest)
    return dest.path
  }

  static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var top = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
      ?? scenes.first?.windows.first?.rootViewController
    while let p = top?.presentedViewController { top = p }
    return top
  }
}
