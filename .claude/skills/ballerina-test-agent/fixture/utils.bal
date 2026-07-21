// BAD PRACTICE FILE — intentional violations for testing /ballerina-best-practices skill.
// This file compiles but violates 10+ rules from rules.md.

import ballerina/io;

// Violation 1.2: Type name should be PascalCase, not lowerCamelCase
type employeeRecord record {|
    string name;
    int age;
    // Violation 2.8: Bare string where enum should be used
    string department;
|};

// Violation 2.7: Redundant type annotation on constant
const int MAX_RETRIES = 3;

// Violation 2.2: Sentinel value instead of nil for optional field
type userProfile record {|
    string username;
    string middleName = "";
    int age;
|};

// Violation 1.5: Missing documentation on public function
public function formatEmployee(employeeRecord emp) returns string {
    // Violation 2.1: Using var instead of explicit type
    var name = emp.name;
    var age = emp.age;

    // Violation 5.3: String concatenation instead of template
    string result = "Employee: " + name + ", Age: " + age.toString() + ", Dept: " + emp.department;

    // Violation 1.4: Using io:println instead of log module
    io:println("Formatted employee: " + name);

    return result;
}

// Violation 1.5: Missing documentation on public function
public function getEmployeeSummary(employeeRecord emp) returns string {
    // Violation 4.2: Parentheses in if statement
    if (emp.age > 60) {
        return "Senior";
    }

    // Violation 5.2: Redundant variable before return
    string summary = "Active";
    return summary;
}
