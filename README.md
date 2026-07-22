# Noctweave Relay

Noctweave Relay is the native macOS operator app for running and configuring a self-hosted Noctweave relay. It uses the sibling `NoctweaveCore` Swift package and provides a graphical control surface for relay networking, storage, access policy, retention, and federation settings.

## What it includes

- Local relay start, stop, status, and runtime diagnostics
- Disk-backed or ephemeral in-memory storage
- TCP and HTTP endpoint configuration, with native TLS or TLS reverse-proxy support
- Password-based relay access control
- Optional bounded one-use rendezvous for Relay Pairing
- Attachment retention and temporal-bucketing controls
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

If you modify the program and let users interact with it over a network, the AGPL requires that those users be offered the Corresponding Source for the version they are using. This summary is informational; the license text controls.
