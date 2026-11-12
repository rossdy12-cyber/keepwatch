import WebKit

/// Built-in ad / tracker blocking via a compiled WKContentRuleList. Toggleable; compiled once and added to tabs.
enum AdBlock {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "adblock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "adblock") }
    }

    private(set) static var ruleList: WKContentRuleList?

    /// Common ad / tracker / analytics hosts. Not exhaustive, but blocks the big offenders.
    private static let hosts = [
        "doubleclick.net", "googlesyndication.com", "google-analytics.com", "googletagmanager.com",
        "googletagservices.com", "googleadservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "ads.yahoo.com", "adnxs.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "criteo.com",
        "criteo.net", "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com", "moatads.com",
        "amazon-adsystem.com", "facebook.net", "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        "hotjar.com", "mixpanel.com", "segment.com", "segment.io", "fullstory.com", "mouseflow.com",
        "bugsnag.com", "nr-data.net", "newrelic.com", "branch.io", "appsflyer.com", "adjust.com",
        "chartbeat.com", "bluekai.com", "demdex.net", "everesttech.net", "2mdn.net", "casalemedia.com",
        "openx.net", "sharethrough.com", "smartadserver.com", "teads.tv", "yieldmo.com", "zedo.com",
        "adroll.com", "pixel.quantserve.com", "sb.scorecardresearch.com", "stats.g.doubleclick.net",
    ]

    static func rulesJSON() -> String {
        let rules = hosts.map { host -> String in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return "{\"trigger\":{\"url-filter\":\"https?://([^/]*\\\\.)?\(escaped)\",\"url-filter-is-case-sensitive\":false},\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    static func compile(_ completion: (() -> Void)? = nil) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "crimson-adblock", encodedContentRuleList: rulesJSON()) { list, error in
            if let list { ruleList = list }
            completion?()
        }
    }

    @MainActor
    static func compileAsync() async {
        if ruleList != nil { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            compile { c.resume() }
        }
    }

    /// Applies (or removes) the blocklist on a web view's content controller per the current toggle.
    static func apply(to controller: WKUserContentController) {
        guard let ruleList else { return }
        if enabled { controller.add(ruleList) } else { controller.remove(ruleList) }
    }
}
