---
name: ballerina-spec-lookup
description: Look up Ballerina language specification details. Use when uncertain about type system, expression/statement semantics, concurrency, module resolution, or any language behavior edge case.
allowed-tools: WebFetch
---

Fetch the relevant section from the Ballerina Language Specification to answer the user's question accurately.

## Strategy

1. Fetch `https://ballerina.io/spec/lang/master/` with a targeted prompt for the specific section needed (e.g., "Extract the section on error handling and check expressions").
2. Extract the relevant rules, constraints, or semantics.
3. Summarize concisely — quote the spec where precision matters, paraphrase where it doesn't.
