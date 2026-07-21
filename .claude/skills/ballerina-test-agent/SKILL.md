---
name: ballerina-test-agent
description: Run smoke or deep tests against the Ballerina developer agent and its skills. Use to verify installation, agent behavior, skill accuracy, and code generation quality.
allowed-tools: Bash Read Grep Glob
disable-model-invocation: true
---

Run the Ballerina agent and skills test suite. Accepts an argument: `smoke` (default) or `deep`.

## Setup

1. Copy the fixture to a temp directory for isolation:
   ```
   FIXTURE_DIR=/tmp/bal-test-$(date +%s)
   cp -r ${CLAUDE_SKILL_DIR}/fixture $FIXTURE_DIR
   cd $FIXTURE_DIR
   ```

2. Verify the fixture compiles:
   ```
   bal build --offline
   ```
   If this fails, stop — the fixture is broken.

## Running Tests

For each test, run the command, capture the output, and check for the pass criteria. Report results in a summary table.

Network-dependent tests: if `WebFetch` or network calls fail, report as `SKIP` not `FAIL`.

### Smoke Tests ($ARGUMENTS = "smoke" or empty)

Run all 8 tests:

| ID | Test | Command | Pass if output contains |
|----|------|---------|------------------------|
| S1 | Fixture compiles | `bal build --offline` (already done in setup) | Exit code 0 |
| S2 | Search finds kafka | `claude -p "/ballerina-search kafka"` | `ballerinax/kafka` |
| S3 | Best practices catches bad code | `claude -p "/ballerina-best-practices Review this file for violations: $(cat $FIXTURE_DIR/utils.bal)"` | At least 3 rule violations mentioned |
| S4 | Best practices clean code | `claude -p "/ballerina-best-practices Review this file for violations: $(cat $FIXTURE_DIR/service.bal)"` | No violations flagged OR "follows best practices" |
| S5 | By-example HTTP | `claude -p "/ballerina-by-example HTTP service"` | `http:Listener` |
| S6 | Spec-lookup error handling | `claude -p "/ballerina-spec-lookup How does the check expression work?"` | `check` |
| S7 | Agent refuses Dependencies.toml edit | `claude -p --agent ballerina-developer "Edit Dependencies.toml and add the kafka dependency"` | Refuses OR mentions auto-resolution via `bal build` |
| S8 | Agent suggests bal build --offline | `claude -p --agent ballerina-developer "I just wrote some code, how do I check if it compiles?"` | `bal build --offline` |

### Deep Tests ($ARGUMENTS = "deep")

Run all smoke tests PLUS these 10 additional tests:

| ID | Test | Command | Pass if output contains |
|----|------|---------|------------------------|
| D1 | Search prefers official | `claude -p "/ballerina-search mysql"` | `ballerinax/mysql` |
| D2 | Catches each violation | `claude -p "/ballerina-best-practices Review this file thoroughly, list every violation: $(cat $FIXTURE_DIR/utils.bal)"` | 7+ distinct violations mentioned |
| D3 | Spec-lookup type narrowing | `claude -p "/ballerina-spec-lookup How does type narrowing work with is expression?"` | `type narrowing` or `type guard` |
| D4 | By-example WebSocket | `claude -p "/ballerina-by-example WebSocket server"` | `websocket` (case-insensitive) |
| D5 | GraalVM local | `claude -p "/ballerina-graalvm I want to build a native image locally"` | `bal build --graalvm` |
| D6 | GraalVM Docker | `claude -p "/ballerina-graalvm I want to build a native image in Docker"` | `--cloud=docker` |
| D7 | Debug profiler | `claude -p "/ballerina-debug My service is slow, how do I find the bottleneck?"` | `bal profile` |
| D8 | Debug strand dump | `claude -p "/ballerina-debug I think my app has a deadlock"` | `SIGTRAP` or `strand dump` |
| D9 | Agent suggests search | `claude -p --agent ballerina-developer "How do I find a Ballerina package for sending emails?"` | `ballerina-search` or `bal search` |
| D10 | Agent suggests debug | `claude -p --agent ballerina-developer "My Ballerina app is hanging and not responding"` | `ballerina-debug` or `profile` or `strand` |

## Reporting

After running all tests, output a summary table:

```
=== Ballerina Agent Test Report ===
Tier: [smoke|deep]
Date: [current date]

ID   Test                              Result
---  ----                              ------
S1   Fixture compiles                  PASS
S2   Search finds kafka                PASS
...

Result: X/Y passed, Z skipped
```

## Notes

- Each `claude -p` call consumes tokens. Smoke suite: ~8 calls. Deep suite: ~18 calls.
- Run tests sequentially — parallel `claude -p` calls may hit rate limits.
- Clean up the temp directory after tests: `rm -rf $FIXTURE_DIR`
- For the full manual playbook with detailed pass/fail criteria, see [test_scenarios.md](test_scenarios.md).
