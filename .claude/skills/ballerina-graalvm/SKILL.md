---
name: ballerina-graalvm
description: Build and run Ballerina GraalVM native executables locally or in a Docker container. Use when the user wants native image compilation, faster startup, or smaller container images for Ballerina projects.
allowed-tools: Read Write Edit Bash Glob Grep
---

Help the user build a GraalVM native executable from their Ballerina project. Ask which approach they prefer if not specified: **local** or **container (Docker)**.

## IMPORTANT: Ask before building

GraalVM native image builds are **resource-intensive** (high memory + CPU) and **time-consuming** (minutes to tens of minutes). **Always inform the user and get explicit consent before running `bal build --graalvm`.**

When the build is part of a larger setup (e.g., Docker Compose, CI pipeline):
- **Generate the configuration files first** (Dockerfile, docker-compose.yml, CI config) without running the build.
- Let the user trigger the build themselves or through the composed tooling (e.g., `docker compose build` will run the GraalVM build inside the container naturally).
- Do not eagerly run `bal build --graalvm` when the user's intent is to set up infrastructure — configure first, build later.

If a build is running, provide **periodic status updates** since it takes significant time.

## Prerequisites

| Requirement | Local | Container |
|-------------|-------|-----------|
| Ballerina Swan Lake (latest) | Yes | Yes |
| GraalVM (Java 21 for Update 11+) | Yes | No (built inside container) |
| `GRAALVM_HOME` or `JAVA_HOME` set | Yes | No |
| Docker (8GB+ memory recommended) | No | Yes |

Install GraalVM locally via SDKMAN!: `sdk install java 21.0.2-graalce` (latest JDK 21 CE is 21.0.2, not 21.0.6 — verify at graalvm/graalvm-ce-builds releases)

## Workflow A: Build Locally

1. Verify GraalVM is installed: `java -version` (should show GraalVM).
2. **Ask the user for consent** — inform them the build will be resource-intensive.
3. Build: `bal build --graalvm`
4. Run: `./target/bin/<project-name>`
5. If build warns about incompatible packages, run tests against native image: `bal test --graalvm`

## Workflow B: Build in Docker Container

1. Verify Docker is running and has 8GB+ memory allocated.
2. Run `bal build --graalvm --cloud=docker` to **generate the Dockerfile** (multi-stage: GraalVM build -> distroless runtime).
3. If the user needs docker-compose or other infrastructure, **create those files first** — the GraalVM build happens naturally when `docker compose build` runs.
4. Run: `docker run -d -p <port>:<port> <project-name>:latest`

### Docker gotchas (known issues)

- **`ghcr.io/ballerina-platform/ballerina` returns 403** — use `ballerina/ballerina` from Docker Hub, or use the GraalVM base with Ballerina zip.
- **`ballerina/ballerina` is Alpine (musl)** — GraalVM CE binaries are glibc-based. Installing GraalVM into this image causes `Unable to load jimage library` errors. Do NOT mix them.
- **Recommended Dockerfile strategy**: Use `ghcr.io/graalvm/native-image-community:21` (Oracle Linux, glibc) as build stage, install Ballerina via the platform-independent zip from GitHub releases.
- **Ballerina download URLs**: `dist.ballerina.io` returns 403. Use GitHub releases instead: `https://github.com/ballerina-platform/ballerina-distribution/releases/download/v{version}/ballerina-{version}-swan-lake.zip`
- **No aarch64 .rpm/.deb for Ballerina** — the platform-independent `.zip` works on all architectures (JVM-based).
- **`ballerina/ballerina` runs as non-root** — use `USER root` before installing to `/opt` or system dirs.
- **`docker-compose.yml` `version` key is obsolete** — modern Docker Compose ignores it. Omit it.

## GraalVM Build Options

Pass options via CLI or `Ballerina.toml`:

**CLI:**
```
bal build --graalvm --graalvm-build-options="-H:+StaticExecutableWithDynamicLibC"
```

**Ballerina.toml:**
```toml
[build-options]
graalvmBuildOptions = "--verbose -H:+StaticExecutableWithDynamicLibC"
```

## Marking Library Packages as GraalVM-Compatible

Add to `Ballerina.toml`:
```toml
[platform.java21]
graalvmCompatible = true
```

## Limitations

- Native image builds are resource-intensive (high memory + CPU, long build times).
- Code coverage and runtime debug are not supported with GraalVM native image testing.
- Apple M1 (darwin-aarch64) support is experimental.
- Windows requires Visual Studio with MSVC.

## Reference

Full docs: https://ballerina.io/learn/graalvm-executable-overview/
