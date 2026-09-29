# Direct Sites — product specification

This document describes the behavior and limitations of version 0.3.0. It is the public product contract for users and contributors.

## Purpose and platform

Direct Sites is a native macOS utility for keeping selected destinations outside a VPN without changing the system default route. It provides domain matching for Firefox and Chrome and host routes for other applications. It is not a VPN client or a firewall.

The distributed executable targets Apple Silicon and macOS 14 or later. The current build is tested on macOS 27 with Swift 6.4. Intel, older macOS releases, different VPN clients and reboot recovery require independent validation. The package uses ad-hoc signing and is not notarized.

## Rules and editing

- Accept a domain, HTTP(S) URL, IPv4 or IPv6 address. Store the normalized host; URL paths do not affect matching.
- Reject credentials in URLs, wildcard input, malformed hosts, unsupported address classes and duplicate hosts.
- Store a UUID, normalized host, editable display name and optional `includeSubdomains` flag per rule. The list permits at most 200 entries; a name permits at most 120 characters and no line breaks.
- Default an empty display name to the host. Discover site-declared icons in the destination's HTTPS home page and fall back to HTTPS `/favicon.ico`. Keep the standard icon if no usable image can be obtained. Page titles are not extracted.
- Cache successful favicons in the current user's cache directory so they remain visible when the site is temporarily unavailable. On each GUI launch, load cached icons immediately and check sites for updates. Retry failed checks with increasing delays while the GUI is open; do not recheck successful icons until the next launch. Do not use a third-party favicon service.
- Fetch favicons for browser domain rules through the application's local SOCKS proxy so they use the same direct network path as matching browser traffic. Other rules use system networking. A failed direct proxy connection does not fall back to the VPN path.
- Apply additions, changes and removals only after the user chooses Apply and authorizes the system administrator prompt. Closing with pending changes prompts to cancel or discard.
- Keep the saved list and background operation independent of the GUI process.

## Browser domain mode

The local PAC URL is `http://127.0.0.1:17879/proxy.pac`. Firefox must be configured manually to use it and send destination names through SOCKS5. Chrome uses a bundled Manifest V3 extension installed manually in each desired Chrome profile. The extension requires Chrome's `proxy` permission and sets that profile's PAC URL without modifying macOS system proxy settings. The GUI setup button prepares the extension in the current user's Application Support directory, copies its absolute path for Chrome's folder picker, displays that path with `~` in place of the home directory, and opens Chrome's extension manager with installation instructions. The app does not silently install an extension or change an existing Chrome profile.

The PAC sends non-loopback traffic to the local proxy. A rule with `includeSubdomains: true` matches the base domain and all dot-delimited descendants. For example, `example.com` matches `api.example.com`, but not `evil-example.com` or `example.com.other.org`. Exact rules also match their exact destination when reached through the proxy. Numeric rules cannot include subdomains.

For matching destinations, the proxy binds outgoing TCP sockets to a physical `en*` interface using `IP_BOUND_IF` or `IPV6_BOUND_IF`. It does not create domain-mode host routes. Unmatched destinations use ordinary system routing, including an active VPN or pre-existing host routes. A direct-connection failure does not fall back to the VPN path.

The proxy implements SOCKS5 CONNECT without authentication, with a limit of 128 concurrent clients. UDP, QUIC and SOCKS BIND are unsupported. TCP data, including TLS, is relayed unchanged. Configuration is read for each new connection; applying configuration restarts the proxy and can interrupt existing connections. Missing or unreadable configuration rejects connections.

## IP route mode

The root helper resolves exact hosts with A and AAAA DNS queries and reconciles host routes every 30 seconds through launchd. A failed lookup preserves cached addresses. Checks may take longer than 30 seconds when DNS or system operations are slow.

The first physical Ethernet/Wi-Fi default gateway from the routing table is selected for each address family. VPN interfaces and default routes are not modified. An exception covers an entire destination IP, all applications and other sites sharing that IP.

Route ownership is persisted. Existing external routes are reported, not adopted or deleted. Removing a rule removes only owned routes whose current destination, gateway and interface still match the recorded route. Shared addresses remain until no rule needs them. Failed cleanup remains recorded for a retry.

## Services, storage and privilege boundary

| Item | Location or identity |
| --- | --- |
| Bundle identifier | `app.directsites.app` |
| Route service | `app.directsites` — root, launchd RunAtLoad / StartInterval |
| Browser service | `app.directsites.browser` — nobody, launchd RunAtLoad / KeepAlive |
| Helper and configuration | `/Library/Application Support/DirectSites/` |
| Rules and route state | `rules.json`, `state.json` |
| Launch agents | System LaunchDaemons under `/Library/LaunchDaemons/` |
| Proxy listener | IPv4 loopback `127.0.0.1:17879` |

Installation, configuration changes and removal require system authorization. The GUI does not receive or store the administrator password. The helper validates configuration, checks service-directory ownership and permissions, serializes privileged work with a file lock, and passes arguments to fixed system executables. User-entered names and hosts are not executable commands.

When installing over an earlier release, the GUI offers Apply even if the rule list is unchanged when it detects a validated older job. The helper identifies previous launchd jobs by their validated program arguments and project-specific labels, stops them, starts the neutral-label jobs, and removes only the identified old plists. Saved rules, state and owned routes remain in the same system-wide directory. If starting the new jobs fails, it attempts to restart the stopped old jobs. No path depends on the macOS account name.

Configuration and route state are readable by local users and writable by the administrator. The unauthenticated loopback proxy is available to other processes and users on the same Mac; it is not a local-user isolation boundary. It rejects loopback destinations, multicast and IPv6 link-local addresses, but is not a general private-network filter.

`GET /status` exposes in-memory connection counters and up to 100 distinct matched hostnames. It does not record URL paths or credentials. HTTP endpoints require the expected loopback Host header. DNS resolution and favicons for non-browser rules follow system networking; there is no separate DNS-leak prevention guarantee.

## Removal and failures

Restore Firefox's previous proxy settings and disable the Chrome extension before removing or stopping the service. Service removal stops both daemons and removes saved rules, helper files and owned routes. External routes are retained. Route-cleanup failure is reported and can be retried; an empty service directory and lock file may remain.

A running-service status is not proof that a website will load. VPN kill switches, DNS behavior, third-party login domains, IPv6 connectivity and CDN address variation may prevent access. Domains used by external authentication must be added separately. The browser must supply a hostname for suffix matching; an already-resolved IP cannot be mapped reliably to its original domain.

## Acceptance and verification

The 0.3.0 release increments the application version and build number, includes the Chrome extension in the signed app bundle, and provides an arm64 zip archive plus a SHA-256 checksum file. The release notes must identify verification performed on a real Chrome profile and limitations that remain unverified.

- Build the GUI and helper with Swift 6 and warnings treated as errors.
- Run the assertion suite in `Source/Tests.swift` without compiler optimizations disabling assertions. It covers normalization, rejected input, physical gateway selection, cached DNS, shared routes, ownership, domain boundaries, backward-compatible rule decoding and favicon discovery and retry policy.
- Validate Chrome extension metadata and configuration and verify that its setup copy stays inside the user's Application Support directory. On a test Chrome profile, install the unpacked extension and confirm that a matching domain and an unmatched domain use the intended routes without altering system proxy settings.
- Verify an upgrade from the previous service labels preserves rules and route ownership, removes only validated old jobs, and supports uninstall. Verify a failed upgrade restarts the old jobs where possible.
- Confirm that an existing installation with unchanged rules offers Apply for service migration.
- Verify the bundle's property list and deep code signature, and inspect the generated icon at all packaged sizes.
- On a test Mac, verify a matching domain and a subdomain while the VPN is active; verify an unmatched destination retains system routing.
- Check that the proxy remains reachable after closing the GUI, and that the static application icon survives quitting.
- Separately validate reboot, sleep, network changes, VPN reconnection and uninstall before claiming compatibility with another environment.

Automated core tests do not replace the privileged integration checks above. Release notes state the checks actually performed.
