//
//  main.swift
//  智能教务 · macOS 原生外壳（WKWebView 宿主）
//
//  职责只有五件事：
//    1. 起一个 NSWindow，把 Resources/app.html 装进 WKWebView；
//    2. 暴露 window.webkit.messageHandlers.zhipai 桥，处理网页发来的
//       state / vault / save / print / pdf 五条命令；
//    3. 用 WKUIDelegate 实现 <input type=file> 的系统文件面板；
//    4. 维护「便携数据仓库」：数据落在 App 包内的 userdata/store.json，
//       网页的 localStorage 由注入垫片接管（见 Vault 类）；
//    5. 提供几个命令行自检钩子（--selftest / --pdftest / --vaulttest / --snapshot）。
//
//  产品逻辑（排课、监考、考场编排、XLSX/PDF 版式）全部在 app.html 里，
//  这个文件不承载任何业务规则。
//
//  编译（见同目录 build.sh）：
//    swiftc -swift-version 5 -parse-as-library -O -o zhipai main.swift \
//           -framework AppKit -framework WebKit -framework PDFKit
//

import AppKit
import WebKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - 常量

/// A4 纸面（点）。1 英寸 = 72pt，210mm × 297mm。
let A4_SIZE = NSSize(width: 595.28, height: 841.89)

/// 窗口标题里用的产品名，取自 Info.plist，方便同一份源码出正式版 / 演示版。
let APP_NAME: String = {
    let b = Bundle.main
    return (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "智能教务"
}()

let DEFAULT_WINDOW_SIZE = NSSize(width: 1320, height: 880)
let MIN_WINDOW_SIZE = NSSize(width: 1080, height: 680)

// MARK: - 命令行钩子

struct Options {
    var selftest = false
    var pdftest = false
    var printtest = false
    var vaulttest = false
    var vaultinfo = false
    var snapshotRoute: String?
    var snapshotPath = "/tmp/zhipai-shot.png"

    init(arguments: [String]) {
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--selftest": selftest = true
            case "--pdftest": pdftest = true
            case "--printtest": printtest = true
            case "--vaulttest": vaulttest = true
            case "--vaultinfo": vaultinfo = true
            case "--snapshot":
                if i + 1 < arguments.count { snapshotRoute = arguments[i + 1]; i += 1 }
            case "--shot":
                if i + 1 < arguments.count { snapshotPath = arguments[i + 1]; i += 1 }
            default: break
            }
            i += 1
        }
    }
}

// MARK: - 小工具

func logLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// 离屏渲染的失败原因。做成字符串字面量，调用处可以直接 `.failure("…")`
struct DocError: Error, ExpressibleByStringLiteral, CustomStringConvertible {
    let message: String
    init(stringLiteral value: String) { self.message = value }
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// 把 Swift 字符串变成可安全塞进 JS 源码的字面量
func jsLiteral(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
    guard let data, let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
    // ["..."] -> "..."
    return String(arr.dropFirst().dropLast())
}

/// 按扩展名推 UTType，未知类型退回 .data，保证保存面板不因为类型为空而报错
func contentType(forFileName name: String) -> UTType {
    let ext = (name as NSString).pathExtension.lowercased()
    guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return .data }
    return t
}

/// 内嵌到 JS 源码里的 JSON 需要屏蔽 U+2028 / U+2029：
/// 它们在 JSON 里合法，但在 JS 字符串字面量里会断行
func jsEmbeddedJSON(_ json: String) -> String {
    json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

// MARK: - 便携数据仓库（Vault）
//
// 目标：数据必须跟着 .app 走。把整个 App 拷到另一台 Mac，双击就能看到原来的
// 排课数据，不用拷 ~/Library，也不用做任何配置。
//
// 做法：不再依赖 WebKit 的 localStorage 目录（它在 ~/Library/WebKit/<bundle id>/，
// 拷 App 拷不走），而是在 App 包内维护一份 JSON —— Contents/Resources/userdata/store.json。
//
//   · 网页端的 localStorage 由注入的垫片接管：读走内存快照（同步，语义不变），
//     写回原生桥，原生合并后原子落盘到上面那个文件；
//   · 旧版本留在 WebKit 里的数据，首次启动时由垫片整体搬进仓库，不丢；
//   · 仓库不可写（App 在只读卷 / 被 Gatekeeper 重定位到随机只读路径）时，
//     退到 ~/Library/Application Support/<bundle id>/userdata，下次能从只读位置
//     正常打开时再把数据接回包内。
//
// 落盘位置和代码签名是一对矛盾：Resources 里的文件都在封条（CodeResources）里，
// 一改签名校验就失败，别的机器上会被判「已损坏」。所以每次落盘后延时重签名一次，
// 退出时强制重签名，保证「拷走的那份永远是签名完好的」。
final class Vault {

    static let shared = Vault()

    /// 仓库目录：优先包内，其次 Application Support
    let dir: URL
    let storeURL: URL
    let backupURL: URL
    /// true = 数据确实在 App 包内（拷贝 App 即带走数据）
    let portable: Bool
    /// 不可写时的原因，用于首次启动提示
    let note: String

    private var keys: [String: String] = [:]
    private var firstRun = true
    private var unsaved = false
    private var saveScheduled = false
    private var backedUp = false
    /// 内存里的这份数据是否已经落到过磁盘（首次搬迁 / 从退路目录接回时可能还没落盘）
    private var persisted = false
    private var needsResign = false
    private var resignQueued = false
    private var lastResign = Date.distantPast
    private let io = DispatchQueue(label: "com.zhipai.vault.io", qos: .utility)

    private init() {
        let resolved = Vault.resolveDir()
        dir = resolved.dir
        portable = resolved.portable
        note = resolved.note
        storeURL = dir.appendingPathComponent("store.json")
        backupURL = dir.appendingPathComponent("store.json.bak")
        loadFromDisk()
    }

    // MARK: 路径

    private static func bundleID() -> String {
        Bundle.main.bundleIdentifier ?? "com.zhipai.paike"
    }

    private static func resolveDir() -> (dir: URL, portable: Bool, note: String) {
        let fm = FileManager.default
        let inBundle = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)

        if let reason = writeProbe(inBundle, fm: fm) {
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            let fallback = base
                .appendingPathComponent(bundleID(), isDirectory: true)
                .appendingPathComponent("userdata", isDirectory: true)
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
            return (fallback, false, reason)
        }
        return (inBundle, true, "")
    }

    /// 真写一个探针文件，比 isWritableFile 可靠（只读卷、App 重定位都能测出来）
    private static func writeProbe(_ dir: URL, fm: FileManager) -> String? {
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let probe = dir.appendingPathComponent(".probe-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 只读退路目录（App 曾在磁盘映像 / 下载目录里被直接打开时用过）
    private static func fallbackStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent(bundleID(), isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)
            .appendingPathComponent("store.json")
    }

    // MARK: 读取

    private struct StoreFile: Decodable { let keys: [String: String] }

    static func readKeys(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(StoreFile.self, from: data) else { return nil }
        return file.keys
    }

    private func loadFromDisk() {
        if let loaded = Vault.readKeys(storeURL), !loaded.isEmpty {
            keys = loaded
            firstRun = false
            persisted = true
            makeBackupIfNeeded()
            return
        }
        if let loaded = Vault.readKeys(backupURL), !loaded.isEmpty {
            keys = loaded
            firstRun = false
            persisted = true
            logLine("vault: 主文件损坏，已用 store.json.bak 恢复 \(loaded.count) 项")
            return
        }
        // 包内还是空的，但退路目录里有一份（上次在只读位置运行过）→ 接回来
        if portable, let loaded = Vault.readKeys(Vault.fallbackStoreURL()), !loaded.isEmpty {
            keys = loaded
            logLine("vault: 已从 Application Support 接回 \(loaded.count) 项旧数据")
        }
        firstRun = true
    }

    /// 每次启动留一份「本次会话开始前」的快照，主文件被写坏时可以回滚。
    /// 内容没变就不动它——重写会让签名封条失效，白白多一次重签名。
    private func makeBackupIfNeeded() {
        guard !backedUp else { return }
        backedUp = true
        let fm = FileManager.default
        guard let current = try? Data(contentsOf: storeURL) else { return }
        if let old = try? Data(contentsOf: backupURL), old == current { return }
        try? fm.removeItem(at: backupURL)
        try? fm.copyItem(at: storeURL, to: backupURL)
    }

    // MARK: 注入脚本

    /// 每次载入页面时重建：种子数据 + 垫片
    var bootScript: String {
        let payload: [String: Any] = ["keys": keys, "firstRun": firstRun]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"keys\":{},\"firstRun\":true}"
        return "window.__ZHIPAI_VAULT_SEED__ = \(jsEmbeddedJSON(json));\n" + Vault.shimJS
    }

    // MARK: 写入

    /// 网页把整份 localStorage 交上来（全量覆盖，比增量操作更不容易出错）
    func apply(keys newKeys: [String: String]) {
        let wasFirstRun = firstRun
        firstRun = false
        guard newKeys != keys else { return }
        keys = newKeys
        unsaved = true

        // 首次搬迁立刻落盘：用户可能开一下马上就退，不能靠去抖计时器
        if wasFirstRun {
            unsaved = false
            let snapshot = keys
            io.async {
                if self.write(snapshot) {
                    DispatchQueue.main.async { self.markDirtyForSignature() }
                }
            }
            return
        }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            guard self.unsaved else { return }
            self.unsaved = false
            let snapshot = self.keys
            self.io.async {
                if self.write(snapshot) {
                    DispatchQueue.main.async { self.markDirtyForSignature() }
                }
            }
        }
    }

    @discardableResult
    private func write(_ snapshot: [String: String]) -> Bool {
        let payload: [String: Any] = [
            "format": "zhipai-vault-1",
            "app": APP_NAME,
            "bundleId": Vault.bundleID(),
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "keys": snapshot
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        ) else {
            logLine("vault: 序列化失败")
            return false
        }
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let tmp = dir.appendingPathComponent("store.tmp")
            try data.write(to: tmp, options: .atomic)
            // 同卷 rename 是原子的：要么整份新数据，要么整份旧数据，不会读到半截
            if rename(tmp.path, storeURL.path) != 0 {
                try? fm.removeItem(at: storeURL)
                try fm.moveItem(at: tmp, to: storeURL)
            }
            persisted = true
            return true
        } catch {
            logLine("vault: 落盘失败 \(error.localizedDescription)")
            return false
        }
    }

    /// 退出前调用：把积压的改动同步写完
    func flushSync() {
        let snapshot = keys
        let needWrite = unsaved || (!persisted && !keys.isEmpty)
        unsaved = false
        io.sync {
            if needWrite { self.write(snapshot) }
        }
    }

    // MARK: 签名修复

    private func markDirtyForSignature() {
        needsResign = true
        scheduleResign(after: 20)
    }

    private func scheduleResign(after delay: TimeInterval) {
        guard portable, !resignQueued else { return }
        resignQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, delay)) { [weak self] in
            guard let self else { return }
            self.resignQueued = false
            guard self.needsResign else { return }
            self.repairSignature()
        }
    }

    func repairSignature() {
        guard portable else { return }
        needsResign = false
        lastResign = Date()
        io.async { Vault.signBundle() }
    }

    /// 强制重签名（退出时调用，阻塞到完成）
    func repairSignatureNow() {
        guard portable else { return }
        let valid = Vault.signatureValid()
        logLine("vault: 退出前检查 封条=\(valid ? "完好" : "已失效") 待签=\(needsResign)")
        guard needsResign || !valid else { return }
        needsResign = false
        lastResign = Date()
        _ = io.sync { Vault.signBundle() }
    }

    /// 封条现在是否完好（codesign --verify 约 20ms，可以直接在启动/退出时跑）
    static func signatureValid() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--strict", Bundle.main.bundleURL.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return true }   // 工具不可用就当没问题，别阻断使用
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// codesign --force --sign - 会把封条重写成当前内容，让「拷走的那份」在别的
    /// Mac 上只是一份普通的未公证 App，而不是被判「已损坏」。
    @discardableResult
    static func signBundle() -> Bool {
        let bundle = Bundle.main.bundleURL.path

        func run(_ args: [String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = args
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
        }

        let signed = run(["--force", "--sign", "-", "--timestamp=none", bundle])
        if signed.0 != 0 {
            logLine("vault: 重签名失败 rc=\(signed.0) \(signed.1.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }
        let verified = run(["--verify", "--strict", bundle])
        if verified.0 != 0 {
            logLine("vault: 重签名后校验失败 \(verified.1.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }
        logLine("vault: 已重签名 \(bundle)")
        return true
    }

    // MARK: 网页侧垫片
    //
    // localStorage 是同步 API，原生桥是异步的，所以垫片是「内存为主 + 异步回写」：
    // document start 时把整份快照塞进内存，之后的读写都在内存里同步完成，
    // 变更 250ms 合并一次发给原生。语义与真 localStorage 一致（含 length / key）。
    static let shimJS = """
    (function () {
      if (window.__ZHIPAI_LOCALSTORAGE_SHIM__) return;
      var seed = window.__ZHIPAI_VAULT_SEED__ || { keys: {}, firstRun: false };
      try { delete window.__ZHIPAI_VAULT_SEED__; } catch (e) {}

      var mem = {};
      var has = function (k) { return Object.prototype.hasOwnProperty.call(mem, k); };

      var seedKeys = seed.keys || {};
      for (var sk in seedKeys) {
        if (Object.prototype.hasOwnProperty.call(seedKeys, sk)) mem[sk] = String(seedKeys[sk]);
      }

      var real = null;
      try { real = window.localStorage; } catch (e) { real = null; }

      // 旧版本的数据在 WebKit 的 localStorage 里：首次启动整体搬进仓库
      var migrated = 0;
      if (seed.firstRun && real) {
        try {
          for (var i = 0; i < real.length; i++) {
            var rk = real.key(i);
            if (rk === null || rk === undefined || rk === '__probe__') continue;
            var rv = real.getItem(rk);
            if (rv === null || rv === undefined) continue;
            mem[String(rk)] = String(rv);
            migrated++;
          }
        } catch (e) {}
      }

      var seq = 0, dirty = false, timer = null;
      function post() {
        try {
          var b = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zhipai;
          if (b) b.postMessage({ cmd: 'vault', keys: mem, seq: seq++ });
        } catch (e) {}
      }
      function flushLater(ms) {
        dirty = true;
        if (timer) return;
        timer = setTimeout(function () {
          timer = null;
          if (dirty) { dirty = false; post(); }
        }, ms || 250);
      }
      function flushNow() {
        if (timer) { clearTimeout(timer); timer = null; }
        if (dirty) { dirty = false; post(); }
      }

      var api = {
        getItem: function (k) { k = String(k); return has(k) ? mem[k] : null; },
        setItem: function (k, v) {
          k = String(k); v = String(v);
          mem[k] = v;
          try { if (real) real.setItem(k, v); } catch (e) {}
          flushLater();
        },
        removeItem: function (k) {
          k = String(k);
          if (has(k)) delete mem[k];
          try { if (real) real.removeItem(k); } catch (e) {}
          flushLater();
        },
        clear: function () {
          mem = {};
          try { if (real) real.clear(); } catch (e) {}
          flushLater(0);
        },
        key: function (i) {
          var ks = Object.keys(mem);
          i = i | 0;
          return (i >= 0 && i < ks.length) ? ks[i] : null;
        }
      };
      Object.defineProperty(api, 'length', {
        get: function () { return Object.keys(mem).length; },
        configurable: true
      });

      var installed = false;
      try {
        Object.defineProperty(window, 'localStorage', {
          get: function () { return api; }, configurable: true
        });
        installed = (window.localStorage === api);
      } catch (e) { installed = false; }

      // 退路：全局属性不可改时，改 Storage.prototype（用 this 区分是不是 localStorage）
      if (!installed && window.Storage) {
        try {
          var proto = window.Storage.prototype;
          var oGet = proto.getItem, oSet = proto.setItem, oDel = proto.removeItem,
              oClear = proto.clear, oKey = proto.key;
          var lenDesc = Object.getOwnPropertyDescriptor(proto, 'length');
          proto.getItem = function (k) {
            if (this !== real) return oGet.call(this, k);
            k = String(k); return has(k) ? mem[k] : null;
          };
          proto.setItem = function (k, v) {
            if (this !== real) return oSet.call(this, k, v);
            api.setItem(k, v);
          };
          proto.removeItem = function (k) {
            if (this !== real) return oDel.call(this, k);
            api.removeItem(k);
          };
          proto.clear = function () {
            if (this !== real) return oClear.call(this);
            api.clear();
          };
          proto.key = function (i) {
            if (this !== real) return oKey.call(this, i);
            return api.key(i);
          };
          if (lenDesc && lenDesc.get) {
            Object.defineProperty(proto, 'length', {
              get: function () {
                if (this !== real) return lenDesc.get.call(this);
                return Object.keys(mem).length;
              },
              configurable: true
            });
          }
          installed = true;
        } catch (e2) { installed = false; }
      }

      window.__ZHIPAI_LOCALSTORAGE_SHIM__ = !!installed;
      window.__ZHIPAI_VAULT__ = api;
      window.__zhipaiVaultFlushNow = flushNow;
      window.__zhipaiVaultInfo = function () {
        return { installed: !!installed, keys: Object.keys(mem).length, migrated: migrated, seq: seq };
      };

      if (migrated > 0) { dirty = true; flushNow(); }
    })();
    """
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler,
                         WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {

    let options: Options
    var window: NSWindow!
    var webView: WKWebView!

    /// 同一时刻只允许一份离屏渲染任务（PDF 导出 / 打印共用一个槽位）
    private var docJob: DocPrinter?
    private var booted = false
    private var vaultPhase = 0

    init(options: Options) {
        self.options = options
        super.init()
    }

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadApp()

        // 仓库在包内才可能「拷贝即迁移」；不在包内时提示一次，并说明怎么修
        if !Vault.shared.portable && !options.selftest && !options.vaulttest
            && !options.pdftest && !options.printtest {
            let alert = NSAlert()
            alert.messageText = "数据暂存在 App 之外"
            alert.informativeText = """
            App 当前所在位置不可写（\(Vault.shared.note)），这通常是因为直接在磁盘映像或下载目录里打开它。
            数据已暂存到「应用程序支持」目录，关闭 App 不会丢，但拷贝 App 时不会跟着走。

            把 App 拖到「应用程序」文件夹后重新打开，数据会自动搬进 App 内部。
            """
            alert.addButton(withTitle: "好")
            alert.runModal()
        }

        // 上次退出没来得及重签名（崩溃 / 强制退出 / 直接从别处拷来的旧副本）时补一次
        if Vault.shared.portable, !Vault.signatureValid() {
            logLine("vault: 启动时发现封条失效，自动重签名")
            Vault.shared.repairSignature()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Vault.shared.flushSync()
        Vault.shared.repairSignatureNow()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DEFAULT_WINDOW_SIZE),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = APP_NAME
        window.minSize = MIN_WINDOW_SIZE
        window.delegate = self
        window.setFrameAutosaveName("ZhipaiMainWindow")
        window.center()

        let config = WKWebViewConfiguration()
        // 仍然用默认（持久）数据仓库：它是旧版本的数据来源（首次启动时由垫片搬进
        // 包内仓库），同时作为运行期缓存，换成 nonPersistent 会让升级路径断掉。
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let ucc = WKUserContentController()
        installUserScripts(ucc)
        ucc.add(self, name: "zhipai")
        config.userContentController = ucc

        webView = WKWebView(frame: NSRect(origin: .zero, size: DEFAULT_WINDOW_SIZE), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 注入脚本每次重载都要重建：垫片的种子数据必须是「当前」的仓库内容，
    /// 否则 ⌘R / reload 之后会拿旧快照覆盖新数据。
    private func installUserScripts(_ ucc: WKUserContentController) {
        ucc.removeAllUserScripts()
        // 网页靠这个标记区分「桌面外壳」与「浏览器单文件」，决定是走原生桥还是走下载/打印
        ucc.addUserScript(WKUserScript(
            source: "window.__ZHIPAI_NATIVE__ = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // localStorage 垫片：把网页的持久化接到 App 包内的仓库上
        ucc.addUserScript(WKUserScript(
            source: Vault.shared.bootScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    private func loadApp() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "html") else {
            logLine("找不到 Resources/app.html")
            NSApp.terminate(nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func buildMenu() {
        let main = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 \(APP_NAME)", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: "在访达中显示数据文件", action: #selector(revealVault), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(APP_NAME)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单：WKWebView 里的输入框需要标准 responder 链
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // 显示菜单
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "重新载入", action: #selector(reloadPage), keyEquivalent: "r").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "+").target = self
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: "实际大小", action: #selector(zoomReset), keyEquivalent: "0").target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // 窗口菜单
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        main.addItem(winItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    // MARK: 菜单动作

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = APP_NAME
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let where_ = Vault.shared.portable
            ? "App 内部（Contents/Resources/userdata/store.json）"
            : "应用程序支持目录（App 当前位置不可写）"
        alert.informativeText = """
        版本 \(version)
        单机离线运行的教务排课 / 监考安排 / 考场编排工具。

        数据保存在：\(where_)
        整个 App 拷到别的 Mac 上，数据会一起带过去。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func revealVault() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Vault.shared.storeURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Vault.shared.storeURL])
        } else {
            try? fm.createDirectory(at: Vault.shared.dir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([Vault.shared.dir])
        }
    }

    @objc private func reloadPage() {
        // 先把积压的改动交给原生（否则重载会用旧快照覆盖新数据），再重建种子
        webView.evaluateJavaScript(
            "if (window.__zhipaiVaultFlushNow) window.__zhipaiVaultFlushNow();",
            completionHandler: nil
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.installUserScripts(self.webView.configuration.userContentController)
            self.webView.reload()
        }
    }
    @objc private func zoomIn() { webView.pageZoom = min(2.0, webView.pageZoom + 0.1) }
    @objc private func zoomOut() { webView.pageZoom = max(0.6, webView.pageZoom - 0.1) }
    @objc private func zoomReset() { webView.pageZoom = 1.0 }

    // MARK: 网页 → 原生

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == "zhipai",
              let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }

        switch cmd {
        case "state":   handleState(body)
        case "vault":   handleVault(body)
        case "save":    handleSave(body)
        case "print":   handlePrint(body)
        case "pdf":     handlePdf(body)
        default:        logLine("未知命令：\(cmd)")
        }
    }

    /// 网页把整份 localStorage 交上来（全量覆盖），落到 App 包内的 store.json
    private func handleVault(_ body: [String: Any]) {
        guard let keys = body["keys"] as? [String: String] else {
            logLine("vault: 负载不合法")
            return
        }
        Vault.shared.apply(keys: keys)
    }

    /// 网页每次渲染都会把学期 / 周次同步过来，桌面外壳只用来更新标题栏
    private func handleState(_ body: [String: Any]) {
        let term = body["term"] as? String ?? ""
        let week = body["week"] as? Int ?? 0
        let weeks = body["weeks"] as? Int ?? 0
        guard !term.isEmpty, week > 0 else { window.title = APP_NAME; return }
        window.title = "\(APP_NAME) · \(term) · 第 \(week) 周 / 共 \(weeks) 周"
    }

    /// 保存文件：网页把 Blob 转成 base64 发过来（WKWebView 不处理 <a download>）
    private func handleSave(_ body: [String: Any]) {
        guard let name = body["name"] as? String,
              let b64 = body["b64"] as? String,
              let data = Data(base64Encoded: b64) else {
            logLine("save: 参数不合法")
            return
        }

        // 自动化测试用：网页可设置 window.__ZHIPAI_SAVE_PATH__ 直接落盘，正常使用不会带 path
        if let path = body["path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url)
                logLine("bridge-save-ok \(path) \(data.count)B")
            } catch {
                logLine("bridge-save-fail \(path) \(error.localizedDescription)")
            }
            return
        }

        let panel = NSSavePanel()
        panel.title = "保存文件"
        panel.prompt = "保存"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [contentType(forFileName: name)]

        let write: (URL) -> Void = { url in
            do {
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }

        if let win = window {
            panel.beginSheetModal(for: win) { resp in
                if resp == .OK, let url = panel.url { write(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    /// 打印：先让网页把 #printRoot 的内容连同样式一起交出来，离屏渲染成 A4 PDF，
    /// 再交给系统打印对话框（也能在里面「存储为 PDF」）。
    ///
    /// 为什么不直接打印 WKWebView：实测在这套系统上（macOS 15 / 26 都复现），
    /// WKWebView 的打印通道会把页面当成无限长文档，一张两页的表能吐出几百 MB、
    /// 上千页，进程直接卡死。走 PDF 中继既稳定，也和「导出 PDF」共用同一套分页。
    private func handlePrint(_ body: [String: Any]) {
        guard docJob == nil else { logLine("print: 上一份还在生成，忽略本次请求"); return }
        let landscape = (body["orientation"] as? String) == "landscape"

        webView.evaluateJavaScript(Self.grabPrintDocJS) { [weak self] result, error in
            guard let self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bodyHTML = obj["html"] as? String, !bodyHTML.isEmpty else {
                logLine("print: 取打印内容失败 \(error?.localizedDescription ?? "")")
                return
            }
            if let err = obj["err"] as? String { logLine("print: 取样式出错 \(err)") }
            let css = obj["css"] as? String ?? ""
            let doc = Self.composePrintDocument(css: css, bodyHTML: bodyHTML)
            if self.options.printtest {
                try? doc.write(toFile: "/tmp/zhipai-printdoc.html", atomically: true, encoding: .utf8)
            }

            self.docJob = DocPrinter(html: doc, selector: ".print-page,.tts-page") { res in
                self.docJob = nil
                switch res {
                case .failure(let message):
                    self.presentError("打印失败", message.message)
                case .success(let pdf):
                    if self.options.printtest {
                        self.reportPrintTest(pdf)
                    } else {
                        self.runPrintDialog(pdf, landscape: landscape)
                    }
                }
            }
        }
    }

    /// 打印完成后清空打印容器，并让网页按当前视图重建，保证连续打印可用
    private func cleanupPrintRoot() {
        webView.evaluateJavaScript("""
        try {
          var r = document.getElementById('printRoot');
          if (r) r.innerHTML = '';
          if (window.__zhipaiRefreshPrint) window.__zhipaiRefreshPrint();
        } catch (e) {}
        """, completionHandler: nil)
    }

    private func runPrintDialog(_ data: Data, landscape: Bool) {
        guard let doc = PDFDocument(data: data) else {
            presentError("打印失败", "无法生成打印文件")
            return
        }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = A4_SIZE
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.orientation = landscape ? .landscape : .portrait

        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else {
            presentError("打印失败", "无法创建打印任务")
            return
        }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
        cleanupPrintRoot()
    }

    private func reportPrintTest(_ data: Data) {
        let url = URL(fileURLWithPath: "/tmp/zhipai-printcheck.pdf")
        try? data.write(to: url)
        var text = "printcheck "
        if let doc = PDFDocument(data: data) {
            text += "pages=\(doc.pageCount) bytes=\(data.count) "
            if let p = doc.page(at: 0) {
                let b = p.bounds(for: .mediaBox)
                text += "page1=\(String(format: "%.1f×%.1f", b.width, b.height))pt"
            }
        } else {
            text += "PDF 解析失败"
        }
        try? text.write(toFile: "/tmp/zhipai-printcheck.log", atomically: true, encoding: .utf8)
        logLine(text)
        NSApp.terminate(nil)
    }

    /// 取打印内容：把 @media print 里的规则「提级」成普通规则，
    /// 这样离屏 WebView（按屏幕媒体渲染）也能拿到打印版式。
    static let grabPrintDocJS = """
    (function () {
      try {
      var root = document.getElementById('printRoot');
      if (!root) return JSON.stringify({ html: '', css: '' });
      var css = [];
      for (var i = 0; i < document.styleSheets.length; i++) {
        var rules = null;
        try { rules = document.styleSheets[i].cssRules; } catch (e) { continue; }
        if (!rules) continue;
        for (var j = 0; j < rules.length; j++) {
          var r = rules[j];
          if (r.type === 4) {
            var m = (r.media && r.media.mediaText) ? r.media.mediaText : '';
            if (m.indexOf('print') >= 0) {
              css.push(String(r.cssText).replace(/^@media[^{]*\\{/, '').replace(/\\}\\s*$/, ''));
            }
            continue;
          }
          css.push(r.cssText);
        }
      }
      return JSON.stringify({ html: root.innerHTML, css: css.join('\\n') });
      } catch (e) {
        return JSON.stringify({ html: '', css: '', err: String((e && e.message) || e) });
      }
    })()
    """

    static func composePrintDocument(css: String, bodyHTML: String) -> String {
        """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>打印</title>
        <style>\(css)</style>
        <style>
          html, body { margin: 0 !important; padding: 0 !important; background: #fff; }
          #printRoot { display: block !important; padding: 10mm !important; box-sizing: border-box; }
          .app { display: none !important; }
        </style></head>
        <body><div id="printRoot">\(bodyHTML)</div></body></html>
        """
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// PDF：网页把一份完整的独立 HTML（含 @page 规则、自带 A4 分页）发过来，
    /// 离屏逐页转成 PDF 后交给保存面板
    private func handlePdf(_ body: [String: Any]) {
        guard let name = body["name"] as? String, let html = body["html"] as? String else {
            logLine("pdf: 参数不合法")
            return
        }
        guard docJob == nil else { logLine("pdf: 上一份还在生成，忽略本次请求"); return }

        let direct: URL? = options.pdftest ? URL(fileURLWithPath: "/tmp/zhipai-pdf-test.pdf") : nil
        docJob = DocPrinter(html: html, selector: ".er-page") { [weak self] res in
            guard let self else { return }
            self.docJob = nil
            var result: String
            switch res {
            case .success(let data):
                result = self.storePDF(data, name: name, direct: direct)
            case .failure(let message):
                result = message.message
            }
            self.webView.evaluateJavaScript(
                "if (window.__zhipaiPdfDone) window.__zhipaiPdfDone(\(jsLiteral(result)));",
                completionHandler: nil
            )
            if self.options.pdftest { self.reportPdfTest(result) }
        }
    }

    /// 把生成的 PDF 落盘：测试直写 / 正常走保存面板。返回给网页的结果串。
    private func storePDF(_ data: Data, name: String, direct: URL?) -> String {
        if let direct {
            do {
                try data.write(to: direct)
                return "ok"
            } catch {
                return "写入失败：\(error.localizedDescription)"
            }
        }
        let panel = NSSavePanel()
        panel.title = "保存 PDF"
        panel.prompt = "保存"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.pdf]
        if let win = window {
            panel.beginSheetModal(for: win) { resp in
                if resp == .OK, let url = panel.url {
                    try? data.write(to: url)
                }
            }
            return "ok"
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                return "ok"
            } catch {
                return "写入失败：\(error.localizedDescription)"
            }
        }
        return "cancel"
    }

    // MARK: 文件选择面板（<input type=file>）

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let win = window {
            panel.beginSheetModal(for: win) { resp in
                completionHandler(resp == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    // MARK: 载入完成后的自检钩子

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // --vaulttest 要走两趟（重载前 / 重载后），所以单独一条通路
        if options.vaulttest {
            vaultPhase += 1
            if vaultPhase == 1 { vaultTestFirstPass() }
            else if vaultPhase == 2 { vaultTestAfterReload() }
            return
        }
        guard !booted else { return }
        booted = true
        if options.vaultinfo { reportVaultInfo() }
        else if options.selftest { runSelftest() }
        else if options.pdftest { runPdfTest() }
        else if options.printtest { runPrintTest() }
        else if let route = options.snapshotRoute { runSnapshot(route) }
    }

    // MARK: 数据仓库自检

    private var vaultSummary: String {
        """
        vault=\(Vault.shared.storeURL.path)
        portable=\(Vault.shared.portable ? "yes" : "no")
        note=\(Vault.shared.note)
        """
    }

    /// 页面上取一份存储视图：垫片是否装上、有哪些键、主状态多长、课表条数、测试标记
    static let vaultProbeJS = """
    (function () {
      var out = {};
      try { out.shim = window.__ZHIPAI_LOCALSTORAGE_SHIM__ ? 'yes' : 'no'; } catch (e) { out.shim = 'err'; }
      try {
        var a = [];
        for (var i = 0; i < localStorage.length; i++) a.push(localStorage.key(i));
        out.keys = a.sort().join(',');
      } catch (e) { out.keys = 'ERR:' + e.message; }
      try { out.stateLen = (localStorage.getItem(DB.KEY) || '').length; } catch (e) { out.stateLen = -1; }
      try { out.lessons = DB.S.lessons.length; } catch (e) { out.lessons = -1; }
      try { out.marker = localStorage.getItem('__vaulttest_marker__') || ''; } catch (e) { out.marker = 'ERR'; }
      return JSON.stringify(out);
    })()
    """

    private func reportVaultInfo() {
        let lines = [vaultSummary,
                     "keys=\(Vault.readKeys(Vault.shared.storeURL)?.count ?? -1)"]
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: "/tmp/zhipai-vault.log", atomically: true, encoding: .utf8)
        logLine(text)
        NSApp.terminate(nil)
    }

    /// 第一趟：确认垫片生效、旧数据已搬迁，写一个标记并强制落盘，然后重载页面
    private func vaultTestFirstPass() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.webView.evaluateJavaScript(Self.vaultProbeJS) { result, error in
                let phase1 = String(describing: result ?? error?.localizedDescription ?? "nil")
                logLine("vaulttest 第一趟：\(phase1)")

                let stamp = "marker-\(Int(Date().timeIntervalSince1970))"
                self.webView.evaluateJavaScript("""
                (function () {
                  try {
                    localStorage.setItem('__vaulttest_marker__', '\(stamp)');
                    if (window.__zhipaiVaultFlushNow) window.__zhipaiVaultFlushNow();
                    return 'ok';
                  } catch (e) { return 'ERR:' + e.message; }
                })()
                """) { _, _ in
                    // 等落盘（0.45s 去抖 + IO），再用原生视角确认文件里确实有这份数据
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        let onDisk = Vault.readKeys(Vault.shared.storeURL) ?? [:]
                        let hasMarker = onDisk["__vaulttest_marker__"] == stamp
                        let hasState = (onDisk["zhipai.state.v3"]?.count ?? onDisk["zhipai.demo.state.v3"]?.count ?? 0) > 0
                        let text = """
                        \(self.vaultSummary)
                        phase1=\(phase1)
                        diskKeys=\(onDisk.count)
                        diskMarker=\(hasMarker ? "ok" : "fail")
                        diskState=\(hasState ? "ok" : "fail")
                        """
                        logLine(text)
                        try? text.write(toFile: "/tmp/zhipai-vaulttest-1.log", atomically: true, encoding: .utf8)

                        // 重载：种子必须是新的（这一步过不了就会丢数据）
                        self.installUserScripts(self.webView.configuration.userContentController)
                        self.webView.reload()
                    }
                }
            }
        }
    }

    /// 第二趟：重载后应当仍然读得到同一份数据
    private func vaultTestAfterReload() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.webView.evaluateJavaScript(Self.vaultProbeJS) { result, error in
                let phase2 = String(describing: result ?? error?.localizedDescription ?? "nil")
                let text = """
                \(self.vaultSummary)
                phase2=\(phase2)
                """
                logLine(text)
                try? text.write(toFile: "/tmp/zhipai-vaulttest-2.log", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logLine("载入失败：\(error.localizedDescription)")
    }

    /// --selftest：确认桥接、原生标记、localStorage、导航与首屏渲染是否正常
    private func runSelftest() {
        let js = """
        (function () {
          var out = {};
          out.bridge = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zhipai) ? 'yes' : 'no';
          out.native = (window.__ZHIPAI_NATIVE__ === true) ? 'yes' : 'no';
          out.documentTitle = document.title;
          out.navItems = document.querySelectorAll('.nav-item').length;
          try { out.dbKeys = Object.keys(DB.S || {}).length; } catch (e) { out.dbKeys = -1; }
          try { out.lessons = (DB.S.lessons || []).length; } catch (e) { out.lessons = -1; }
          try {
            var ks = [];
            for (var i = 0; i < localStorage.length; i++) ks.push(localStorage.key(i));
            out.storageKeys = ks.join(',');
          } catch (e) { out.storageKeys = 'blocked'; }
          out.viewHTML = (document.getElementById('view') || {}).innerHTML ? 'ok' : 'empty';
          return JSON.stringify(out);
        })()
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.webView.evaluateJavaScript(js) { result, error in
                var lines: [String] = []
                lines.append("selftest @" + ISO8601DateFormatter().string(from: Date()))
                if let error { lines.append("JS 错误：\(error.localizedDescription)") }
                lines.append(String(describing: result ?? "nil"))

                // 顺带验一次保存桥：网页发 base64 + path，原生直写磁盘
                let probe = URL(fileURLWithPath: "/tmp/zhipai-save-test.bin")
                try? FileManager.default.removeItem(at: probe)
                self.webView.evaluateJavaScript(
                    "window.webkit.messageHandlers.zhipai.postMessage({ cmd: 'save', name: 't.bin', b64: 'aGVsbG8=', path: '/tmp/zhipai-save-test.bin' }); 'sent'",
                    completionHandler: nil
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let ok = (try? Data(contentsOf: probe)).map { String(data: $0, encoding: .utf8) == "hello" } ?? false
                    lines.append("saveBridge=\(ok ? "ok" : "fail")")
                    let text = lines.joined(separator: "\n")
                    try? text.write(toFile: "/tmp/zhipai-selftest.log", atomically: true, encoding: .utf8)
                    logLine(text)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// --pdftest：走一遍考场编排 → 导出 PDF → 直接落到 /tmp/zhipai-pdf-test.pdf
    private func runPdfTest() {
        let js = """
        (function () {
          try {
            if (typeof go !== 'function' || typeof seatExportPdf !== 'function') return 'ERR:接口缺失';
            var P = seatData();
            if (!P.students || !P.students.length) return 'ERR:没有花名册';
            var hasPlan = P.plan && Object.keys(P.plan).length > 0;
            if (!hasPlan) seatArrangeAll(P.seed || 20260101);
            go('seating');
            setTimeout(function () { seatExportPdf(); }, 400);
            return 'ok';
          } catch (e) { return 'ERR:' + e.message; }
        })()
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.webView.evaluateJavaScript(js) { result, error in
                let r = (result as? String) ?? "ERR:\(error?.localizedDescription ?? "unknown")"
                logLine("pdftest 触发：\(r)")
                if r != "ok" { NSApp.terminate(nil) }
            }
            // PDF 面板不会弹出（directURL 生效），超时兜底避免脚本挂住
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                logLine("pdftest 超时")
                NSApp.terminate(nil)
            }
        }
    }

    /// --printtest：走一遍网页 → 原生打印 → PDF 的完整链路，结果落在 /tmp/zhipai-printcheck.pdf
    private func runPrintTest() {
        let js = """
        (function () {
          try {
            var rows = '';
            for (var i = 1; i <= 60; i++) {
              rows += '<tr><td style="border:1px solid #000;padding:4px">' + i +
                      '</td><td style="border:1px solid #000;padding:4px">打印自检第 ' + i + ' 行</td></tr>';
            }
            Export.print('打印自检', '共 60 行', '<table class="tt" style="width:100%;border-collapse:collapse">' +
              '<tbody>' + rows + '</tbody></table>');
            return 'ok';
          } catch (e) { return 'ERR:' + e.message; }
        })()
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.webView.evaluateJavaScript(js) { result, error in
                logLine("printtest 触发：\((result as? String) ?? error?.localizedDescription ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                logLine("printtest 超时")
                NSApp.terminate(nil)
            }
        }
    }

    private func reportPdfTest(_ result: String) {        var text = "pdftest result=\(result)\n"
        if let doc = PDFDocument(url: URL(fileURLWithPath: "/tmp/zhipai-pdf-test.pdf")) {
            text += "pages=\(doc.pageCount)\n"
            if let p = doc.page(at: 0) {
                let b = p.bounds(for: .mediaBox)
                text += "page1=\(String(format: "%.1f×%.1f", b.width, b.height))pt\n"
            }
        } else {
            text += "pages=0（文件未生成）\n"
        }
        try? text.write(toFile: "/tmp/zhipai-pdf.log", atomically: true, encoding: .utf8)
        logLine(text)
        NSApp.terminate(nil)
    }

    /// --snapshot <route>：切到指定视图截一张 PNG，用于 README 配图
    private func runSnapshot(_ route: String) {
        let js = "try { go(\(jsLiteral(route))); 'ok' } catch (e) { 'ERR:' + e.message }"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let cfg = WKSnapshotConfiguration()
                    cfg.snapshotWidth = NSNumber(value: Double(DEFAULT_WINDOW_SIZE.width))
                    self.webView.takeSnapshot(with: cfg) { image, error in
                        if let image, let tiff = image.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: self.options.snapshotPath))
                            logLine("snapshot ok \(self.options.snapshotPath)")
                        } else {
                            logLine("snapshot error: \(error?.localizedDescription ?? "unknown")")
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

// MARK: - 离屏渲染：HTML → 逐页 A4 PDF

/// 把一整份 HTML 渲染成多页 A4 PDF。
///
/// 两种用途共用它：
///   · 导出 PDF —— 网页给的是自带 `.er-page` 分页的独立文档；
///   · 打印     —— 网页给的是 `#printRoot` 里的内容，按 `.print-page` 切页。
///
/// 分页方式：先量出每个「页块」元素的位置和高度，再按 A4 的像素高度切片，
/// 每片一次 `createPDF`，最后用 PDFKit 合并。切片高度取 A4 而不是页块高度，
/// 这样页块之间的空隙不会把后面的内容顶到下一页。
final class DocPrinter: NSObject, WKNavigationDelegate {

    /// 一页纸在 WebKit 里的逻辑尺寸。网页的 PDF 样式把 A4 缩到 0.75，
    /// 于是 210mm × 297mm 正好落成 595.28 × 841.89 个逻辑像素，
    /// 与 A4 的点数一一对应，切出来的每一片就是一张标准 A4。
    static let PAGE_WIDTH: CGFloat = 595.28
    static let PAGE_HEIGHT: CGFloat = 841.89

    private let web: WKWebView
    private let holder: NSWindow
    private let selector: String
    private let completion: (Result<Data, DocError>) -> Void

    private var loaded = false
    private var pages: [PDFPage] = []
    private var slices: [(top: CGFloat, height: CGFloat)] = []   // 每页在原文档里的位置
    private var cursor = 0

    init(html: String, selector: String, completion: @escaping (Result<Data, DocError>) -> Void) {
        self.selector = selector
        self.completion = completion

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: DocPrinter.PAGE_WIDTH, height: DocPrinter.PAGE_HEIGHT)
        self.web = WKWebView(frame: frame, configuration: config)
        self.holder = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: frame.width, height: frame.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        web.navigationDelegate = self
        holder.contentView = web
        holder.isReleasedWhenClosed = false
        // 必须放进窗口并「显示」在屏幕外，否则 WebKit 可能不排版；orderBack 不抢焦点
        holder.orderBack(nil)
        web.loadHTMLString(html, baseURL: nil)
    }

    // MARK: 载入 → 量页 → 逐页出图

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        // 等字体与表格完成一次排版再量，否则页高会被算小
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.measurePages() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(DocError("渲染失败：\(error.localizedDescription)")))
    }

    private func measurePages() {
        let js = """
        (function () {
          var round = function (v) { return Math.round(v * 100) / 100; };
          var nodes = document.querySelectorAll(\(jsLiteral(selector)));
          var blocks = [];
          var bottom = 0;
          for (var i = 0; i < nodes.length; i++) {
            var r = nodes[i].getBoundingClientRect();
            var top = round(r.top + window.scrollY);
            // 表格行位置：长表格要按行换页，不能把一行劈成两半
            var rows = [];
            var trs = nodes[i].querySelectorAll('tr');
            for (var k = 0; k < trs.length; k++) {
              var tr = trs[k].getBoundingClientRect();
              rows.push([round(tr.top + window.scrollY), round(tr.bottom + window.scrollY)]);
            }
            blocks.push({ top: top, height: round(r.height), rows: rows });
            bottom = Math.max(bottom, top + r.height);
          }
          return JSON.stringify({ blocks: blocks, bottom: bottom || document.body.scrollHeight });
        })()
        """
        web.evaluateJavaScript(js) { result, error in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.finish(.failure(DocError("测量页面失败：\(error?.localizedDescription ?? "无法解析")")))
                return
            }
            let rawBlocks = (obj["blocks"] as? [[String: Any]]) ?? []
            let bottom = (obj["bottom"] as? Double) ?? 0
            self.slices = DocPrinter.paginate(rawBlocks: rawBlocks, bottom: CGFloat(bottom))

            // 把离屏视图撑到整份文档高度，保证每页都在自己的排版位置上
            if bottom > 0 {
                let size = NSSize(width: DocPrinter.PAGE_WIDTH, height: CGFloat(bottom) + 2)
                self.web.frame = NSRect(origin: .zero, size: size)
                self.holder.setContentSize(size)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.renderNextPage() }
        }
    }

    /// 把「页块 + 表行位置」编排成每一页的切割位置。
    ///
    /// 规则：页块本身不超过一页就整页切一刀；超过一页的（长表格）按行切，
    /// 每页尽量多装行但不劈行，切口就落在下一行的顶边——
    /// 这样每页的高度可能略小于 A4，合成时留白，而不是把半行裁掉。
    static func paginate(rawBlocks: [[String: Any]], bottom: CGFloat) -> [(top: CGFloat, height: CGFloat)] {
        let pageH = PAGE_HEIGHT
        var slices: [(CGFloat, CGFloat)] = []

        func hardSlice(_ top: CGFloat, _ height: CGFloat) {
            guard height.isFinite, height > 0 else { return }
            let n = max(1, Int(ceil(height / pageH - 0.02)))
            for k in 0..<n {
                let y = top + CGFloat(k) * pageH
                slices.append((y, min(pageH, top + height - y)))
            }
        }

        if rawBlocks.isEmpty {
            hardSlice(0, bottom)
            return slices
        }

        for raw in rawBlocks {
            let top = CGFloat((raw["top"] as? Double) ?? 0)
            let height = CGFloat((raw["height"] as? Double) ?? 0)
            let rows: [(CGFloat, CGFloat)] = ((raw["rows"] as? [[Double]]) ?? []).compactMap {
                guard $0.count >= 2 else { return nil }
                return (CGFloat($0[0]), CGFloat($0[1]))
            }

            if height <= pageH + 1 || rows.count < 2 {
                hardSlice(top, height)
                continue
            }

            var index = 0
            var pageTop = top
            var guardCount = 0
            while index < rows.count && guardCount < 5000 {
                guardCount += 1
                let limit = pageTop + pageH
                var next = index
                while next < rows.count && rows[next].1 <= limit + 0.5 { next += 1 }

                if next == index {
                    // 这一段第一行就超过一页：只能硬切
                    slices.append((pageTop, pageH))
                    pageTop += pageH
                    while index < rows.count && rows[index].0 < pageTop { index += 1 }
                    continue
                }

                if next >= rows.count {
                    // 剩下的行都在这一页里了
                    slices.append((pageTop, min(pageH, top + height - pageTop)))
                    break
                }
                let cut = rows[next].0
                slices.append((pageTop, min(pageH, cut - pageTop)))
                pageTop = cut
                index = next
            }
        }
        return slices
    }

    private func renderNextPage() {
        if cursor >= slices.count {
            assemble()
            return
        }
        let slice = slices[cursor]
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: slice.top, width: DocPrinter.PAGE_WIDTH, height: slice.height)

        web.createPDF(configuration: config) { result in
            switch result {
            case .success(let data):
                if let src = PDFDocument(data: data), let page = src.page(at: 0) {
                    self.pages.append(page)
                }
            case .failure(let error):
                logLine("第 \(self.cursor + 1) 页生成失败：\(error.localizedDescription)")
            }
            self.cursor += 1
            DispatchQueue.main.async { self.renderNextPage() }
        }
    }

    /// 把抓下来的页面依次贴到 A4 画布上（顶部对齐），高度不足的部分留白
    private func assemble() {
        guard !pages.isEmpty else {
            finish(.failure("PDF 生成失败"))
            return
        }
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: DocPrinter.PAGE_WIDTH, height: DocPrinter.PAGE_HEIGHT)
        guard let consumer = CGDataConsumer(data: output),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            finish(.failure("PDF 合成失败"))
            return
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            if let pageRef = page.pageRef {
                let b = page.bounds(for: .mediaBox)
                ctx.saveGState()
                // CG 原点在左下，顶部对齐就是把整页往下挪剩下那段
                ctx.translateBy(x: 0, y: box.height - b.height)
                ctx.drawPDFPage(pageRef)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        pages.removeAll()
        finish(.success(output as Data))
    }

    private func finish(_ result: Result<Data, DocError>) {
        holder.orderOut(nil)
        holder.contentView = nil
        completion(result)
    }
}

// MARK: - 入口

let appDelegate = AppDelegate(options: Options(arguments: CommandLine.arguments))

let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
