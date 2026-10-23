# Ollama Monitor

A native macOS menu bar companion for monitoring and controlling a local [Ollama](https://ollama.com/) instance.

## Features

- Shows whether the configured Ollama server is responding and which models are loaded, using Ollama's `/api/ps` endpoint.
- Reads Ollama's server log to show recent activity, prompt and generation token counts, rates, and elapsed time.
- Displays system memory information. Available memory is estimated from macOS virtual memory statistics; GPU utilization is not reported.
- Unloads a selected loaded model.
- Starts, stops, or restarts the configured Ollama macOS app and reports whether its API responds afterward.
- Lets you configure the server URL, server log path, Ollama app name or path, and refresh interval.

Detailed activity depends on the configured server log being present and readable.

## Requirements

- macOS 13 or later
- Swift 5.9 or later to build
- A local Ollama server (the default address is `http://127.0.0.1:11434`)

## Build and run

From a Terminal:

```sh
git clone https://github.com/dlomneck/ollama-monitor.git
cd ollama-monitor
swift build -c release
.build/release/OllamaMonitor
```

Run the test suite with:

```sh
swift test
```

## Settings

Settings are saved automatically to:

```
~/Library/Application Support/OllamaMonitor/config.json
```

Defaults:

- Server URL: `http://127.0.0.1:11434`
- Server log: `~/.ollama/logs/server.log`
- Ollama app: `Ollama`
- Refresh interval: 0.5 seconds

The refresh interval can be set to 0.5, 1, 2, 3, or 5 seconds. Use the Settings window to adjust these values if your Ollama server or log is in a nonstandard location.

The Start, Stop, and Restart controls operate on the configured macOS Ollama app. Start opens the app; Stop sends a termination signal to its running app process. The monitor then checks the server API to confirm the resulting state.

## Downloads

There are no prebuilt downloads yet. For now, build from source using the instructions above. The repository's `build_release.sh` is a developer-oriented local release/install helper; it does not create a downloadable release package.

## License

A license has not been added yet.
