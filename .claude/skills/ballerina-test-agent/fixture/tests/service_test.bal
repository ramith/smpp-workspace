import ballerina/http;
import ballerina/test;

http:Client testClient = check new ("http://localhost:9090/api");

@test:Config {}
function testGetEmptyTasks() returns error? {
    Task[] response = check testClient->/tasks;
    test:assertEquals(response.length(), 0, "Initial tasks should be empty");
}

@test:Config {
    dependsOn: [testGetEmptyTasks]
}
function testCreateTask() returns error? {
    Task response = check testClient->/tasks.post({
        title: "Test task",
        description: "A test task",
        priority: "HIGH"
    });
    test:assertEquals(response.title, "Test task");
    test:assertEquals(response.completed, false);
}

@test:Config {
    dependsOn: [testCreateTask]
}
function testGetTasks() returns error? {
    Task[] response = check testClient->/tasks;
    test:assertTrue(response.length() > 0, "Should have at least one task");
}
