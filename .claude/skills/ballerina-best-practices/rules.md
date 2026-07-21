# Ballerina Best Practices Rules

Source: https://learn-ballerina.github.io/

---

## 1. Project

### 1.1 Structure your code
- Use packages and modules for non-trivial projects — avoid putting everything in a single `.bal` file.
- Divide code into multiple `.bal` files based on logical components.
- Avoid excessive global state.

### 1.2 Naming conventions
- **Files**: `snake_case.bal` (e.g., `stock_quote_service.bal`)
- **Types/Records/Objects**: `PascalCase` (e.g., `Employee`)
- **Functions/Variables**: `lowerCamelCase` (e.g., `getEmployee`, `accountName`)
- **Constants**: `UPPER_SNAKE_CASE` (e.g., `MAX_SIZE`)
- **Packages/Modules**: lowercase with dots for hierarchy (e.g., `aws.s3`)
- **Abbreviations as words**: `hashMd5()` not `hashMD5()`, `LlmModel` not `LLMModel`
- **Clients**: reflect type, not redundant — `twilio:Client twilio` not `twilioClient`
- **REST paths**: lowercase with dashes, plural nouns — `/music-store`, `/albums/[string title]`

### 1.3 Format the code
- Use `bal format` to auto-format code.
- Import order: (1) same-package modules, (2) `ballerina/` and `ballerinax/`, (3) third-party — separated by blank lines, alphabetical within groups.

### 1.4 Logging
- Use `log:printInfo/Warn/Error/Debug` instead of `io:println` for diagnostics.
- Use string templates in log messages:
  ```ballerina
  // Bad
  log:printInfo("Started with delay " + delay.toString());
  // Good
  log:printInfo(string `Started with delay ${delay}`);
  ```
- Use key-value pairs: `log:printInfo("Started", delay = delay, timeout = timeout);`
- Use function pointers for expensive debug computations to avoid unnecessary evaluation.

### 1.5 Documentation
- Document all public constructs. End function descriptions with a period.
- Parameter/return docs: omit period if single sentence.
  ```ballerina
  # Checks if the user is valid.
  #
  # + username - The username to validate
  # + return - True if valid
  public function isValid(string username) returns boolean { }
  ```

### 1.6 Configuration management
- Never pass secrets through standard config — use separate TOML files via `BAL_CONFIG_FILES`.
- Add `Config.toml` to `.gitignore` if it contains secrets.
- Provide sensible defaults: `configurable int maxActiveConnections = -1;` not `= ?;`
- Use descriptive names: `maxActiveConnections` not `maxActive`.

### 1.7 Dependency management
- Test packages locally before publishing to Central (published packages cannot be deleted).
- Use `--offline --sticky` for reproducible builds with locked versions.
- Do not commit `Dependencies.toml` if you want latest versions auto-resolved.

---

## 2. Types & Values

### 2.1 Use precise types
- Prefer explicit types over `var`. Reserve `var` for limited-scope variables like `foreach`.
- Use application-defined record types instead of `json`, `any`, `anydata`.
  ```ballerina
  // Bad
  json albums = check httpClient->/albums;
  // Good
  type Album readonly & record {| string title; string artist; |};
  Album[] albums = check httpClient->/albums;
  ```

### 2.2 Represent optionality with nil
- Use `T?` with `()` default — never sentinel values like `""` or `-1`.
  ```ballerina
  // Bad
  type Employee record {| string middleName = ""; |};
  // Good
  type Employee record {| string? middleName = (); |};
  ```

### 2.3 Handle nil with Elvis operator
- Use `?:` for defaults instead of type casts or verbose `if` checks.
  ```ballerina
  // Bad
  int validAge = <int>age;
  // Good
  int validAge = age ?: 0;
  ```

### 2.4 Avoid unnecessary type casts
- Type casts panic on failure. Use `is` type narrowing or `value.ensureType()` instead.
  ```ballerina
  // Bad — panics if value is string
  return <int>value + 1;
  // Good — returns error instead
  return check value.ensureType(int) + 1;
  ```

### 2.5 Open vs closed records (Postel's Law)
- **Open records** for incoming/external data (tolerate extra fields).
- **Closed records** (`record {||}`) for outgoing/response data (strict contracts).

### 2.6 Simplify mapping constructors
- When variable name matches field name, use shorthand.
  ```ballerina
  // Bad
  Student s = {name: name, age: age, city: "London"};
  // Good
  Student s = {name, age, city: "London"};
  ```

### 2.7 Constants
- Omit the type — compiler infers it.
  ```ballerina
  // Bad
  const int MAX_SIZE = 1000;
  // Good
  const MAX_SIZE = 1000;
  ```

### 2.8 Constrain string values with enums
- Use `enum` (preferred), union of singletons, or union of constants — never bare `string`.
  ```ballerina
  // Bad
  type Employee record {| string department; |};
  // Good
  enum Department { Finance, Engineering, HR }
  type Employee record {| Department department; |};
  ```

### 2.9 Constrain integer values with constants
- Use named constants with union types for semantic clarity.
  ```ballerina
  // Bad
  type Issue record {| int priority; |};
  // Good
  const HIGH = 1; const MEDIUM = 2; const LOW = 3;
  type Priority HIGH|MEDIUM|LOW;
  type Issue record {| Priority priority; |};
  ```

---

## 3. Functions & Error Handling

### 3.1 Return errors and use check
- Never return sentinel values on failure. Include `error` in return type and use `check`.
  ```ballerina
  // Bad — loses error info, returns -1
  function getYear(int id) returns int { ... return -1; }
  // Good — propagates error
  function getYear(int id) returns int|error {
      string name = check getName(id);
      return getYear(name);
  }
  ```

### 3.2 Avoid unnecessary panic
- Reserve `panic`/`checkpanic` for programming bugs only (division by zero, OOM).
- Business logic errors must be returned as `error` values, never panicked.

### 3.3 Expression-bodied functions
- Use `=>` when the body is a single return statement.
  ```ballerina
  // Bad
  function isValid(string name) returns boolean { return check(name) && available(name); }
  // Good
  function isValid(string name) returns boolean => check(name) && available(name);
  ```

### 3.4 Included record parameters
- Use `*Record` syntax so callers can pass fields as named arguments.
  ```ballerina
  // Enables: register(admissionYear = 2023, firstName = "John", age = 14)
  function register(int admissionYear, *Student student) { }
  ```

### 3.5 Use tuples to return multiple values
- Prefer tuples over single-use wrapper records for returning multiple values.
  ```ballerina
  function getData() returns [int, string, float] => [1, "Product", 10.0];
  var [id, name, price] = getData();
  ```

---

## 4. Control Flow & Iteration

### 4.1 Early returns
- Use early returns to avoid nested `if` blocks. Exception: if both branches have similar logic, don't return early.

### 4.2 No parentheses in if
- Ballerina requires braces but not parentheses around conditions.
  ```ballerina
  // Bad
  if (x == 0) { }
  // Good
  if x == 0 { }
  ```

### 4.3 Use match for fixed values
- Use `match` instead of chained `if-else` when comparing against constant values.

### 4.4 Query expressions over loops
- Replace verbose `foreach` + filter + push patterns with query expressions.
  ```ballerina
  // Good
  Country[] summary = from var {country, population, cases, deaths} in data
      where population > 5000 && cases > 100
      let decimal ratio = <decimal>deaths / <decimal>cases * 100
      order by ratio descending
      limit 3
      select {name: country, population, caseFatalityRatio: ratio};
  ```

### 4.5 Value ranges in foreach
- Use range expressions instead of manual index tracking.
  ```ballerina
  // Bad — manual index + skip logic
  // Good
  foreach int i in 1 ..< data.length() { io:println(data[i]); }
  ```

---

## 5. Style & Hygiene

### 5.1 Avoid unnecessary objects
- Ballerina is data-oriented. Don't wrap logic in classes when a service or module-level function suffices.

### 5.2 Avoid redundant variables
- Don't create a variable used only once before returning. Return the value directly.
  ```ballerina
  // Bad
  Employee emp = {name, age}; return emp;
  // Good
  return {name, age};
  ```

### 5.3 String templates over concatenation
- Use backtick templates with `${}` interpolation — handles type conversion automatically.
  ```ballerina
  // Bad
  "Name is " + name + " age is " + age.toString()
  // Good
  string `Name is ${name} age is ${age}`
  ```

### 5.4 Avoid unnecessary comments
- Don't duplicate what the code says. Write self-explanatory code instead.

### 5.5 Wrap at 120 characters
- Break long lines strategically. Refactor if a single statement is too complex.

### 5.6 Commit messages
- 50 char limit, capitalize, imperative mood, no trailing period.
- Good: `Fix XML record generation when multiple namespaces exist`
- Bad: `Implementing XML to record converter`

---

## 6. Messaging & Integration

### 6.1 Consistent queue/topic declarations
- When a producer declares a queue/topic with specific properties (durable, exclusive, autoDelete), every consumer/listener touching the same queue must use identical properties.
- Mismatched declarations cause `PRECONDITION_FAILED` errors at runtime.
- Prefer declaring the queue once in a shared initialization function and referencing it from both producer and consumer.

### 6.2 Retry backoff for message consumers
- `basicNack` with `requeue = true` delivers the message back immediately — this creates a hot retry loop that wastes resources and hammers downstream services.
- Use a dead-letter exchange (DLX) with TTL to introduce delay between retries.
- Track retry count in message headers and move to a dead-letter queue after max attempts.
