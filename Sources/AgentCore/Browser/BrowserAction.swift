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
                             localCaptureHost: String? = nil,
                             localCapturePort: String? = nil) -> [String: Any] {
        ["url": url,
         "actions": actions.map { $0.json },
         "extract": (extract == "html" ? "html" : "text"),
         "configuredAllowedHosts": configuredAllowedHosts,
         "perCallAllowedHosts": perCallAllowedHosts,
         "allowLocalhost": allowLocalhost,
         "localCaptureHost": localCaptureHost ?? "",
         "localCapturePort": localCapturePort ?? "",
         "timeoutMs": 30000]
    }

    public static func jsonString(url: String, actions: [BrowserAction], extract: String,
                                  configuredAllowedHosts: [String] = [],
                                  perCallAllowedHosts: [String] = [],
                                  allowLocalhost: Bool = false,
                                  localCaptureHost: String? = nil,
                                  localCapturePort: String? = nil) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: build(url: url, actions: actions, extract: extract,
                                                                           configuredAllowedHosts: configuredAllowedHosts,
                                                                           perCallAllowedHosts: perCallAllowedHosts,
                                                                           allowLocalhost: allowLocalhost,
                                                                           localCaptureHost: localCaptureHost,
                                                                           localCapturePort: localCapturePort)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The CONSTANT Playwright driver. No interpolation — it reads the spec from argv[2] as JSON and
    /// executes it. Agent input never becomes code.
    public static let driverJS = #"""
    // argv[3] is an absolute path to the playwright module (so a globally-installed playwright resolves
    // from this temp-dir driver); falls back to bare 'playwright' for a local install / NODE_PATH.
    const { chromium } = require(process.argv[3] || 'playwright');
    const dns = require('dns').promises;
    const net = require('net');

    function normalizeHost(raw) {
      return String(raw || '').trim().replace(/\.+$/, '').toLowerCase();
    }
    function hostMatches(host, patterns) {
      return (patterns || []).some((pattern) => {
        pattern = normalizeHost(pattern);
        if (pattern.startsWith('*.')) {
          const suffix = pattern.slice(1);
          return host.endsWith(suffix) && host.length > suffix.length;
        }
        return host === pattern;
      });
    }
    function isPrivateIPv4(ip) {
      const parts = ip.split('.').map((p) => Number(p));
      if (parts.length !== 4 || parts.some((p) => Number.isNaN(p))) return false;
      const [a, b] = parts;
      return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254)
        || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
    }
    function isPrivateIPv6(ip) {
      const h = ip.toLowerCase();
      if (h === '::' || h === '::1') return true;
      if (h.startsWith('fc') || h.startsWith('fd') || h.startsWith('fe80:')) return true;
      // IPv4-mapped (::ffff:a.b.c.d) / IPv4-compatible (::a.b.c.d): block via the IPv4 rules so
      // ::ffff:127.0.0.1 / ::ffff:169.254.169.254 don't slip past.
      const m = h.match(/^::(?:ffff:)?(\d+\.\d+\.\d+\.\d+)$/);
      if (m) return isPrivateIPv4(m[1]);
      return false;
    }
    function isPrivateIP(ip) {
      const family = net.isIP(ip);
      return family === 4 ? isPrivateIPv4(ip) : (family === 6 ? isPrivateIPv6(ip) : false);
    }
    function isAllowedLocalhostHost(host) {
      const h = normalizeHost(host).replace(/^\[/, '').replace(/\]$/, '');
      if (h === 'localhost') return true;
      const family = net.isIP(h);
      if (family === 4) return h.startsWith('127.');
      if (family === 6) return h === '::' || h === '::1';
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
      return !!expectedHost && !!expectedPort && isAllowedLocalhostHost(h)
        && h === expectedHost && effectivePort(url) === expectedPort;
    }
    async function blockReasonForURL(url, spec) {
      const h = normalizeHost(url.hostname);
      if (!h) return 'empty host';
      if ((spec.configuredAllowedHosts || []).length && !hostMatches(h, spec.configuredAllowedHosts)) {
        return h + ' is not in configured host allowlist';
      }
      if ((spec.perCallAllowedHosts || []).length && !hostMatches(h, spec.perCallAllowedHosts)) {
        return h + ' is not in per-call host allowlist';
      }
      if (sameLocalCaptureOrigin(url, spec)) return null;
      if (h === 'localhost') return 'localhost is not allowed';
      let addrs = [];
      if (net.isIP(h)) addrs = [h];
      else {
        try { addrs = (await dns.lookup(h, { all: true })).map((a) => a.address); } catch (_) { addrs = []; }
      }
      if (addrs.some(isPrivateIP)) return h + ' resolves to a private/loopback address';
      return null;
    }

    (async () => {
      let spec;
      try { spec = JSON.parse(process.argv[2]); } catch (e) { console.error('bad spec'); process.exit(2); }
      const browser = await chromium.launch({ headless: true });
      try {
        const page = await browser.newPage();
        await page.route('**/*', async (route) => {
          let u;
          try { u = new URL(route.request().url()); } catch (_) { return route.abort(); }
          if (u.protocol !== 'http:' && u.protocol !== 'https:') return route.abort();
          const reason = await blockReasonForURL(u, spec);
          if (reason) { console.error('blocked browser request: ' + reason); return route.abort(); }
          return route.continue();
        });
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
