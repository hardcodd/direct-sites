**English** | [Русский](CHANGELOG.ru.md)

# Changelog

Published versions and changes planned for the next release. Version dates refer to their Git tags.

## 0.4.0 — October 12, 2026

- Clear the entire domain/IP list with confirmation, including hidden rules; save through Apply while retaining background services and system proxy settings.
- Search names, domains, Unicode hosts and IPs; filter rule types/readiness, reverse sorting, and collapse type or related-domain groups. Presentation preferences persist locally, with UUID-based editing and removal after list navigation.
- Persistent system-mode intent and a background monitor repair cleared/disabled proxies after network changes, with a five-second fallback check. Explicit disable stops maintenance before recovery; active foreign proxies remain protected.
- Shared system HTTP/HTTPS proxy mode targeting Safari, Chrome, Yandex and Firefox. Firefox requires selecting system proxy settings; disable the previous Chrome extension.
- Saved proxy preferences, safe restoration, external change protection and recovery before service removal.
- HTTP forwarding and HTTPS CONNECT, retaining SOCKS5 and IP exceptions.
- Protocol and preference recovery tests. Verified the four installed browsers with hidemy.name active, direct and VPN socket routes, and exact restoration of network proxy preferences. Reboot recovery remains unverified.
- Compatible CONNECT authority handling for Safari and reliable launchd service replacement during helper updates.

## 0.3.0 — September 29, 2026

### Added

- Google Chrome support through a proxy extension for individual profiles.
- Chrome setup button.
- HTML favicon discovery, local caching and retries after failures.

### Changed

- Browser-rule favicons load through the local Direct Sites proxy.
- App and service identifiers no longer contain a personal name. Applying an update migrates older services while preserving rules and routes.
- Chrome extension setup displays the folder path using `~` instead of the account name.

## 0.2.1 — September 28, 2026

- First published release: native macOS app with Firefox domain rules, IP routes for other applications, background services, English and Russian UI and source builds.
