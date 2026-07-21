---
name: ballerina-by-example
description: Find and fetch Ballerina By Example code samples. Use when implementing an unfamiliar pattern or verifying the idiomatic way to do something in Ballerina.
allowed-tools: WebFetch
---

Find the relevant Ballerina By Example page and return the idiomatic implementation pattern.

## Strategy

1. Fetch the index at `https://ballerina.io/learn/by-example/` to locate the relevant example.
2. Fetch the specific example page for the complete code and explanation.
3. Return the key code snippet and any important notes — do not dump the entire page.
