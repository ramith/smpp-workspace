import ballerina/http;
import ballerina/log;

# Represents the priority level of a task.
enum Priority {
    HIGH,
    MEDIUM,
    LOW
}

# Represents a task in the task manager.
#
# + id - Unique identifier for the task
# + title - Title of the task
# + description - Detailed description
# + priority - Priority level
# + completed - Whether the task is done
type Task record {|
    readonly int id;
    string title;
    string description;
    Priority priority;
    boolean completed;
|};

# Represents the payload for creating a new task.
type TaskRequest record {
    string title;
    string description;
    Priority priority;
};

# Represents an error response.
type ErrorResponse record {|
    string message;
|};

int nextId = 1;
table<Task> key(id) tasks = table [];

# Task manager service for managing tasks.
service /api on new http:Listener(9090) {

    # Retrieves all tasks.
    #
    # + return - List of all tasks
    resource function get tasks() returns Task[] {
        log:printInfo("Fetching all tasks");
        return tasks.toArray();
    }

    # Retrieves a task by ID.
    #
    # + id - The task ID
    # + return - The task or an error response
    resource function get tasks/[int id]() returns Task|http:NotFound {
        Task? task = tasks[id];
        if task is () {
            log:printWarn(string `Task not found: ${id}`);
            return http:NOT_FOUND;
        }
        return task;
    }

    # Creates a new task.
    #
    # + request - The task creation payload
    # + return - The created task or an error
    resource function post tasks(TaskRequest request) returns Task|http:BadRequest {
        if request.title.length() == 0 {
            log:printError("Task title cannot be empty");
            return http:BAD_REQUEST;
        }
        Task task = {
            id: nextId,
            title: request.title,
            description: request.description,
            priority: request.priority,
            completed: false
        };
        nextId += 1;
        tasks.add(task);
        log:printInfo(string `Task created: ${task.id}`);
        return task;
    }

    # Marks a task as completed.
    #
    # + id - The task ID
    # + return - The updated task or not found
    resource function put tasks/[int id]/complete() returns Task|http:NotFound {
        Task? existing = tasks[id];
        if existing is () {
            return http:NOT_FOUND;
        }
        Task updated = {
            id: existing.id,
            title: existing.title,
            description: existing.description,
            priority: existing.priority,
            completed: true
        };
        tasks.put(updated);
        log:printInfo(string `Task completed: ${id}`);
        return updated;
    }

    # Returns high-priority incomplete tasks.
    #
    # + return - Filtered list of urgent tasks
    resource function get tasks/urgent() returns Task[] {
        Task[] urgent = from Task t in tasks
            where t.priority == HIGH && !t.completed
            select t;
        return urgent;
    }
}
