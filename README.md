# PS-TaskFile

A PowerShell task runner that uses YAML-based task definitions, similar to Taskfile and Make.

## Features

- 📝 YAML-based task definitions
- 🔄 Task dependencies with automatic resolution
- 📊 Variable support (static and dynamic)
- 🎯 Interactive mode for command confirmation
- 🔍 Dry-run mode for previewing commands
- 📁 Directory context support per task
- 🚀 Simple and intuitive command-line interface

## Installation

### Prerequisites

The module requires the `powershell-yaml` module, which will be automatically installed if not present.

### Install from Source

```powershell
# Clone the repository
git clone https://github.com/rabitarochan/PS-TaskFile.git
cd PS-TaskFile

# Import the module
Import-Module ./src/PS-TaskFile/PS-TaskFile.psd1 -Force
```

## Quick Start

### 1. Create a Taskfile

Create a `tasks.yaml` file in your project root:

```yaml
vars:
  project_name: "MyProject"
  build_config: "Release"
  timestamp:
    cmd: Get-Date -Format "yyyy-MM-dd HH:mm:ss"

tasks:
  default:
    desc: "Default task"
    depends_on:
      - build
      - test

  clean:
    desc: "Clean build artifacts"
    cmds:
      - Remove-Item -Path "./bin" -Recurse -Force -ErrorAction SilentlyContinue
      - Remove-Item -Path "./obj" -Recurse -Force -ErrorAction SilentlyContinue
      - Write-Host "Cleaned build artifacts"

  build:
    desc: "Build the project"
    depends_on:
      - clean
    cmds:
      - Write-Host "Building $project_name in $build_config mode..."
      - dotnet build --configuration $build_config
      - Write-Host "Build completed at $timestamp"

  test:
    desc: "Run tests"
    cmds:
      - Write-Host "Running tests..."
      - dotnet test --no-build --configuration $build_config

  deploy:
    desc: "Deploy the application"
    depends_on:
      - build
      - test
    dir: "./src"
    cmds:
      - Write-Host "Deploying application..."
      - # Your deployment commands here
```

### 2. Run Tasks

```powershell
# List all available tasks
Invoke-TaskFile -List

# Run the default task
Invoke-TaskFile

# Run a specific task
Invoke-TaskFile build

# Run multiple tasks
Invoke-TaskFile clean,build,test
```

## Command Reference

### Invoke-TaskFile

The main command to execute tasks from a Taskfile.

#### Syntax

```powershell
Invoke-TaskFile [[-TaskNames] <string[]>]
                [-List]
                [-File <string>]
                [-DryRun]
                [-Interactive]
                [-Var <string[]>]
```

#### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `TaskNames` | Name(s) of tasks to execute | `default` task if exists |
| `-List` | List all available tasks | - |
| `-File` | Path to the Taskfile | `tasks.yaml` |
| `-DryRun` | Preview commands without executing | `$false` |
| `-Interactive` | Prompt before each command execution | `$false` |
| `-Var` | Override variables (format: `name=value`) | - |

#### Examples

```powershell
# List all tasks
Invoke-TaskFile -List

# Run default task
Invoke-TaskFile

# Run specific task
Invoke-TaskFile build

# Run with dry-run to preview
Invoke-TaskFile deploy -DryRun

# Run with interactive mode
Invoke-TaskFile build -Interactive

# Override variables
Invoke-TaskFile build -Var build_config=Debug

# Use a different taskfile
Invoke-TaskFile -File custom-tasks.yaml build

# Run multiple tasks in sequence
Invoke-TaskFile clean,build,test
```

## Taskfile Schema

### Structure

```yaml
vars:
  # Static variables
  variable_name: "value"

  # Dynamic variables (executed at runtime)
  dynamic_var:
    cmd: PowerShell-Command

tasks:
  task_name:
    desc: "Task description"
    dir: "Working directory for this task"
    depends_on:
      - dependency1
      - dependency2
    cmds:
      - Command 1
      - Command 2
      - task: another_task  # Call another task
```

### Variables

Variables can be defined in the `vars` section and used throughout the taskfile with `$variable_name` syntax.

#### Static Variables

```yaml
vars:
  app_name: "MyApp"
  version: "1.0.0"
```

#### Dynamic Variables

Dynamic variables execute PowerShell commands at runtime:

```yaml
vars:
  current_time:
    cmd: Get-Date -Format "HH:mm:ss"
  git_branch:
    cmd: git branch --show-current
```

### Task Dependencies

Tasks can depend on other tasks using the `depends_on` field:

```yaml
tasks:
  deploy:
    desc: "Deploy application"
    depends_on:
      - test
      - build
    cmds:
      - # deployment commands

  build:
    desc: "Build application"
    depends_on:
      - clean
    cmds:
      - # build commands

  clean:
    desc: "Clean artifacts"
    cmds:
      - # clean commands

  test:
    desc: "Run tests"
    depends_on:
      - build
    cmds:
      - # test commands
```

The dependency resolution automatically handles the correct execution order and prevents circular dependencies.

### Working Directory

Each task can specify its own working directory:

```yaml
tasks:
  frontend:
    desc: "Build frontend"
    dir: "./src/frontend"
    cmds:
      - npm install
      - npm run build

  backend:
    desc: "Build backend"
    dir: "./src/backend"
    cmds:
      - dotnet restore
      - dotnet build
```

## Advanced Examples

### Development Workflow

```yaml
vars:
  solution: "MyApp.sln"
  test_project: "./tests/MyApp.Tests"

tasks:
  dev:
    desc: "Start development environment"
    cmds:
      - task: watch

  watch:
    desc: "Watch for file changes"
    cmds:
      - dotnet watch run

  format:
    desc: "Format code"
    cmds:
      - dotnet format $solution

  lint:
    desc: "Run linter"
    cmds:
      - # Your linting commands

  ci:
    desc: "Continuous Integration pipeline"
    depends_on:
      - format
      - lint
      - build
      - test
```

### Docker Operations

```yaml
vars:
  image_name: "myapp"
  tag: "latest"
  container_name: "myapp-container"

tasks:
  docker-build:
    desc: "Build Docker image"
    cmds:
      - docker build -t ${image_name}:${tag} .

  docker-run:
    desc: "Run Docker container"
    depends_on:
      - docker-build
    cmds:
      - docker run -d --name $container_name ${image_name}:${tag}

  docker-stop:
    desc: "Stop Docker container"
    cmds:
      - docker stop $container_name
      - docker rm $container_name

  docker-logs:
    desc: "Show container logs"
    cmds:
      - docker logs -f $container_name
```

### Git Operations

```yaml
vars:
  branch:
    cmd: git branch --show-current
  commit_msg: "Auto-commit"

tasks:
  git-status:
    desc: "Show git status"
    cmds:
      - git status

  git-commit:
    desc: "Commit changes"
    cmds:
      - git add .
      - git commit -m "$commit_msg"

  git-push:
    desc: "Push to remote"
    depends_on:
      - git-commit
    cmds:
      - git push origin $branch

  git-sync:
    desc: "Sync with remote"
    cmds:
      - git fetch origin
      - git pull origin $branch
```

## Tips and Best Practices

1. **Use descriptive task names**: Make task names self-explanatory
2. **Add descriptions**: Always include `desc` field for documentation
3. **Leverage dependencies**: Use `depends_on` to create logical workflows
4. **Use variables**: Define common values as variables for reusability
5. **Test with dry-run**: Use `-DryRun` to verify task execution order
6. **Interactive mode for dangerous operations**: Use `-Interactive` for tasks that modify important files

## Troubleshooting

### Module not found

If you get an error about the module not being found:

```powershell
# Make sure you're in the correct directory
cd PS-TaskFile

# Import with full path
Import-Module "$PWD/src/PS-TaskFile/PS-TaskFile.psd1" -Force
```

### powershell-yaml not installed

The module will attempt to install `powershell-yaml` automatically. If this fails:

```powershell
# Install manually
Install-Module -Name powershell-yaml -Force -Scope CurrentUser
```

### Task not found

If a task is not found, use `-List` to see all available tasks:

```powershell
Invoke-TaskFile -List
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Inspired by [Taskfile](https://taskfile.dev/) and GNU Make
- Built with PowerShell and powershell-yaml
