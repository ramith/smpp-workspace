# Ballerina Agent & Skills — Test Scenarios

Manual playbook for verifying the Ballerina developer agent and its skills.
Run these against a Claude Code session with the agent installed.

## Prerequisites

- `bal` CLI installed (2201.13.x)
- Ballerina developer agent installed in `~/.claude/agents/` or `.claude/agents/`
- Skills installed in `~/.claude/skills/` or `.claude/skills/`
- The `fixture/` directory from this skill available locally

---

## Smoke Tests

Quick checks (~2-3 min). All should pass for a working installation.

### S1: Fixture compiles

**Run:** `cd fixture && bal build --offline`
**Pass:** Exit code 0, generates `target/bin/test_fixture.jar`

### S2: Package search finds kafka

**Prompt:** `/ballerina-search kafka`
**Pass:** Output contains `ballerinax/kafka` with an import statement
**Requires:** Network access

### S3: Best practices catches bad code

**Prompt:** `/ballerina-best-practices` then point it at `fixture/utils.bal`
**Pass:** Output mentions at least 3 violations (e.g., `var` usage, string concatenation, `io:println`)

### S4: Best practices — clean code OK

**Prompt:** `/ballerina-best-practices` then point it at `fixture/service.bal`
**Pass:** Output does NOT flag violations, or says code follows best practices

### S5: By-example finds HTTP example

**Prompt:** `/ballerina-by-example HTTP service`
**Pass:** Output contains a code snippet with `http:Listener`
**Requires:** Network access

### S6: Spec-lookup on error handling

**Prompt:** `/ballerina-spec-lookup How does the check expression work in Ballerina?`
**Pass:** Output explains `check` expression semantics
**Requires:** Network access

### S7: Agent refuses Dependencies.toml edit

**Prompt:** (to the agent) `Edit Dependencies.toml and add the kafka dependency`
**Pass:** Agent refuses or explains that dependencies auto-resolve via `bal build`

### S8: Agent suggests bal build --offline

**Prompt:** (to the agent) `I just wrote some code, how do I check if it compiles?`
**Pass:** Output contains `bal build --offline`

---

## Deep Tests

Thorough checks (~10-15 min). Run after smoke tests pass.

### D1: Search prefers official packages

**Prompt:** `/ballerina-search mysql`
**Pass:** `ballerinax/mysql` is listed first or prominently before any community package
**Requires:** Network access

### D2: Best practices catches each violation

**Prompt:** `/ballerina-best-practices` on `fixture/utils.bal`
**Pass:** Detects 7+ of these 10 violations:

| # | Violation | Rule |
|---|-----------|------|
| 1 | `var` instead of explicit type | 2.1 |
| 2 | String concatenation instead of template | 5.3 |
| 3 | Sentinel value `""` instead of nil | 2.2 |
| 4 | Parentheses in `if` | 4.2 |
| 5 | `io:println` instead of `log` | 1.4 |
| 6 | Redundant variable before return | 5.2 |
| 7 | Redundant type on constant | 2.7 |
| 8 | lowerCamelCase type name | 1.2 |
| 9 | Missing docs on public function | 1.5 |
| 10 | Bare `string` for department | 2.8 |

### D3: Spec-lookup on type narrowing

**Prompt:** `/ballerina-spec-lookup How does type narrowing work with the is expression?`
**Pass:** Output explains type narrowing / type guard semantics
**Requires:** Network access

### D4: By-example for WebSocket

**Prompt:** `/ballerina-by-example WebSocket server`
**Pass:** Output contains WebSocket-related code or service definition
**Requires:** Network access

### D5: GraalVM local workflow

**Prompt:** `/ballerina-graalvm I want to build a native image locally`
**Pass:** Output includes `bal build --graalvm` and mentions GraalVM/SDKMAN prerequisites

### D6: GraalVM Docker workflow

**Prompt:** `/ballerina-graalvm I want to build a native image in Docker`
**Pass:** Output includes `bal build --graalvm --cloud=docker`

### D7: Debug picks profiler

**Prompt:** `/ballerina-debug My HTTP service is responding slowly, how do I find the bottleneck?`
**Pass:** Output suggests `bal profile` and mentions flame graph

### D8: Debug picks strand dump

**Prompt:** `/ballerina-debug I think my application has a deadlock, strands seem stuck`
**Pass:** Output suggests `kill -SIGTRAP` and strand dump analysis

### D9: Agent suggests search skill

**Prompt:** (to the agent) `How do I find a Ballerina package for sending emails?`
**Pass:** Agent mentions `/ballerina-search` or uses `bal search`

### D10: Agent suggests debug skill

**Prompt:** (to the agent) `My Ballerina app is hanging and not responding to requests`
**Pass:** Agent mentions `/ballerina-debug` or suggests profiler/strand dump

### D11: Consistent queue declarations

**Prompt:** (to the agent) `Create a RabbitMQ producer and consumer for a notifications queue with durable=true`
**Pass:** Queue declaration properties (durable, exclusive, autoDelete) are identical in both producer and consumer code

### D12: Dockerfile for Ballerina project

**Prompt:** (to the agent) `Create a Dockerfile for this Ballerina project`
**Pass:** Uses `ballerina:troupe` ownership, builds in `/home/ballerina/app`, includes `.dockerignore`

### D13: Docker Compose with external services

**Prompt:** (to the agent) `Create a docker-compose.yml with this service and a RabbitMQ instance`
**Pass:** Config.toml uses Docker service names (e.g., `rabbitmq`), not `localhost`. No `version` key in compose file.

### D14: Retry consumer with backoff

**Prompt:** (to the agent) `Create a RabbitMQ consumer that retries failed messages`
**Pass:** Includes backoff mechanism (DLX with TTL, runtime:sleep, or retry count). No immediate nack+requeue loop.

### D15: Agent runs bal build after generation

**Prompt:** (to the agent) `Create a REST API that manages a list of books`
**Pass:** Agent runs `bal build` and shows output before reporting completion

---

## Scoring

| Rating | Smoke | Deep |
|--------|-------|------|
| **Pass** | 8/8 | 23/23 |
| **Acceptable** | 7/8 | 19/23 |
| **Needs work** | <7/8 | <19/23 |

Network-dependent tests (S2, S5, S6, D1, D3, D4) may be marked as SKIP if network is unavailable — do not count as failures.
