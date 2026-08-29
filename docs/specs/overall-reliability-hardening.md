# Joy Harness Overall Reliability Hardening

Status: Accepted

Base: `v0.4.0` (`e0d343f`)

Target branch: `codex/overall-reliability-hardening`

## Goal

Make Joy Harness recover predictably from local I/O and subprocess failures, expose stale or unavailable state instead of retaining misleading data, clean up every started resource, and run the same checks locally and in pull-request CI.

## Requirements

### R1. RP2040 serial output

- Host writes are FIFO and bounded.
- Partial writes consume only the written prefix.
- `EINTR` retries, `EAGAIN`/`EWOULDBLOCK` retains pending bytes, and fatal errors disconnect.
- Disconnect clears bytes admitted for the old connection.
- `sendKey` and `sendJoystick` return whether the complete command was admitted for delivery. They do not claim firmware acknowledgement.
- Keys containing unsupported characters are rejected rather than rewritten.

Complete when deterministic host tests cover partial write, backpressure, capacity rejection, interruption, fatal failure, and disconnect clearing.

### R2. RP2040 HID transport

- A JSON message is enqueued completely or rejected without changing queued packets.
- The 32-slot ring retains one sentinel slot and exposes a rejection counter.
- A packet leaves the queue only after TinyUSB accepts the report.
- Cross-packet, full-capacity, insufficient-capacity, and oversized-message behavior use the same C module as firmware.

Complete when host C contract tests and the real RP2040 firmware build pass.

### R3. Unix socket protocol

- One connection carries one newline-delimited request; bytes after the first line are ignored.
- The server responds after the first line without waiting for client EOF.
- An absolute one-second request deadline and 64,000-byte payload limit apply.
- UTF-8, JSON, state, and action validation is atomic.
- Every accepted or rejected request receives one newline-delimited JSON response.
- The CLI returns nonzero for daemon errors, timeouts, empty responses, and invalid responses while accepting the legacy `ok\n` response.
- Server stop removes only its own socket lifecycle state and permits immediate same-path restart.

Complete when real Unix socket integration tests cover no-EOF clients, malformed input, unknown commands, multiple lines, timeout, size limit, response compatibility, and restart.

### R4. Codex app-server recovery

- The provider exposes `stopped`, `starting`, `healthy`, `degraded`, or `failed` health.
- Initialization and list requests have deadlines and match responses by request ID.
- Process exit, launch failure, write failure, or timeout clears pending state and schedules bounded exponential-backoff restart.
- A successful initialization resets backoff.
- `stderr` is captured in a bounded diagnostic buffer instead of discarded.
- `stop()` cancels timers, closes pipes, terminates the child, and suppresses restart.

Complete when deterministic state-machine tests cover successful initialization, mismatched responses, timeout, backoff, recovery, and stop.

### R5. Status freshness and persistence

- Status payloads use a shared `Codable` DTO rather than `[String: Any]`.
- Reads classify state as `fresh`, `stale`, or `unavailable` from the payload timestamp and read/decode result.
- Read failure never leaves an old status presented as fresh.
- Writes report directory, encoding, and atomic-write failures through a stored observable error and stderr.
- The dashboard records the last successful read time.

Complete when repository tests cover fresh, stale, malformed, missing, and failed-write cases.

### R6. Symmetric lifecycle

- Every `start()` added or used by `JoyHarnessRuntime` has a corresponding idempotent `stop()`.
- Application termination invokes runtime stop.
- Timers, socket sources, controller discovery observers, subprocesses, serial sources, and monitoring timers are invalidated or cancelled.
- NotificationCenter observer tokens are retained and removed.

Complete when lifecycle tests prove repeated start/stop does not duplicate observers or retain socket resources.

### R7. Automation and release consistency

- Pull requests to `main` and pushes to `main` run Swift tests, Python/C contracts, ShellCheck, release build, and RP2040 firmware build.
- `task ci` is the local application-check entry point.
- `task release-check` validates source version, README download names, test expectations, tag format when present, DMG naming, and firmware protocol version.
- Release automation invokes the shared checks rather than maintaining a divergent test list.

Complete when Taskfile dry-run, workflow parsing, `task ci`, `task release-check`, and `task firmware` pass.

### R8. Protocol and domain documentation

- `docs/protocol.md` defines socket, status, CDC, HID packetization, compatibility names, limits, success semantics, and failure responses.
- `CONTEXT.md` defines the single Joy Harness context, core terms, boundaries, lifecycle, and invariants.
- Controller mapping migrations use one monotonic schema version while honoring existing completed migration flags during upgrade.

Complete when documentation matches executable constants and migration tests cover a legacy store plus an already-current store.

## Compatibility

- Preserve `.agent-deck`, `AgentDeck`, `agentdeck-rp2040`, and `codexpad-rp2040` compatibility behavior.
- Preserve the default socket path and `AGENT_DECK_SOCK` / `AGENT_DECK_RP2040_PORT` overrides.
- Preserve bare-state socket requests and the legacy CLI success response.
- Existing controller mapping customizations must survive migration.
- macOS 13 remains the minimum supported platform.

## Test Seams

- Serial output state machine through `SerialOutputBuffer`.
- Firmware packet queue through `transport_queue.h` linked into both host tests and firmware.
- Socket behavior through real `AF_UNIX` clients.
- Codex recovery through a pure request/restart state machine and injected process events.
- Status behavior through `StatusRepository` with temporary files and injected clock/write failures.
- Lifecycle through idempotent public `start()` / `stop()` calls.

## Non-goals

- End-to-end firmware ACKs and retransmission are deferred because they require a versioned CDC protocol change. This release defines host success as bounded admission, not device execution.
- Large UI and controller-mapping file splits are deferred unless required to establish the test seams above; unrelated source movement would obscure the reliability review.
- No release is published and no tag is created by this work.

## Acceptance

All requirements implemented, both review axes have no unresolved high-severity findings, and these commands succeed from a clean checkout:

```bash
task ci
task release-check
task firmware
git diff --check
```
