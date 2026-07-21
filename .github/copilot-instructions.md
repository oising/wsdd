# Copilot instructions for wsdd

## Build, test, and lint commands

- No build step is required; `src/wsdd.py` is the executable script.
- Syntax check: `python -m py_compile src/wsdd.py`
- Lint: `flake8 --count --show-source --statistics src`
- Type check all supported Python versions used by CI: `test/linting/mypy.sh`
- Type check one Python target: `mypy --config-file=test/linting/mypy.ini --python-version=3.13 src/wsdd.py`
- Run all regression tests: `test/regressions/run-regressions.sh`
- Run one regression test: `WSDD_ROOT_DIR="$(pwd)" WSDD_SCRIPT="$(pwd)/src/wsdd.py" test/regressions/03_relay_helpers/run.sh`

The shell scripts assume a POSIX shell and common Unix tooling. Some regression tests also need `nc` and whichever `python3.x` executables are present locally.

## High-level architecture

- `src/wsdd.py` is a single-module asyncio daemon implementing both WS-Discovery host mode and discovery client mode. Startup flows through `parse_args()` and `main()`, then creates a fresh event loop, optional `WSDRelay`, a platform-specific `NetworkAddressMonitor`, optional API server, privilege/chroot changes, and signal handlers.
- `NetworkAddressMonitor` is the cross-platform orchestration layer. Subclasses (`NetlinkAddressMonitor`, `RouteSocketAddressMonitor`, `DladmAddressMonitor`) enumerate and watch addresses for Linux, BSD/macOS/OpenBSD, and SunOS. For each handled multicast-capable address it creates a `MulticastHandler`, then attaches `WSDHost`, `WSDClient`, HTTP metadata serving, and relay handlers according to CLI options.
- `MulticastHandler` owns the per-address sockets: multicast receive, multicast send, unicast send, and the HTTP listen address. It registers socket readers on the asyncio loop and dispatches received UDP payloads to registered `INetworkPacketHandler` instances.
- `WSDMessageHandler` centralizes SOAP/XML parsing, duplicate message suppression, and XML response construction. `WSDHost` handles incoming `Probe`/`Resolve` and sends `Hello`/`Bye`; `WSDClient` sends probes, processes `Hello`/`ProbeMatches`/`ResolveMatches`, and performs HTTP metadata exchange; `WSDHttpRequestHandler` serves metadata responses for host mode.
- `WSDRelay` bridges IPv4 WS-Discovery multicast over explicit unicast UDP peers. It wraps payloads in JSON envelopes with packet IDs, TTL, optional HMAC-SHA256, optional deflate compression, pending reply routing, duplicate/suppression caches, and optional `XAddrs` rewriting for ONVIF-style deployments.
- `ApiServer` exposes runtime control over either a Unix socket, localhost TCP port, or systemd socket activation. The `--no-autostart` mode depends on this API to start/stop network handling after launch.
- Packaging and service integration live under `etc/` and `man/`; they are templates for init systems, firewalls, and the manual page, not separate runtime modules.

## Key conventions

- Keep compatibility broad: README states Python 3.7+ at runtime, while CI checks syntax on Python 3.10 and mypy targets 3.10 through 3.14. Avoid newer syntax unless the project deliberately raises its minimum.
- Preserve the single-file executable model. New runtime behavior usually belongs in `src/wsdd.py`; service, firewall, and init-system changes belong under `etc/`, and CLI/man-page-facing behavior should be reflected in `README.md` and `man/wsdd.8` when changed.
- Code style follows `CONTRIBUTING.md`: 4-space indentation, PEP8/pycodestyle expectations, type hints, short block comments preferred over inline comments, and function docstrings only where useful.
- Flake8 is configured in `setup.cfg` with `max-line-length = 120` and ignores `F401,W503`; do not reformat to a stricter width or different operator-wrapping style.
- XML parsing should continue to prefer `defusedxml.ElementTree.fromstring` when available and fall back to the standard library import only when the optional dependency is absent.
- Most runtime state is intentionally module-level or class-level (`args`, `logger`, singleton monitors/relay, handler instance lists, duplicate-message caches). Be careful to update cleanup/teardown paths when adding handlers, sockets, tasks, or class-level registries.
- Network changes must respect address-family and interface filtering in `NetworkAddressMonitor.is_address_handled()`: IPv4 non-loopback and IPv6 link-local multicastable addresses are the supported discovery surfaces.
- Graceful shutdown matters: host/client teardown schedules delayed UDP repeats for `Bye` and waits for pending tasks when needed. Avoid bypassing existing `cleanup()`/`teardown()` methods.
- Relay logic is IPv4-only for local WS-Discovery capture/rebroadcast. Keep relay packet validation explicit and noisy: malformed envelopes, bad HMACs, unknown packet types, and invalid mappings should be logged rather than silently accepted.
- Regression tests are executable shell scripts one directory below `test/regressions/`; the runner discovers only executable `.sh` files in those level-1 subdirectories.
