# Noctweave Relay

Noctweave Relay is the native macOS operator app for running and configuring a self-hosted Noctweave relay. It uses the sibling `NoctweaveCore` Swift package and provides a graphical control surface for relay networking, storage, access policy, retention, federation, and application-neutral realtime services.

## NoctCord community services

Open the dedicated **NoctCord** panel to configure the relay capabilities used
by NoctCord communities. **Apply Recommended Profile** selects a Standard relay,
disables relay-wide temporal bucketing for immediate delivery, enables encrypted
realtime routes and durable shared logs, and permits bounded encrypted media.
Presence and media can then be disabled independently.

The panel reports whether the relay is ready for remote NoctCord clients.
Remote realtime routes require native Relay TLS or a trusted TLS reverse proxy;
loopback development is allowed without TLS. Voice and screen-sharing traversal
remain optional and can use the relay app's bundled coturn service.

These are transport capabilities, not a server-side community database. The
relay does not receive community names, channels, roles, memberships, message
plaintext, or media plaintext.

## Optional call traversal

Open **Transport** and enable **Call connectivity**. The native app bundles a
minimal coturn 4.17.2 service, generates its private credential key, advertises
`nw.ice-service@1`, issues short-lived TURN credentials, and starts or stops the
service with the relay. A local-network address is detected automatically, so a
LAN relay needs no separate coturn install, Docker container, account, or manual
secret configuration.

For Internet calls, route the displayed TURN TCP/UDP port and UDP allocation
range to the Mac. Ordinary HTTP reverse proxies cannot carry TURN. Operators
who already run coturn can select **External** under **Advanced call settings**.
The credential key remains in Keychain and is never included in relay info. See
the public
[`coturn_call_traversal.md`](../NoctweaveDocumentation/coturn_call_traversal.md)
guide for network examples and threat boundaries.

## What it includes

- Local relay start, stop, status, and runtime diagnostics
- Disk-backed or ephemeral in-memory storage
- TCP and HTTP endpoint configuration, with native TLS or TLS reverse-proxy support
- Password-based relay access control
- Optional bounded one-use rendezvous for Relay Pairing
- Attachment retention and temporal-bucketing controls
- Configurable NoctCord realtime routes, durable shared logs, presence, and media blobs
- Explicit `solo`, `manual`, `curated`, and `open` federation modes
- Coordinator and relay-directory configuration

The macOS relay serves native TCP frames or HTTP (`POST /relay`, `GET /health`, and
`GET /info`). It does not implement a WebSocket listener; use the sibling Linux
relay for WebSocket/WSS endpoints.

This repository is an operator application, not a hosted relay service. Messages and attachments must be encrypted by clients before submission. Relays store and route ciphertext and must not be treated as trusted plaintext processors.

## Requirements

- Xcode 26 or later
- macOS 26 SDK
- `NoctweaveCore` checked out as a sibling directory at `../NoctweaveCore`

## Build

Open `Noctweave Relay.xcodeproj` in Xcode, or build from the command line:

```sh
xcodebuild \
  -project "Noctweave Relay.xcodeproj" \
  -scheme "Noctweave Relay" \
  -destination 'platform=macOS' \
  build
```

See [RELAY_OPERATIONS.md](RELAY_OPERATIONS.md) for configuration and operating details.

## App identity migration

This project replaces the former Noctyra product identity. Its product name, scheme, bundle identifier, source symbols, and local persistence labels now use Noctweave. Existing Noctyra installations and their local data are not migrated automatically.

## License

This project is free software licensed under the GNU Affero General Public License, version 3 or, at your option, any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).

Bundled dependencies and their licenses are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

If you modify the program and let users interact with it over a network, the AGPL requires that those users be offered the Corresponding Source for the version they are using. This summary is informational; the license text controls.
