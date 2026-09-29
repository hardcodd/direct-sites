import Foundation

/// Finds HTTPS icons declared by a site's home page, with its conventional icon as the final fallback.
func faviconURLs(in html: String, pageURL: URL) -> [URL] {
    guard pageURL.scheme == "https", pageURL.host != nil,
          let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL else { return [] }
    let tags = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
    let attributes = try! NSRegularExpression(pattern: #"([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
    let source = html as NSString
    var urls: [URL] = []
    for tag in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
        let text = source.substring(with: tag.range)
        let tagSource = text as NSString
        var values: [String: String] = [:]
        for match in attributes.matches(in: text, range: NSRange(location: 0, length: tagSource.length)) {
            let key = tagSource.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).first(where: { match.range(at: $0).location != NSNotFound })
                .map { tagSource.substring(with: match.range(at: $0)) } ?? ""
            values[key] = value
        }
        let relations = Set((values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        guard !relations.isDisjoint(with: ["icon", "apple-touch-icon", "apple-touch-icon-precomposed"]),
              let href = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
              let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              !urls.contains(url) else { continue }
        urls.append(url)
        if urls.count == 8 { break }
    }
    if !urls.contains(fallback) { urls.append(fallback) }
    return urls
}

/// Spaces repeated failures while still retrying sites that were temporarily unavailable.
func faviconRetryDelay(after failures: Int) -> TimeInterval {
    switch failures {
    case ...1: 30
    case 2: 120
    case 3: 600
    default: 3_600
    }
}
