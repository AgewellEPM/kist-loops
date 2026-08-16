import Foundation

/// One step the browser performs. The agent supplies these as data; they are NEVER interpolated into
/// the driver's JavaScript — they ride as a JSON spec the constant driver parses, so there's no script
/// injection surface even though selectors/values are agent-controlled.
public enum BrowserAction: Sendable, Equatable {
    case click(selector: String)
    case fill(selector: String, value: String)
    case waitFor(selector: String)
    case press(key: String)
    case screenshot(path: String)

    /// Parse a `{do, selector?, value?, key?, path?}` dict. Returns nil for an unknown/invalid shape.
    public static func parse(_ dict: [String: Any]) -> BrowserAction? {
        guard let verb = (dict["do"] as? String)?.lowercased() else { return nil }
        let selector = dict["selector"] as? String
        switch verb {
        case "click":      return selector.map { .click(selector: $0) }
        case "fill":       if let s = selector, let v = dict["value"] as? String { return .fill(selector: s, value: v) }; return nil
        case "wait", "waitfor": return selector.map { .waitFor(selector: $0) }
        case "press":      return (dict["key"] as? String).map { .press(key: $0) }
        case "screenshot": return (dict["path"] as? String).map { .screenshot(path: $0) }
        default:           return nil
        }
    }

    /// The JSON object form fed to the driver (data, not code).
    public var json: [String: Any] {
        switch self {
        case .click(let s):           return ["do": "click", "selector": s]
        case .fill(let s, let v):     return ["do": "fill", "selector": s, "value": v]
        case .waitFor(let s):         return ["do": "wait", "selector": s]
        case .press(let k):           return ["do": "press", "key": k]
        case .screenshot(let p):      return ["do": "screenshot", "path": p]
        }
    }

    /// Resolve any filesystem-bearing action through the project root before it reaches
    /// the browser process. Selectors/values remain data; screenshot paths become
    /// absolute, root-confined paths or the tool refuses the request.
    public func confined(to context: ToolContext) throws -> BrowserAction {
        switch self {
        case .screenshot(let path):
            return .screenshot(path: try context.resolvedPath(path, mustExist: false))
        default:
            return self
        }
    }
}

/// Builds the JSON spec the headless driver consumes. Pure + validated so the data contract is tested
/// without a browser.
public enum BrowserSpec {
    public static func build(url: String, actions: [BrowserAction], extract: String,
                             configuredAllowedHosts: [String] = [],
                             perCallAllowedHosts: [String] = [],
                             allowLocalhost: Bool = false,
                             proxyServer: String = "",
                             proxyUsername: String = "",
                             proxyPassword: String = "",
                             localCaptureScheme: String? = nil,
                             localCaptureHost: String? = nil,
                             localCapturePort: String? = nil) -> [String: Any] {
        ["url": url,
         "actions": actions.map { $0.json },
         "extract": (extract == "html" ? "html" : "text"),
         "configuredAllowedHosts": configuredAllowedHosts,
         "perCallAllowedHosts": perCallAllowedHosts,
         "allowLocalhost": allowLocalhost,
         "proxyServer": proxyServer,
         "proxyUsername": proxyUsername,
         "proxyPassword": proxyPassword,
         "localCaptureScheme": localCaptureScheme ?? "",
         "localCaptureHost": localCaptureHost ?? "",
         "localCapturePort": localCapturePort ?? "",
         "timeoutMs": 30000]
    }

    public static func jsonString(url: String, actions: [BrowserAction], extract: String,
                                  configuredAllowedHosts: [String] = [],
                                  perCallAllowedHosts: [String] = [],
                                  allowLocalhost: Bool = false,
                                  proxyServer: String = "",
                                  proxyUsername: String = "",
                                  proxyPassword: String = "",
                                  localCaptureScheme: String? = nil,
                                  localCaptureHost: String? = nil,
                                  localCapturePort: String? = nil) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: build(url: url, actions: actions, extract: extract,
                                                                           configuredAllowedHosts: configuredAllowedHosts,
                                                                           perCallAllowedHosts: perCallAllowedHosts,
                                                                           allowLocalhost: allowLocalhost,
                                                                           proxyServer: proxyServer,
                                                                           proxyUsername: proxyUsername,
                                                                           proxyPassword: proxyPassword,
                                                                           localCaptureScheme: localCaptureScheme,
                                                                           localCaptureHost: localCaptureHost,
                                                                           localCapturePort: localCapturePort)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The CONSTANT Playwright driver. No interpolation — it reads the spec from private stdin as JSON and
    /// executes it. Agent input never becomes code.
    public static let driverJS = #"""
    // argv[2] is an absolute path to the playwright module (so a globally-installed playwright resolves
    // from this temp-dir driver); falls back to bare 'playwright' for a local install / NODE_PATH.
    const fs = require('fs');
    const net = require('net');
    const { chromium } = require(process.argv[2] || 'playwright');

    function normalizeHost(raw) {
      return String(raw || '').trim().replace(/\.+$/, '').toLowerCase();
    }
    function isAllowedLocalhostHost(host) {
      const h = normalizeHost(host).replace(/^\[/, '').replace(/\]$/, '');
      if (h === 'localhost') return true;
      const family = net.isIP(h);
      if (family === 4) return h.startsWith('127.');
      if (family === 6) return h === '::1';
      return false;
    }
    function effectivePort(url) {
      if (url.port) return String(url.port);
      return url.protocol === 'https:' ? '443' : '80';
    }
    function sameLocalCaptureOrigin(url, spec) {
      if (!spec.allowLocalhost) return false;
      const h = normalizeHost(url.hostname).replace(/^\[/, '').replace(/\]$/, '');
      const expectedHost = normalizeHost(spec.localCaptureHost || '').replace(/^\[/, '').replace(/\]$/, '');
      const expectedPort = String(spec.localCapturePort || '');
      const expectedScheme = String(spec.localCaptureScheme || '').toLowerCase() + ':';
      return !!expectedHost && !!expectedPort && !!expectedScheme && isAllowedLocalhostHost(h)
        && url.protocol === expectedScheme
        && h === expectedHost && effectivePort(url) === expectedPort;
    }

    (async () => {
      let spec;
      try {
        const input = fs.readFileSync(0);
        if (input.length > 1048576) throw new Error('spec too large');
        spec = JSON.parse(input.toString('utf8'));
      } catch (e) { console.error('bad spec'); process.exit(2); }
      if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(String(spec.proxyServer || ''))) {
        throw new Error('missing loopback browser proxy');
      }
      if (!/^[A-Za-z0-9_-]{43}$/.test(String(spec.proxyUsername || ''))
          || !/^[A-Za-z0-9_-]{43}$/.test(String(spec.proxyPassword || ''))) {
        throw new Error('missing browser proxy credentials');
      }
      const browser = await chromium.launch({
        headless: true,
        args: [
          '--disable-quic',
          '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
          '--webrtc-ip-handling-policy=disable_non_proxied_udp',
          '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
          '--proxy-bypass-list=<-loopback>'
        ]
      });
      try {
        const context = await browser.newContext({
          proxy: {
            server: spec.proxyServer,
            username: spec.proxyUsername,
            password: spec.proxyPassword,
            bypass: ''
          },
          serviceWorkers: 'allow'
        });
        const page = await context.newPage();
        await page.goto(spec.url, { waitUntil: 'domcontentloaded', timeout: spec.timeoutMs });
        for (const a of (spec.actions || [])) {
          if (a.do === 'click') await page.click(a.selector, { timeout: spec.timeoutMs });
          else if (a.do === 'fill') await page.fill(a.selector, a.value, { timeout: spec.timeoutMs });
          else if (a.do === 'wait') await page.waitForSelector(a.selector, { timeout: spec.timeoutMs });
          else if (a.do === 'press') await page.keyboard.press(a.key);
          else if (a.do === 'screenshot') await page.screenshot({ path: a.path, fullPage: true });
        }
        const out = spec.extract === 'html' ? await page.content() : await page.innerText('body');
        process.stdout.write(out.slice(0, 200000));
      } catch (e) {
        console.error('browser error: ' + e.message);
        process.exit(1);
      } finally {
        await browser.close();
      }
    })();
    """#
}
