---
name: ballerina-debug
description: Debug, profile, and diagnose Ballerina programs. Use when troubleshooting runtime issues, finding performance bottlenecks, diagnosing concurrency problems (deadlocks, race conditions), or profiling CPU usage.
allowed-tools: Read Write Edit Bash Glob Grep
---

Help the user diagnose their Ballerina program. Determine which tool fits their problem:

| Problem | Tool | Command |
|---------|------|---------|
| Performance bottleneck / slow functions | **Profiler** | `bal profile` |
| Deadlock / race condition / strand inspection | **Strand Dump** | `kill -SIGTRAP <PID>` |
| Step-through debugging / breakpoints | **VS Code Debugger** | launch.json config |

---

## 1. Profiler (`bal profile`)

Identifies where CPU time is spent by instrumenting function calls and generating a flame graph.

### Workflow

1. Run from the package root:
   ```
   bal profile
   ```
2. Exercise the application (send requests, trigger workflows).
3. Stop with `Ctrl+C`.
4. Open `target/bin/ProfilerOutput.html` in a browser.
5. Use the flame graph to identify hot functions — look for wide bars (high cumulative time).

### Profiling an HTTP service
1. `bal profile` starts the service.
2. Send test requests: `curl localhost:<port>/<path>`
3. `Ctrl+C` to stop and generate the report.

### Key notes
- Profiling adds significant overhead — results show relative cost, not absolute production times.
- Flame graph supports search, zoom (click a function), and reset.
- This is an **experimental** feature.

---

## 2. Strand Dump (concurrency diagnostics)

Captures the state of all strands and strand groups at a point in time. Use to diagnose deadlocks, livelocks, race conditions, and blocked strands.

### Workflow

1. Find the PID of the running Ballerina program:
   ```
   jps
   ```
   Look for the `$_init` class (or `BTestMain` for tests).

2. Send `SIGTRAP` to trigger the dump:
   ```
   kill -SIGTRAP <PID>
   ```

3. The dump prints to the program's stdout. Look for:

| Strand State | Meaning |
|-------------|---------|
| `WAITING FOR LOCK` | Blocked on lock acquisition — potential deadlock |
| `BLOCKED ON WORKER MESSAGE SEND` | Sync send blocking |
| `BLOCKED ON WORKER MESSAGE RECEIVE` | Waiting for worker message |
| `BLOCKED ON WORKER MESSAGE FLUSH` | Flush blocking |
| `WAITING` | Blocked on wait action |
| `BLOCKED` | Other (sleep, external call) |
| `RUNNABLE` | Ready or executing |
| `DONE` | Completed |

4. Check for deadlock patterns: two or more strands in `WAITING FOR LOCK` holding locks the other needs.

### Limitations
- **Not available on Windows** (requires POSIX signals).

---

## 3. VS Code Debugger

For step-through debugging with breakpoints, expression evaluation, and call stack inspection.

### Setup

Add to `.vscode/launch.json`:
```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Ballerina Debug",
            "type": "ballerina",
            "request": "launch",
            "programArgs": [],
            "commandOptions": [],
            "env": {}
        },
        {
            "name": "Ballerina Remote",
            "type": "ballerina",
            "request": "attach",
            "debuggeeHost": "127.0.0.1",
            "debuggeePort": "5005"
        }
    ]
}
```

### Capabilities
- Breakpoints with conditions and logpoints
- Pause/continue execution
- Evaluate expressions at runtime
- View call stacks and strands
- Debug tests via CodeLens

### Remote debugging
1. Start the program with debug port: `bal run --debug <port>`
2. Attach using the "Ballerina Remote" launch config.

---

## References

- Profiler: https://ballerina.io/learn/ballerina-profiler/
- Strand Dump: https://ballerina.io/learn/strand-dump-tool/
- Debugger: https://ballerina.io/learn/debug-ballerina-programs/
