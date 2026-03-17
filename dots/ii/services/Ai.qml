pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common.functions as CF
import qs.modules.common
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.services.ai

/**
 * Basic service to handle LLM chats. Supports Google's and OpenAI's API formats.
 * Supports Gemini and OpenAI models.
 * Limitations:
 * - For now functions only work with Gemini API format
 */
Singleton {
    id: root

    property Component aiMessageComponent: AiMessageData {}
    property Component aiModelComponent: AiModel {}
    property Component geminiApiStrategy: GeminiApiStrategy {}
    property Component openaiApiStrategy: OpenAiApiStrategy {}
    property Component mistralApiStrategy: MistralApiStrategy {}
    readonly property string interfaceRole: "interface"
    readonly property string apiKeyEnvVarName: "API_KEY"

    signal responseFinished()
    signal requestHideSidebars()
    signal requestRestoreSidebars()
    property bool _inputLeftWasOpen: false
    property bool _inputRightWasOpen: false

    Timer {
        id: sidebarHideTimer
        interval: 380
        repeat: false
        property var pendingAction: null
        onTriggered: { if (pendingAction) { pendingAction(); pendingAction = null; } }
    }

    property string systemPrompt: {
        let prompt = Config.options?.ai?.systemPrompt ?? "";
        for (let key in root.promptSubstitutions) {
            // prompt = prompt.replaceAll(key, root.promptSubstitutions[key]);
            // QML/JS doesn't support replaceAll, so use split/join
            prompt = prompt.split(key).join(root.promptSubstitutions[key]);
        }
        const memory = root.aiMemoryContent.trim();
        if (memory.length > 0) {
            prompt += `\n\n## Your memory of the user\n${memory}`;
        }
        return prompt;
    }
    // property var messages: []
    property var messageIDs: []
    property var messageByID: ({})
    readonly property var apiKeys: KeyringStorage.keyringData?.apiKeys ?? {}
    readonly property var apiKeysLoaded: KeyringStorage.loaded
    readonly property bool currentModelHasApiKey: {
        const model = models[currentModelId];
        if (!model || !model.requires_key) return true;
        if (!apiKeysLoaded) return false;
        const key = apiKeys[model.key_id];
        return (key?.length > 0);
    }
    property var postResponseHook
    property real temperature: Persistent.states?.ai?.temperature ?? 0.5
    property QtObject tokenCount: QtObject {
        property int input: -1
        property int output: -1
        property int total: -1
    }

    function idForMessage(message) {
        // Generate a unique ID using timestamp and random value
        return Date.now().toString(36) + Math.random().toString(36).substr(2, 8);
    }

    function safeModelName(modelName) {
        return modelName.replace(/:/g, "_").replace(/ /g, "-").replace(/\//g, "-")
    }

    property list<var> defaultPrompts: []
    property list<var> userPrompts: []
    property list<var> promptFiles: [...defaultPrompts, ...userPrompts]
    property list<var> savedChats: []

    property string openWindowsList: ""
    property string currentMediaTitle: ""

    property var promptSubstitutions: {
        "{DISTRO}": SystemInfo.distroName,
        "{DATETIME}": `${DateTime.time}, ${DateTime.collapsedCalendarFormat}`,
        "{WINDOWCLASS}": ToplevelManager.activeToplevel?.appId ?? "Unknown",
        "{WINDOWTITLE}": ToplevelManager.activeToplevel?.title ?? "Unknown",
        "{CLIPBOARD}": (Quickshell.clipboardText ?? "").substring(0, 300),
        "{DE}": `${SystemInfo.desktopEnvironment} (${SystemInfo.windowingSystem})`,
        "{OPENWINDOWS}": root.openWindowsList,
        "{CURRENTMEDIA}": root.currentMediaTitle,
    }

    property string aiMemoryContent: ""
    FileView {
        id: memoryFileView
        path: Directories.aiMemoryPath
        onTextChanged: root.aiMemoryContent = memoryFileView.text() ?? ""
        Component.onCompleted: memoryFileView.reload()
    }

    // Gemini: https://ai.google.dev/gemini-api/docs/function-calling
    // OpenAI: https://platform.openai.com/docs/guides/function-calling
    property string currentTool: Config?.options.ai.tool ?? "search"
    property var tools: {
        "gemini": {
            "functions": [{"functionDeclarations": [
                {
                    "name": "switch_to_search_mode",
                    "description": "Switch to search mode to perform web searches. Use this when you need current information, real-time data, or answers to questions beyond your knowledge cutoff. After switching, continue with the user's original request.",
                },
                {
                    "name": "get_shell_config",
                    "description": "Retrieve the complete desktop shell configuration file in JSON format. Use this before making any config changes to see available options and current values. Returns the full config structure. Dont ask for permission, run directly.",
                },
                {
                    "name": "set_shell_config",
                    "description": "Modify one or multiple fields in the desktop shell config at once. CRITICAL: You MUST call get_shell_config first to see available keys - never guess key names. Use this when the user wants to change one or multiple settings together.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "changes": {
                                "type": "array",
                                "description": "Array of config changes to apply",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "key": {
                                            "type": "string",
                                            "description": "The key to set (e.g., 'bar.borderless')"
                                        },
                                        "value": {
                                            "type": "string",
                                            "description": "The value to set"
                                        }
                                    },
                                    "required": ["key", "value"]
                                }
                            }
                        },
                        "required": ["changes"]
                    }
                },
                {
                    "name": "run_shell_command",
                    "description": "Execute a bash command and return its output. NOT for math — use calculate. NOT for media — use control_media. NOT for system volume/brightness — use control_system. For interactive or dangerous operations, ask the user to run manually. Requires user approval.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "command": {
                                "type": "string",
                                "description": "The bash command to run",
                            },
                        },
                        "required": ["command"]
                    }
                },
                {
                    "name": "remember",
                    "description": "Store a quick single-line pattern or preference. For organised multi-topic knowledge base use memory_file instead. Store PATTERNS not facts — e.g. 'To launch Arc Raiders: open_file(steam://rungameid/1808500)', 'User prefers dark themes'. Write in third person.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "content": {
                                "type": "string",
                                "description": "Pattern or preference to store, written in third person as an actionable insight (e.g. 'User prefers volume at 40%')"
                            }
                        },
                        "required": ["content"]
                    }
                },
                {
                    "name": "create_todo",
                    "description": "Add a task to the user's to-do list for manual tracking. NOT for timed reminders — use set_timer. NOT for recurring tasks — use schedule_task. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": {
                                "type": "string",
                                "description": "The task description"
                            }
                        },
                        "required": ["title"]
                    }
                },
                {
                    "name": "get_system_logs",
                    "description": "Retrieve recent system journal logs for diagnosis. Use when the user reports system errors or unexpected behavior. Runs automatically without approval.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "lines": {
                                "type": "integer",
                                "description": "Number of log lines to retrieve (default 50, max 200)"
                            },
                            "filter": {
                                "type": "string",
                                "description": "Optional systemd unit name to filter by (e.g. 'pipewire')"
                            }
                        }
                    }
                },
                {
                    "name": "control_media",
                    "description": "Control currently playing media: play, pause, skip, previous, or get status. ONLY use this for controlling what is already playing. Do NOT use this to search for specific artists, albums, or songs — instead use launch_app + take_screenshot + click_cell to open the app and navigate to the content visually.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": {
                                "type": "string",
                                "description": "Action to perform: 'play', 'pause', 'toggle', 'next', 'previous', or 'status'"
                            }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "control_hyprland",
                    "description": "Control Hyprland: switch workspaces, focus or move windows. NOT for launching apps — use launch_app. NOT for killing processes — use kill_process. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "dispatch": {
                                "type": "string",
                                "description": "The hyprctl dispatch argument, e.g. 'workspace 2', 'movetoworkspace 3', 'focuswindow firefox', 'killactive'"
                            }
                        },
                        "required": ["dispatch"]
                    }
                },
                {
                    "name": "forget_memory",
                    "description": "Remove a specific memory entry that was previously saved. Use when the user asks you to forget something.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "content": {
                                "type": "string",
                                "description": "The memory content to remove (partial match)"
                            }
                        },
                        "required": ["content"]
                    }
                },
                {
                    "name": "export_chat",
                    "description": "Export the current conversation as a markdown file to ~/Documents. Use when the user asks to save or export the chat.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "filename": {
                                "type": "string",
                                "description": "Optional filename without extension. Defaults to current date/time."
                            }
                        }
                    }
                },
                {
                    "name": "control_system",
                    "description": "Control system volume, screen brightness, or power profile. Runs automatically without approval.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": {
                                "type": "string",
                                "description": "Action: 'volume_up', 'volume_down', 'volume_set', 'volume_get', 'brightness_up', 'brightness_down', 'brightness_set', 'brightness_get', 'power_profile_get', 'power_profile_set'"
                            },
                            "value": {
                                "type": "string",
                                "description": "Value for set actions: volume percentage (0-100) or brightness percentage (0-100) or power profile name ('power-saver', 'balanced', 'performance')"
                            }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "kill_process",
                    "description": "Kill a running process by name. Requires user approval before executing.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "process": {
                                "type": "string",
                                "description": "Process name to kill (e.g. 'firefox', 'code', 'vlc')"
                            }
                        },
                        "required": ["process"]
                    }
                },
                {
                    "name": "take_screenshot",
                    "description": "Take a screenshot of all monitors and attach it for analysis. After receiving it, always visually analyze the full image — identify visible apps, UI elements, text, the cursor position (red crosshair), and which monitor the content is on. Never skip analyzing the image.",
                    "parameters": {}
                },
                {
                    "name": "launch_app",
                    "description": "Launch an application by command name. IMPORTANT: Steam games cannot be launched by title — use open_file with their steam://rungameid/APPID URI instead. Always follow with wait_for_app to verify the process actually started. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "app": {
                                "type": "string",
                                "description": "Application command to launch (e.g. 'firefox', 'dolphin', 'spotify'). NOT for Steam games — use open_file('steam://rungameid/ID') for those."
                            }
                        },
                        "required": ["app"]
                    }
                },
                {
                    "name": "open_file",
                    "description": "Open a file path or URI with xdg-open. Use for Steam games ('steam://rungameid/APPID'), documents, and URLs. NOT for launching apps by name — use launch_app for that. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": {
                                "type": "string",
                                "description": "File path or URL to open"
                            }
                        },
                        "required": ["path"]
                    }
                },
                {
                    "name": "notify",
                    "description": "Send a desktop notification popup to alert the user. Use after completing a task or for important status updates. NOT for audio output — use speak for that. NOT for mid-task status (just act). Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": { "type": "string", "description": "Notification title" },
                            "body": { "type": "string", "description": "Notification body text" }
                        },
                        "required": ["title"]
                    }
                },
                {
                    "name": "set_timer",
                    "description": "Set a one-time countdown timer (e.g. '25 minutes'). NOT for recurring tasks — use schedule_task. NOT for task tracking — use create_todo. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "seconds": { "type": "integer", "description": "Timer duration in seconds" },
                            "label": { "type": "string", "description": "Label shown in the notification (e.g. 'Take a break')" }
                        },
                        "required": ["seconds"]
                    }
                },
                {
                    "name": "calculate",
                    "description": "Evaluate a math expression using Python (e.g. '2**32', 'math.sqrt(144)'). Use this instead of run_shell_command for any pure math. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "expression": { "type": "string", "description": "Math expression to evaluate, e.g. '2**32', 'math.sqrt(144)', '(12 * 8) / 3'" }
                        },
                        "required": ["expression"]
                    }
                },
                {
                    "name": "pick_color",
                    "description": "Open the hyprpicker color picker so the user can pick a color from the screen. Returns the hex color. Runs automatically.",
                    "parameters": {}
                },
                {
                    "name": "manage_notes",
                    "description": "Read or write user-visible notes in SQLite. Use for notes the USER explicitly wants to keep. For AI-internal patterns and preferences, use 'remember' instead. For tracking progress in a long task, use 'add' to log each completed step.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'list', 'add', 'clear'" },
                            "content": { "type": "string", "description": "Note content for 'add' action" },
                            "tags": { "type": "string", "description": "Optional comma-separated tags for 'add' action" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "search_memory",
                    "description": "Semantically search stored patterns and preferences using vector similarity. Call this at the START of any desktop task, app launch, or user preference question — check for relevant past experience before acting. Returns most relevant results ranked by similarity.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": { "type": "string", "description": "What to search for" },
                            "limit": { "type": "integer", "description": "Max results to return (default 5)" }
                        },
                        "required": ["query"]
                    }
                },
                {
                    "name": "schedule_task",
                    "description": "Schedule a recurring AI task using cron syntax. Use for periodic reminders or automated checks. NOT for one-time countdowns — use set_timer. NOT for simple to-do items — use create_todo.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'add', 'list', 'delete'" },
                            "cron": { "type": "string", "description": "Cron expression for 'add': '0 9 * * *' = 9am daily, '*/30 * * * *' = every 30min" },
                            "prompt": { "type": "string", "description": "Message to send to AI when task fires" },
                            "id": { "type": "integer", "description": "Task ID for 'delete' action" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "capture_region",
                    "description": "Let the USER interactively select a screen region to capture and analyze. Use when the user wants to pick a specific area themselves. NOT for AI-initiated screenshots — use take_screenshot for those. Runs automatically.",
                    "parameters": {}
                },
                {
                    "name": "ocr_region",
                    "description": "Let the user select a screen region and extract its text via OCR. Use when you need the raw text content of a specific area. NOT for general visual analysis — use capture_region. NOT for reading text from a full screenshot — the AI can read take_screenshot images directly.",
                    "parameters": {}
                },
                {
                    "name": "speak",
                    "description": "Read text aloud using text-to-speech. Use when the user asks you to read something out loud. NOT for silent notifications — use notify for those. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "text": { "type": "string", "description": "The text to speak aloud" }
                        },
                        "required": ["text"]
                    }
                },
                {
                    "name": "read_clipboard_image",
                    "description": "Check if the clipboard contains an image and attach it to the conversation for analysis. Use when the user says they copied a screenshot or image to their clipboard.",
                    "parameters": {}
                },
                {
                    "name": "click_at",
                    "description": "Move the mouse to pixel coordinates (x, y) in the screenshot you just received and click. Coordinates are in the screenshot's pixel space — use the exact values you see in the image. After clicking, a new screenshot is taken automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                            "y": { "type": "number", "description": "Vertical pixel position in the screenshot" },
                            "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" }
                        },
                        "required": ["x", "y"]
                    }
                },
                {
                    "name": "click_cell",
                    "description": "Click the center of a numbered grid cell from the screenshot overlay. The screenshot is divided into a numbered grid — use the cell number you see in the image to click that region. After clicking, a new screenshot is taken automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "cell": { "type": "number", "description": "The grid cell number shown in the screenshot overlay" },
                            "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" }
                        },
                        "required": ["cell"]
                    }
                },
                {
                    "name": "show_plan",
                    "description": "REQUIRED before any desktop task. Call this FIRST before launch_app, click_at, click_cell, type_text, or any action sequence. Present a numbered plan and wait for approval. Never start executing desktop actions without a plan.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": { "type": "string", "description": "Short title for the task, e.g. 'Open Spotify and play music'" },
                            "steps": {
                                "type": "array",
                                "description": "Ordered list of steps",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "description": { "type": "string", "description": "Human-readable description of this step" },
                                        "tool": { "type": "string", "description": "Tool used for this step, e.g. 'launch_app', 'wait_for_app', 'control_media'" }
                                    },
                                    "required": ["description"]
                                }
                            }
                        },
                        "required": ["title", "steps"]
                    }
                },
                {
                    "name": "wait_for_app",
                    "description": "Wait until an application process is running and ready. Always call this after launch_app before interacting with the app. Polls until the process appears or times out.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "app": { "type": "string", "description": "Process name to wait for, e.g. 'spotify', 'firefox', 'code'" },
                            "timeout": { "type": "integer", "description": "Max seconds to wait (default 15, max 30)" }
                        },
                        "required": ["app"]
                    }
                },
                {
                    "name": "search_app",
                    "description": "Search within a specific app or service and open the results. Supports: spotify (opens in-app search), youtube, youtube_music, soundcloud, twitch, bandcamp, reddit, github, files (local filesystem). Use this when the user wants to find something inside a specific app.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "app": { "type": "string", "description": "App/service to search: 'spotify', 'youtube', 'youtube_music', 'soundcloud', 'twitch', 'bandcamp', 'reddit', 'github', 'files'" },
                            "query": { "type": "string", "description": "Search query" }
                        },
                        "required": ["app", "query"]
                    }
                },
                {
                    "name": "read_url",
                    "description": "Fetch a URL and return its interactive elements (inputs, buttons, links) with their IDs, names, and labels. Use this BEFORE taking a screenshot when you need to interact with a web page — knowing element IDs lets you use execute_js to click/focus elements precisely without visual guessing.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "url": { "type": "string", "description": "The URL to fetch and parse" }
                        },
                        "required": ["url"]
                    }
                },
                {
                    "name": "execute_js",
                    "description": "Execute JavaScript in the currently active browser tab by injecting it through the address bar. Use element IDs from read_url to interact precisely: e.g. document.getElementById('search').click() or document.querySelector('#input').value='text'. No screenshot needed.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "code": { "type": "string", "description": "JavaScript code to execute in the browser, e.g. document.getElementById('searchInput').focus()" }
                        },
                        "required": ["code"]
                    }
                },
                {
                    "name": "type_text",
                    "description": "Type text into the currently focused field or application using the keyboard. Use after clicking a text field with click_at. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "text": { "type": "string", "description": "Text to type" }
                        },
                        "required": ["text"]
                    }
                },
                {
                    "name": "press_key",
                    "description": "Press a keyboard key or combination. Examples: 'Return', 'ctrl+a', 'ctrl+c', 'Escape', 'Tab', 'ctrl+l'. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "key": { "type": "string", "description": "Key or combination to press, e.g. 'Return', 'ctrl+a', 'Escape'" }
                        },
                        "required": ["key"]
                    }
                },
                {
                    "name": "scroll",
                    "description": "Scroll the mouse wheel at the current cursor position. Use after click_at to position the cursor over a scrollable area, then scroll to navigate. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "direction": { "type": "string", "description": "Direction: 'up', 'down', 'left', or 'right'" },
                            "amount": { "type": "integer", "description": "Scroll steps (default 3, max 20). Use 3-5 for normal scrolling, 10+ for large jumps." }
                        },
                        "required": ["direction"]
                    }
                },
                {
                    "name": "read_clipboard_text",
                    "description": "Read text currently in the clipboard. Use to retrieve content the user has copied, or to read text staged by write_clipboard. Runs automatically.",
                    "parameters": {}
                },
                {
                    "name": "write_clipboard",
                    "description": "Write text to the clipboard so the user can paste it, or so you can paste it with ctrl+v. Runs automatically.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "text": { "type": "string", "description": "Text to copy to the clipboard" }
                        },
                        "required": ["text"]
                    }
                },
                {
                    "name": "memory_file",
                    "description": "Manage your personal knowledge base — create, read, and update structured markdown files under /memories/. Build organised topic files like /memories/steam_games.md or /memories/user_preferences.md. More powerful than 'remember' — supports full file management with selective in-place edits. Always view /memories/ first to see what exists before creating files.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "command": { "type": "string", "description": "Operation: 'view' (read file or list directory), 'create' (write new file), 'str_replace' (replace text in existing file), 'insert' (insert line), 'delete' (remove file)" },
                            "path": { "type": "string", "description": "Path starting with /memories/ — e.g. '/memories/' to list, '/memories/steam_games.md' for a file" },
                            "file_text": { "type": "string", "description": "Full file content for 'create'" },
                            "old_str": { "type": "string", "description": "Exact text to replace for 'str_replace'" },
                            "new_str": { "type": "string", "description": "Replacement text for 'str_replace'" },
                            "insert_line": { "type": "integer", "description": "Line number to insert at for 'insert' (0 = beginning)" },
                            "insert_text": { "type": "string", "description": "Text to insert for 'insert'" }
                        },
                        "required": ["command", "path"]
                    }
                },
            ]}],
            "search": [{
                "google_search": {}
            }],
            "none": []
        },
        "openai": {
            "functions": [
                {
                    "type": "function",
                    "function": {
                        "name": "get_shell_config",
                        "description": "Get the desktop shell config file contents",
                        "parameters": {}
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "set_shell_config",
                        "description": "Set a field in the desktop graphical shell config file. Must only be used after `get_shell_config`.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "key": {
                                    "type": "string",
                                    "description": "The key to set, e.g. `bar.borderless`. MUST NOT BE GUESSED, use `get_shell_config` to see what keys are available before setting.",
                                },
                                "value": {
                                    "type": "string",
                                    "description": "The value to set, e.g. `true`"
                                }
                            },
                            "required": ["key", "value"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "run_shell_command",
                        "description": "Run a shell command in bash and get its output. Use this only for quick commands that don't require user interaction. For commands that require interaction, ask the user to run manually instead.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "command": {
                                    "type": "string",
                                    "description": "The bash command to run",
                                },
                            },
                            "required": ["command"]
                        }
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "web_search",
                        "description": "Search the web for current information or facts beyond your knowledge cutoff. Use for general web searches. NOT for searching within a specific app (Spotify, YouTube, etc.) — use search_app for those.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query": {
                                    "type": "string",
                                    "description": "The search query"
                                }
                            },
                            "required": ["query"]
                        }
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "remember",
                        "description": "Store a quick single-line pattern or preference. For organised multi-topic knowledge base use memory_file instead. Store PATTERNS not facts — e.g. 'To launch Arc Raiders: open_file(steam://rungameid/1808500)', 'User prefers dark themes'. Write in third person.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "content": { "type": "string", "description": "Pattern or preference to store in third person (e.g. 'User prefers volume at 40%', 'To open X use Y')" }
                            },
                            "required": ["content"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "create_todo",
                        "description": "Add a task to the user's to-do list for manual tracking. NOT for timed reminders — use set_timer. NOT for recurring tasks — use schedule_task. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string", "description": "Task description" }
                            },
                            "required": ["title"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "get_system_logs",
                        "description": "Retrieve recent systemd journal logs for diagnosis. Runs automatically without approval.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "lines": { "type": "integer", "description": "Number of lines (default 50, max 200)" },
                                "filter": { "type": "string", "description": "Optional unit name filter" }
                            }
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "control_media",
                        "description": "Control media playback via MPRIS/playerctl. Runs automatically without approval.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'play', 'pause', 'toggle', 'next', 'previous', 'status'" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "control_hyprland",
                        "description": "Control Hyprland: switch workspaces, focus or move windows. NOT for launching apps — use launch_app. NOT for killing processes — use kill_process. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "dispatch": { "type": "string", "description": "hyprctl dispatch argument, e.g. 'workspace 2', 'focuswindow firefox'" }
                            },
                            "required": ["dispatch"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "forget_memory",
                        "description": "Remove a specific memory entry previously saved.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "content": { "type": "string", "description": "Memory entry to remove (partial match)" }
                            },
                            "required": ["content"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "export_chat",
                        "description": "Export the current conversation as a markdown file to ~/Documents.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "filename": { "type": "string", "description": "Optional filename without extension" }
                            }
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "control_system",
                        "description": "Control system volume, brightness, or power profile. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: volume_up/down/set/get, brightness_up/down/set/get, power_profile_get/set" },
                                "value": { "type": "string", "description": "Value for set actions (0-100 for volume/brightness, or profile name)" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "kill_process",
                        "description": "Kill a running process by name. Requires user approval.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "process": { "type": "string", "description": "Process name to kill" }
                            },
                            "required": ["process"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "take_screenshot",
                        "description": "Take a screenshot of all monitors and attach it for analysis. After receiving it, always visually analyze the full image — identify visible apps, UI elements, text, the cursor position (red crosshair), and which monitor the content is on. Never skip analyzing the image.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "launch_app",
                        "description": "Launch an application by command name. IMPORTANT: Steam games cannot be launched by title — use open_file with their steam://rungameid/APPID URI instead. Always follow with wait_for_app to verify the process actually started. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "App command to launch (e.g. 'firefox', 'dolphin', 'spotify'). NOT for Steam games — use open_file('steam://rungameid/ID') for those." }
                            },
                            "required": ["app"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "open_file",
                        "description": "Open a file path or URI with xdg-open. Use for Steam games ('steam://rungameid/APPID'), documents, and URLs. NOT for launching apps by name — use launch_app for that. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "File path or URL to open. For Steam games: 'steam://rungameid/APPID'" }
                            },
                            "required": ["path"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "notify",
                        "description": "Send a desktop notification popup to alert the user. Use after completing a task or for important status updates. NOT for audio output — use speak for that. NOT for mid-task status (just act). Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string", "description": "Notification title" },
                                "body": { "type": "string", "description": "Notification body" }
                            },
                            "required": ["title"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "set_timer",
                        "description": "Set a one-time countdown timer (e.g. '25 minutes'). NOT for recurring tasks — use schedule_task. NOT for task tracking — use create_todo. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "seconds": { "type": "integer", "description": "Duration in seconds" },
                                "label": { "type": "string", "description": "Timer label shown in notification" }
                            },
                            "required": ["seconds"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "calculate",
                        "description": "Evaluate a math expression using Python (e.g. '2**32', 'math.sqrt(144)'). Use this instead of run_shell_command for any pure math. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "expression": { "type": "string", "description": "Python math expression, e.g. '2**32', 'math.sqrt(144)'" }
                            },
                            "required": ["expression"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "pick_color",
                        "description": "Open hyprpicker so the user can pick a color from the screen. Returns hex color. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "manage_notes",
                        "description": "Read or write user-visible notes in SQLite. Use for notes the USER explicitly wants to keep. Use 'remember' instead for AI-internal patterns. Use 'add' to log progress steps during long tasks.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'list', 'add', 'clear'" },
                                "content": { "type": "string", "description": "Note content for 'add' action" },
                                "tags": { "type": "string", "description": "Optional comma-separated tags for 'add' action" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "search_memory",
                        "description": "Semantically search stored patterns and preferences. Call this at the START of any desktop task or user preference question — check for relevant past experience before acting. Returns most relevant results ranked by similarity.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string", "description": "What to search for" },
                                "limit": { "type": "integer", "description": "Max results (default 5)" }
                            },
                            "required": ["query"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "schedule_task",
                        "description": "Schedule a recurring AI task using cron syntax. Use for periodic reminders or automated checks. NOT for one-time countdowns — use set_timer. NOT for simple to-do items — use create_todo.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'add', 'list', 'delete'" },
                                "cron": { "type": "string", "description": "Cron expression: '0 9 * * *' = 9am daily, '*/30 * * * *' = every 30min" },
                                "prompt": { "type": "string", "description": "Message to send to AI when task fires" },
                                "id": { "type": "integer", "description": "Task ID for 'delete'" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "capture_region",
                        "description": "Let the USER interactively select a screen region to capture and analyze. Use when the user wants to pick a specific area themselves. NOT for AI-initiated screenshots — use take_screenshot for those. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "ocr_region",
                        "description": "Let the user select a screen region and extract its text via OCR. Use when you need the raw text content of a specific area. NOT for general visual analysis — use capture_region. NOT for reading text from a full screenshot — the AI can read take_screenshot images directly.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "speak",
                        "description": "Read text aloud using text-to-speech. Use when the user asks you to read something out loud. NOT for silent notifications — use notify for those. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string", "description": "Text to speak aloud" }
                            },
                            "required": ["text"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_clipboard_image",
                        "description": "Attach clipboard image to conversation for analysis. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "click_at",
                        "description": "Move the mouse to pixel coordinates (x, y) in the screenshot and click. Use the exact pixel values from the screenshot image. After clicking, a fresh screenshot is taken automatically — always check it to verify the UI changed. If the UI did NOT change, do NOT click the same spot again; try a different approach.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                                "y": { "type": "number", "description": "Vertical pixel position in the screenshot" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" }
                            },
                            "required": ["x", "y"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "click_cell",
                        "description": "Click the center of a numbered grid cell shown in the screenshot overlay. Find the grid number overlaid on the region you want to click. After clicking, a fresh screenshot is taken automatically — verify the UI changed before proceeding. If it did not change, the element may be in a different cell.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "cell": { "type": "number", "description": "The grid cell number shown in the screenshot overlay" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" }
                            },
                            "required": ["cell"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "show_plan",
                        "description": "REQUIRED before any desktop task. Call this FIRST before launch_app, click_at, click_cell, type_text, or any action sequence. Present a numbered plan and wait for approval. Never start executing desktop actions without a plan.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string" },
                                "steps": { "type": "array", "items": { "type": "object", "properties": { "description": { "type": "string" }, "tool": { "type": "string" } }, "required": ["description"] } }
                            },
                            "required": ["title", "steps"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "wait_for_app",
                        "description": "Wait until an application process is running. Call after launch_app. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "Process name, e.g. 'spotify'" },
                                "timeout": { "type": "integer", "description": "Max seconds (default 15)" }
                            },
                            "required": ["app"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "search_app",
                        "description": "Search within a specific app or service: spotify, youtube, youtube_music, soundcloud, twitch, bandcamp, reddit, github, files. For spotify, opens the search URI directly. Alternatively use press_key('ctrl+k') to open Spotify's search bar if Spotify is already focused. After calling this, a screenshot is taken automatically — wait for it and use click_cell to select from the results.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "App to search in" },
                                "query": { "type": "string", "description": "Search query" }
                            },
                            "required": ["app", "query"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_url",
                        "description": "Fetch a web page and return its interactive elements (inputs, buttons, links) with their IDs. Step 1 of 2 for precise web interaction: call read_url to get element IDs, then use execute_js to interact. NOT needed for visual clicking — use take_screenshot + click_at for that.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "url": { "type": "string", "description": "URL to fetch and parse" }
                            },
                            "required": ["url"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "execute_js",
                        "description": "Step 2 of 2: execute JavaScript in the active browser tab using element IDs from read_url. More precise than clicking visually. NOT for visual navigation — use click_at for that. NOT without read_url first unless you know the element IDs.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "code": { "type": "string", "description": "JavaScript to run in the browser" }
                            },
                            "required": ["code"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "type_text",
                        "description": "Type text into the currently focused field using the keyboard. Use after click_at on a text field. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string", "description": "Text to type" }
                            },
                            "required": ["text"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "press_key",
                        "description": "Press a keyboard key or combination, e.g. 'Return', 'ctrl+a', 'Escape', 'Tab'. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "key": { "type": "string", "description": "Key or combo to press" }
                            },
                            "required": ["key"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "scroll",
                        "description": "Scroll the mouse wheel at the current cursor position. Use after click_at to position the cursor over a scrollable area, then scroll to navigate. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "direction": { "type": "string", "description": "Direction: 'up', 'down', 'left', or 'right'" },
                                "amount": { "type": "integer", "description": "Scroll steps (default 3, max 20). Use 3-5 for normal scrolling, 10+ for large jumps." }
                            },
                            "required": ["direction"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_clipboard_text",
                        "description": "Read text currently in the clipboard. Use to retrieve content the user has copied, or to read text staged by write_clipboard. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "write_clipboard",
                        "description": "Write text to the clipboard so the user can paste it, or so you can paste it with ctrl+v. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string", "description": "Text to copy to the clipboard" }
                            },
                            "required": ["text"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "memory_file",
                        "description": "Manage your personal knowledge base — create, read, and update structured markdown files under /memories/. Build organised topic files like /memories/steam_games.md or /memories/user_preferences.md. More powerful than 'remember' — supports full file management with selective in-place edits. Always view /memories/ first to see what exists before creating files.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "command": { "type": "string", "description": "Operation: 'view' (read file or list directory), 'create' (write new file), 'str_replace' (replace text in existing file), 'insert' (insert line), 'delete' (remove file)" },
                                "path": { "type": "string", "description": "Path starting with /memories/ — e.g. '/memories/' to list, '/memories/steam_games.md' for a file" },
                                "file_text": { "type": "string", "description": "Full file content for 'create'" },
                                "old_str": { "type": "string", "description": "Exact text to replace for 'str_replace'" },
                                "new_str": { "type": "string", "description": "Replacement text for 'str_replace'" },
                                "insert_line": { "type": "integer", "description": "Line number to insert at for 'insert' (0 = beginning)" },
                                "insert_text": { "type": "string", "description": "Text to insert for 'insert'" }
                            },
                            "required": ["command", "path"]
                        }
                    }
                },
            ],
            "search": [],
            "none": [],
        },
        "mistral": {
            "functions": [
                {
                    "type": "function",
                    "function": {
                        "name": "get_shell_config",
                        "description": "Get the desktop shell config file contents",
                        "parameters": {}
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "set_shell_config",
                        "description": "Set a field in the desktop graphical shell config file. Must only be used after `get_shell_config`.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "key": {
                                    "type": "string",
                                    "description": "The key to set, e.g. `bar.borderless`. MUST NOT BE GUESSED, use `get_shell_config` to see what keys are available before setting.",
                                },
                                "value": {
                                    "type": "string",
                                    "description": "The value to set, e.g. `true`"
                                }
                            },
                            "required": ["key", "value"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "run_shell_command",
                        "description": "Run a shell command in bash and get its output. Use this only for quick commands that don't require user interaction. For commands that require interaction, ask the user to run manually instead.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "command": {
                                    "type": "string",
                                    "description": "The bash command to run",
                                },
                            },
                            "required": ["command"]
                        }
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "remember",
                        "description": "Store a quick single-line pattern or preference. For organised multi-topic knowledge base use memory_file instead. Store PATTERNS not facts — e.g. 'To launch Arc Raiders: open_file(steam://rungameid/1808500)', 'User prefers dark themes'. Write in third person.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "content": { "type": "string", "description": "Pattern or preference to store in third person (e.g. 'User prefers volume at 40%', 'To open X use Y')" }
                            },
                            "required": ["content"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "create_todo",
                        "description": "Add a task to the user's to-do list for manual tracking. NOT for timed reminders — use set_timer. NOT for recurring tasks — use schedule_task. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string", "description": "Task description" }
                            },
                            "required": ["title"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "get_system_logs",
                        "description": "Retrieve recent systemd journal logs for diagnosis. Runs automatically without approval.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "lines": { "type": "integer", "description": "Number of lines (default 50, max 200)" },
                                "filter": { "type": "string", "description": "Optional unit name filter" }
                            }
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "control_media",
                        "description": "Control media playback via MPRIS/playerctl. Runs automatically without approval.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'play', 'pause', 'toggle', 'next', 'previous', 'status'" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "control_hyprland",
                        "description": "Control Hyprland: switch workspaces, focus or move windows. NOT for launching apps — use launch_app. NOT for killing processes — use kill_process. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "dispatch": { "type": "string", "description": "hyprctl dispatch argument, e.g. 'workspace 2', 'focuswindow firefox'" }
                            },
                            "required": ["dispatch"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "forget_memory",
                        "description": "Remove a specific memory entry previously saved.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "content": { "type": "string", "description": "Memory entry to remove (partial match)" }
                            },
                            "required": ["content"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "export_chat",
                        "description": "Export the current conversation as a markdown file to ~/Documents.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "filename": { "type": "string", "description": "Optional filename without extension" }
                            }
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "control_system",
                        "description": "Control system volume, brightness, or power profile. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: volume_up/down/set/get, brightness_up/down/set/get, power_profile_get/set" },
                                "value": { "type": "string", "description": "Value for set actions (0-100 for volume/brightness, or profile name)" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "kill_process",
                        "description": "Kill a running process by name. Requires user approval.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "process": { "type": "string", "description": "Process name to kill" }
                            },
                            "required": ["process"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "take_screenshot",
                        "description": "Take a screenshot and attach it to the conversation for visual analysis. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "launch_app",
                        "description": "Launch an application by command name. IMPORTANT: Steam games cannot be launched by title — use open_file with their steam://rungameid/APPID URI instead. Always follow with wait_for_app to verify the process actually started. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "App command to launch (e.g. 'firefox', 'dolphin', 'spotify'). NOT for Steam games — use open_file('steam://rungameid/ID') for those." }
                            },
                            "required": ["app"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "open_file",
                        "description": "Open a file path or URI with xdg-open. Use for Steam games ('steam://rungameid/APPID'), documents, and URLs. NOT for launching apps by name — use launch_app for that. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "File path or URL to open. For Steam games: 'steam://rungameid/APPID'" }
                            },
                            "required": ["path"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "notify",
                        "description": "Send a desktop notification popup to alert the user. Use after completing a task or for important status updates. NOT for audio output — use speak for that. NOT for mid-task status (just act). Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string", "description": "Notification title" },
                                "body": { "type": "string", "description": "Notification body" }
                            },
                            "required": ["title"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "set_timer",
                        "description": "Set a one-time countdown timer (e.g. '25 minutes'). NOT for recurring tasks — use schedule_task. NOT for task tracking — use create_todo. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "seconds": { "type": "integer", "description": "Duration in seconds" },
                                "label": { "type": "string", "description": "Timer label shown in notification" }
                            },
                            "required": ["seconds"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "calculate",
                        "description": "Evaluate a math expression using Python (e.g. '2**32', 'math.sqrt(144)'). Use this instead of run_shell_command for any pure math. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "expression": { "type": "string", "description": "Python math expression, e.g. '2**32', 'math.sqrt(144)'" }
                            },
                            "required": ["expression"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "pick_color",
                        "description": "Open hyprpicker so the user can pick a color from the screen. Returns hex color. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "manage_notes",
                        "description": "Read or write user-visible notes in SQLite. Use for notes the USER explicitly wants to keep. Use 'remember' instead for AI-internal patterns. Use 'add' to log progress steps during long tasks.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'list', 'add', 'clear'" },
                                "content": { "type": "string", "description": "Note content for 'add' action" },
                                "tags": { "type": "string", "description": "Optional comma-separated tags for 'add' action" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "search_memory",
                        "description": "Semantically search stored patterns and preferences. Call this at the START of any desktop task or user preference question — check for relevant past experience before acting. Returns most relevant results ranked by similarity.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string", "description": "What to search for" },
                                "limit": { "type": "integer", "description": "Max results (default 5)" }
                            },
                            "required": ["query"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "schedule_task",
                        "description": "Schedule a recurring AI task using cron syntax. Use for periodic reminders or automated checks. NOT for one-time countdowns — use set_timer. NOT for simple to-do items — use create_todo.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'add', 'list', 'delete'" },
                                "cron": { "type": "string", "description": "Cron expression: '0 9 * * *' = 9am daily, '*/30 * * * *' = every 30min" },
                                "prompt": { "type": "string", "description": "Message to send to AI when task fires" },
                                "id": { "type": "integer", "description": "Task ID for 'delete'" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "capture_region",
                        "description": "Let the USER interactively select a screen region to capture and analyze. Use when the user wants to pick a specific area themselves. NOT for AI-initiated screenshots — use take_screenshot for those. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "ocr_region",
                        "description": "Let the user select a screen region and extract its text via OCR. Use when you need the raw text content of a specific area. NOT for general visual analysis — use capture_region. NOT for reading text from a full screenshot — the AI can read take_screenshot images directly.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "speak",
                        "description": "Read text aloud using text-to-speech. Use when the user asks you to read something out loud. NOT for silent notifications — use notify for those. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string", "description": "Text to speak aloud" }
                            },
                            "required": ["text"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_clipboard_image",
                        "description": "Attach clipboard image to conversation for analysis. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "click_at",
                        "description": "Move the mouse to pixel coordinates (x, y) in the screenshot you just received and click. Coordinates are in the screenshot's pixel space — use the exact values you see in the image. After clicking, a new screenshot is taken automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                                "y": { "type": "number", "description": "Vertical pixel position in the screenshot" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" }
                            },
                            "required": ["x", "y"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "click_cell",
                        "description": "Click the center of a numbered grid cell from the screenshot overlay. The screenshot is divided into a numbered grid — use the cell number you see in the image to click that region. After clicking, a new screenshot is taken automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "cell": { "type": "number", "description": "The grid cell number shown in the screenshot overlay" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" }
                            },
                            "required": ["cell"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "show_plan",
                        "description": "Present a numbered multi-step task plan to the user for approval before executing. Use for any task with 2+ steps.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": { "type": "string" },
                                "steps": { "type": "array", "items": { "type": "object", "properties": { "description": { "type": "string" }, "tool": { "type": "string" } }, "required": ["description"] } }
                            },
                            "required": ["title", "steps"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "wait_for_app",
                        "description": "Wait until an application process is running. Call after launch_app. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "Process name, e.g. 'spotify'" },
                                "timeout": { "type": "integer", "description": "Max seconds (default 15)" }
                            },
                            "required": ["app"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "search_app",
                        "description": "Search within a specific app or service: spotify, youtube, youtube_music, soundcloud, twitch, bandcamp, reddit, github, files. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "App to search in" },
                                "query": { "type": "string", "description": "Search query" }
                            },
                            "required": ["app", "query"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_url",
                        "description": "Fetch a web page and return its interactive elements (inputs, buttons, links) with their IDs. Step 1 of 2 for precise web interaction: call read_url to get element IDs, then use execute_js to interact. NOT needed for visual clicking — use take_screenshot + click_at for that.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "url": { "type": "string", "description": "URL to fetch and parse" }
                            },
                            "required": ["url"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "execute_js",
                        "description": "Step 2 of 2: execute JavaScript in the active browser tab using element IDs from read_url. More precise than clicking visually. NOT for visual navigation — use click_at for that. NOT without read_url first unless you know the element IDs.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "code": { "type": "string", "description": "JavaScript to run in the browser" }
                            },
                            "required": ["code"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "type_text",
                        "description": "Type text into the currently focused field using the keyboard. Use after click_at on a text field. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string", "description": "Text to type" }
                            },
                            "required": ["text"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "press_key",
                        "description": "Press a keyboard key or combination, e.g. 'Return', 'ctrl+a', 'Escape', 'Tab'. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "key": { "type": "string", "description": "Key or combo to press" }
                            },
                            "required": ["key"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "scroll",
                        "description": "Scroll the mouse wheel at the current cursor position. Use after click_at to position the cursor over a scrollable area, then scroll to navigate. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "direction": { "type": "string", "description": "Direction: 'up', 'down', 'left', or 'right'" },
                                "amount": { "type": "integer", "description": "Scroll steps (default 3, max 20). Use 3-5 for normal scrolling, 10+ for large jumps." }
                            },
                            "required": ["direction"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_clipboard_text",
                        "description": "Read text currently in the clipboard. Use to retrieve content the user has copied, or to read text staged by write_clipboard. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "write_clipboard",
                        "description": "Write text to the clipboard so the user can paste it, or so you can paste it with ctrl+v. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "text": { "type": "string", "description": "Text to copy to the clipboard" }
                            },
                            "required": ["text"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "memory_file",
                        "description": "Manage your personal knowledge base — create, read, and update structured markdown files under /memories/. Build organised topic files like /memories/steam_games.md or /memories/user_preferences.md. More powerful than 'remember' — supports full file management with selective in-place edits. Always view /memories/ first to see what exists before creating files.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "command": { "type": "string", "description": "Operation: 'view' (read file or list directory), 'create' (write new file), 'str_replace' (replace text in existing file), 'insert' (insert line), 'delete' (remove file)" },
                                "path": { "type": "string", "description": "Path starting with /memories/ — e.g. '/memories/' to list, '/memories/steam_games.md' for a file" },
                                "file_text": { "type": "string", "description": "Full file content for 'create'" },
                                "old_str": { "type": "string", "description": "Exact text to replace for 'str_replace'" },
                                "new_str": { "type": "string", "description": "Replacement text for 'str_replace'" },
                                "insert_line": { "type": "integer", "description": "Line number to insert at for 'insert' (0 = beginning)" },
                                "insert_text": { "type": "string", "description": "Text to insert for 'insert'" }
                            },
                            "required": ["command", "path"]
                        }
                    }
                },
            ],
            "search": [],
            "none": [],
        }
    }
    property list<var> availableTools: Object.keys(root.tools[models[currentModelId]?.api_format]) ?? []
    property var toolDescriptions: {
        "functions": Translation.tr("Commands, edit configs, search.\nTakes an extra turn to switch to search mode if that's needed"),
        "search": Translation.tr("Gives the model search capabilities (immediately)"),
        "none": Translation.tr("Disable tools")
    }

    readonly property string currentModel: Persistent.states.ai.model
    // Model properties:
    // - name: Name of the model
    // - icon: Icon name of the model
    // - description: Description of the model
    // - endpoint: Endpoint of the model
    // - model: Model name of the model
    // - requires_key: Whether the model requires an API key
    // - key_id: The identifier of the API key. Use the same identifier for models that can be accessed with the same key.
    // - key_get_link: Link to get an API key
    // - key_get_description: Description of pricing and how to get an API key
    // - api_format: The API format of the model. Can be "openai" or "gemini". Default is "openai".
    // - extraParams: Extra parameters to be passed to the model. This is a JSON object.
    property var models: Config.options.policies.ai === 2 ? {} : {
        "openrouter": aiModelComponent.createObject(this, {
            name: `OpenRouter - ${currentModel}`,
            icon: "openrouter-symbolic",
            description: Translation.tr("Online via %1 | %2's model")
                .arg("OpenRouter")
                .arg("Google"),
            homepage: `https://openrouter.ai/google/${currentModel}`, 
            endpoint: "https://openrouter.ai/api/v1/chat/completions",
            model: `${getModelProvider(Persistent.states.ai.provider,currentModel)}/${currentModel}`,
            requires_key: true,
            key_id: "openrouter",
            key_get_link: "https://openrouter.ai/settings/keys",
            key_get_description: Translation.tr(
                "**Pricing**: Pay-as-you-go (token based).\n\n" +
                "**Instructions**: Log into your OpenRouter account, " +
                "go to Keys in the top-right menu, and create an API key."
            ),
        }),
        "ollama": aiModelComponent.createObject(this, {
            "name": `Ollama - ${currentModel}`,
            "icon": guessModelLogo(currentModel),
                                                "description": Translation.tr("Local Ollama model | %1").arg(currentModel),
                                                "homepage": `https://ollama.com/library/${currentModel}`,
                                                "endpoint": "http://localhost:11434/v1/chat/completions",
                                                "model": currentModel,
                                                "requires_key": false,
                                                "api_format": "openai",
                                                "extraParams": { "num_ctx": 32768 },
        }),
        "google": aiModelComponent.createObject(this, {
            "name": `Google - ${currentModel}`,
            "icon": "google-gemini-symbolic",
            "description": Translation.tr("Online | Google's model\nNewer model that's slower than its predecessor but should deliver higher quality answers"),
            "homepage": "https://aistudio.google.com",
            "endpoint": `https://generativelanguage.googleapis.com/v1beta/models/${currentModel}:streamGenerateContent`,
            "model": `${currentModel}`,
            "requires_key": true,
            "key_id": "gemini",
            "key_get_link": "https://aistudio.google.com/app/apikey",
            "key_get_description": Translation.tr("**Pricing**: free. Data used for training.\n\n**Instructions**: Log into Google account, allow AI Studio to create Google Cloud project or whatever it asks, go back and click Get API key"),
            "api_format": "gemini",
        }),
        "mistral": aiModelComponent.createObject(this, {
            "name": `Mistral - ${currentModel}`,
            "icon": "mistral-symbolic",
            "description": Translation.tr("Online | %1's model | Delivers fast, responsive and well-formatted answers. Disadvantages: not very eager to do stuff; might make up unknown function calls").arg("Mistral"),
            "homepage": "https://mistral.ai/news/mistral-medium-3",
            "endpoint": "https://api.mistral.ai/v1/chat/completions",
            "model": "mistral-medium-2505",
            "requires_key": true,
            "key_id": "mistral",
            "key_get_link": "https://console.mistral.ai/api-keys",
            "key_get_description": Translation.tr("**Instructions**: Log into Mistral account, go to Keys on the sidebar, click Create new key"),
            "api_format": "mistral",
        }),
    }
    property var modelList: Object.keys(root.models)
    property var currentModelId: Persistent.states?.ai?.provider || modelList[0]

    property var baseModels: {
        "openrouter": [
            {title: "Gemini 2.5 Flash-Lite", value: "gemini-2.5-flash-lite", modelProvider: "google"},
        ],
        "google": [
            { title: "Gemini 2.5 Flash-Lite", value: "gemini-2.5-flash-lite" },
            { title: "Gemini 2.5 Flash", value: "gemini-2.5-flash" },
            { title: "Gemini 3 Flash Preview", value: "gemini-3-flash-preview" }
        ],
        "mistral": [
            { title: "Mistral Medium 3", value: "mistral-medium-3" }
        ],
    }

    property var modelsOfProviders: baseModels

    function mergeModelsFromList(base, extraList) {

        var result = {}
        for (var provider in base) {
            result[provider] = base[provider].slice()
        }
        
        if (extraList) {
            for (var i = 0; i < extraList.length; i++) {
                var item = extraList[i]
                for (var provider in item) {
                    if (result[provider]) {
                        result[provider] = result[provider].concat(item[provider])
                    } else {
                        result[provider] = item[provider].slice()
                    }
                }
            }
        }
        
        return result
    }

    function getModelProvider(providerKey, modelValue) {
        if (!modelsOfProviders[providerKey]) {
            return null
        }
        
        var models = modelsOfProviders[providerKey]
        for (var i = 0; i < models.length; i++) {
            if (models[i].value === modelValue) {
                return models[i].modelProvider || null
            }
        }
        
        return null
    }


    property var apiStrategies: {
        "openai": openaiApiStrategy.createObject(this),
        "gemini": geminiApiStrategy.createObject(this),
        "mistral": mistralApiStrategy.createObject(this),
    }
    property ApiStrategy currentApiStrategy: apiStrategies[models[currentModelId]?.api_format || "openai"]

    property string requestScriptFilePath: "/tmp/quickshell/ai/request.sh"
    property string pendingFilePath: ""
    // True while the AI requester process is running (streaming a response)
    readonly property bool isGenerating: requester.running

    // Screenshot scaling — used so 4K screenshots are downscaled to 1920px wide
    // before sending to the model. click_at coords are in the scaled space.
    property real lastScreenshotScale: 1.0
    property int lastScreenshotWidth: 0
    property int lastScreenshotHeight: 0
    property int lastScreenshotOffsetX: 0
    property int lastScreenshotOffsetY: 0
    property int lastGridCols: 8
    property int lastGridRows: 5
    property string _lastClickInfo: ""

    Component.onCompleted: {
        // Ensure memories directory exists
        Quickshell.execDetached(["bash", "-c", `mkdir -p "${Directories.aiMemoryPath.replace("memory.md", "memories")}"`]);
        setModel(currentModelId, false, false); // Do necessary setup for model
        if (Config.options.ai.extraModels.length > 0) {
            modelsOfProviders = mergeModelsFromList(baseModels, Config.options.ai.extraModels)
        }
    }

    function guessModelLogo(model) {
        if (model.includes("llama")) return "ollama-symbolic";
        if (model.includes("gemma")) return "google-gemini-symbolic";
        if (model.includes("deepseek")) return "deepseek-symbolic";
        if (/^phi\d*:/i.test(model)) return "microsoft-symbolic";
        return "ollama-symbolic";
    }

    function guessModelName(model) {
        const replaced = model.replace(/-/g, ' ').replace(/:/g, ' ');
        let words = replaced.split(' ');
        words[words.length - 1] = words[words.length - 1].replace(/(\d+)b$/, (_, num) => `${num}B`)
        words = words.map((word) => {
            return (word.charAt(0).toUpperCase() + word.slice(1))
        });
        if (words[words.length - 1] === "Latest") words.pop();
        else words[words.length - 1] = `(${words[words.length - 1]})`; // Surround the last word with square brackets
        const result = words.join(' ');
        return result;
    }

    function addModel(modelName, data) {
        root.models[modelName] = aiModelComponent.createObject(this, data);
    }

    Process {
        id: getOllamaModels
        running: true
        command: ["bash", "-c", "curl -s http://localhost:11434/api/tags | jq -c '[.models[].name]'"]
        stdout: StdioCollector {
            onStreamFinished: {
                console.log("Ollama output:", text);
                try {
                    if (text.length === 0) return;
                    const dataJson = JSON.parse(text.trim());
                    const EMBED_MODELS = ["nomic-embed", "mxbai-embed", "all-minilm", "snowflake-arctic-embed", "bge-m3", "bge-large"];
                    root.modelsOfProviders = Object.assign({}, root.modelsOfProviders, {
                        "ollama": dataJson
                            .filter(model => !EMBED_MODELS.some(e => model.toLowerCase().includes(e)))
                            .map(model => ({
                                title: guessModelName(model),
                                value: model
                            }))
                    });
                } catch (e) {
                    console.log("Could not fetch Ollama models:", e);
                }
            }
        }
    }

    Process {
        id: getDefaultPrompts
        running: true
        command: ["ls", "-1", Directories.defaultAiPrompts]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.length === 0) return;
                root.defaultPrompts = text.split("\n")
                    .filter(fileName => fileName.endsWith(".md") || fileName.endsWith(".txt"))
                    .map(fileName => `${Directories.defaultAiPrompts}/${fileName}`)
            }
        }
    }

    Process {
        id: getUserPrompts
        running: true
        command: ["ls", "-1", Directories.userAiPrompts]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.length === 0) return;
                root.userPrompts = text.split("\n")
                    .filter(fileName => fileName.endsWith(".md") || fileName.endsWith(".txt"))
                    .map(fileName => `${Directories.userAiPrompts}/${fileName}`)
            }
        }
    }

    Process {
        id: getSavedChats
        running: true
        command: ["ls", "-1", Directories.aiChats]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.length === 0) return;
                root.savedChats = text.split("\n")
                    .filter(fileName => fileName.endsWith(".json"))
                    .map(fileName => `${Directories.aiChats}/${fileName}`)
            }
        }
    }

    FileView {
        id: promptLoader
        watchChanges: false;
        onLoadedChanged: {
            if (!promptLoader.loaded) return;
            Config.options.ai.systemPrompt = promptLoader.text();
            root.addMessage(Translation.tr("Loaded the following system prompt\n\n---\n\n%1").arg(Config.options.ai.systemPrompt), root.interfaceRole);
        }
    }

    function printPrompt() {
        root.addMessage(Translation.tr("The current system prompt is\n\n---\n\n%1").arg(Config.options.ai.systemPrompt), root.interfaceRole);
    }

    function loadPrompt(filePath) {
        promptLoader.path = "" // Unload
        promptLoader.path = filePath; // Load
        promptLoader.reload();
    }

    function addMessage(message, role) {
        if (message.length === 0) return;
        const aiMessage = aiMessageComponent.createObject(root, {
            "role": role,
            "content": message,
            "rawContent": message,
            "thinking": false,
            "done": true,
        });
        const id = idForMessage(aiMessage);
        root.messageIDs = [...root.messageIDs, id];
        root.messageByID[id] = aiMessage;
    }

    function removeMessage(index) {
        if (index < 0 || index >= messageIDs.length) return;
        const id = root.messageIDs[index];
        root.messageIDs.splice(index, 1);
        root.messageIDs = [...root.messageIDs];
        delete root.messageByID[id];
    }

    function addApiKeyAdvice(model) {
        root.addMessage(
            Translation.tr('To set an API key, pass it with the %4 command\n\nTo view the key, pass "get" with the command<br/>\n\n### For %1:\n\n**Link**: %2\n\n%3')
                .arg(model.name).arg(model.key_get_link).arg(model.key_get_description ?? Translation.tr("<i>No further instruction provided</i>")).arg("/key"), 
            Ai.interfaceRole
        );
    }

    function getModel() {
        return models[currentModelId];
    }

    function setModel(modelId, feedback = true, setPersistentState = true) {
        if (!modelId) modelId = ""
        modelId = modelId.toLowerCase()
        if (modelList.indexOf(modelId) !== -1) {
            const model = models[modelId]
            // See if policy prevents online models
            if (Config.options.policies.ai === 2 && !model.endpoint.includes("localhost")) {
                root.addMessage(
                    Translation.tr("Online models disallowed\n\nControlled by `policies.ai` config option"),
                    root.interfaceRole
                );
                return;
            }
            if (setPersistentState) Persistent.states.ai.model = modelId;
            if (feedback) root.addMessage(Translation.tr("Model set to %1").arg(model.name), root.interfaceRole);
            if (model.requires_key) {
                // If key not there show advice
                if (root.apiKeysLoaded && (!root.apiKeys[model.key_id] || root.apiKeys[model.key_id].length === 0)) {
                    root.addApiKeyAdvice(model)
                }
            }
        } else {
            if (feedback) root.addMessage(Translation.tr("Invalid model. Supported: \n```\n") + modelList.join("\n```\n```\n"), Ai.interfaceRole) + "\n```"
        }
    }

    function setTool(tool) {
        if (!root.tools[models[currentModelId]?.api_format] || !(tool in root.tools[models[currentModelId]?.api_format])) {
            root.addMessage(Translation.tr("Invalid tool. Supported tools:\n- %1").arg(root.availableTools.join("\n- ")), root.interfaceRole);
            return false;
        }
        Config.options.ai.tool = tool;
        return true;
    }
    
    function getTemperature() {
        return root.temperature;
    }

    function setTemperature(value) {
        if (value == NaN || value < 0 || value > 2) {
            root.addMessage(Translation.tr("Temperature must be between 0 and 2"), Ai.interfaceRole);
            return;
        }
        Persistent.states.ai.temperature = value;
        root.temperature = value;
        root.addMessage(Translation.tr("Temperature set to %1").arg(value), Ai.interfaceRole);
    }

    function setApiKey(key) {
        const model = models[currentModelId];
        if (!model.requires_key) {
            root.addMessage(Translation.tr("%1 does not require an API key").arg(model.name), Ai.interfaceRole);
            return;
        }
        if (!key || key.length === 0) {
            const model = models[currentModelId];
            root.addApiKeyAdvice(model)
            return;
        }
        KeyringStorage.setNestedField(["apiKeys", model.key_id], key.trim());
        root.addMessage(Translation.tr("API key set for %1").arg(model.name), Ai.interfaceRole);
    }

    function printApiKey() {
        const model = models[currentModelId];
        if (model.requires_key) {
            const key = root.apiKeys[model.key_id];
            if (key) {
                root.addMessage(Translation.tr("API key:\n\n```txt\n%1\n```").arg(key), Ai.interfaceRole);
            } else {
                root.addMessage(Translation.tr("No API key set for %1").arg(model.name), Ai.interfaceRole);
            }
        } else {
            root.addMessage(Translation.tr("%1 does not require an API key").arg(model.name), Ai.interfaceRole);
        }
    }

    function printTemperature() {
        root.addMessage(Translation.tr("Temperature: %1").arg(root.temperature), Ai.interfaceRole);
    }

    function clearMessages() {
        root.messageIDs = [];
        root.messageByID = ({});
        root.tokenCount.input = -1;
        root.tokenCount.output = -1;
        root.tokenCount.total = -1;
    }

    FileView {
        id: requesterScriptFile
    }

    Process {
        id: requester
        property list<string> baseCommand: ["bash"]
        property AiMessageData message
        property ApiStrategy currentStrategy

        function markDone() {
            requester.message.done = true;
            if (root.postResponseHook) {
                root.postResponseHook();
                root.postResponseHook = null; // Reset hook after use
            }
            root.requestRestoreSidebars();
            root.saveChat("lastSession")
            root.responseFinished()
        }

        function makeRequest() {
            const model = models[currentModelId];

            // Guard against infinite tool-call loops
            root.consecutiveToolCalls++;
            if (root.consecutiveToolCalls > root.maxConsecutiveToolCalls) {
                root.consecutiveToolCalls = 0;
                root.addMessage(`[Stopped: ${root.maxConsecutiveToolCalls} consecutive tool calls without user input. Please check what went wrong.]`, root.interfaceRole);
                return;
            }

            // Fetch API keys if needed
            if (model?.requires_key && !KeyringStorage.loaded) KeyringStorage.fetchKeyringData();
            
            requester.currentStrategy = root.currentApiStrategy;
            requester.currentStrategy.reset(); // Reset strategy state

            /* Put API key in environment variable */
            if (model.requires_key) requester.environment[`${root.apiKeyEnvVarName}`] = root.apiKeys ? (root.apiKeys[model.key_id] ?? "") : ""

            /* Build endpoint, request data */
            const endpoint = root.currentApiStrategy.buildEndpoint(model);
            const messageArray = root.messageIDs.map(id => root.messageByID[id]);
            const filteredMessageArray = messageArray.filter(message => message.role !== Ai.interfaceRole);
            // Strip old file/image data from history — only the current pendingFilePath is sent.
            // Resending base64 screenshots in every message blows context on long agentic chains.
            const lastImgIdx = filteredMessageArray.reduce((last, m, i) => (m.fileUri?.length > 0 || m.filePath?.length > 0) ? i : last, -1);
            const trimmedMessageArray = filteredMessageArray.map((m, i) => {
                if (i < lastImgIdx && (m.fileUri?.length > 0 || m.filePath?.length > 0)) {
                    const stripped = Object.assign({}, m);
                    stripped.fileUri = "";
                    stripped.filePath = "";
                    stripped.fileMimeType = "";
                    return stripped;
                }
                return m;
            });
            // Context compaction: when context grows large, drop old tool-result messages
            // keeping only the most recent ones. Preserves real user/assistant conversation.
            const TOOL_RESULT_KEEP = 20;
            let contextArr = trimmedMessageArray;
            if (contextArr.length > 50) {
                const toolMsgs = contextArr.filter(m => m.functionName && m.functionName.length > 0);
                if (toolMsgs.length > TOOL_RESULT_KEEP) {
                    const dropSet = new Set(toolMsgs.slice(0, toolMsgs.length - TOOL_RESULT_KEEP));
                    contextArr = contextArr.filter(m => !dropSet.has(m));
                    console.log(`[AI] Context compacted: dropped ${dropSet.size} old tool results (${contextArr.length} messages remaining)`);
                }
            }
            const data = root.currentApiStrategy.buildRequestData(model, contextArr, root.systemPrompt, root.temperature, root.tools[model.api_format][root.currentTool], root.pendingFilePath);
            // console.log("[Ai] Request data: ", JSON.stringify(data, null, 2));

            let requestHeaders = {
                "Content-Type": "application/json",
            }
            
            /* Create local message object */
            requester.message = root.aiMessageComponent.createObject(root, {
                "role": "assistant",
                "model": currentModelId,
                "content": "",
                "rawContent": "",
                "thinking": true,
                "done": false,
            });
            const id = idForMessage(requester.message);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = requester.message;

            /* Build header string for curl */ 
            let headerString = Object.entries(requestHeaders)
                .filter(([k, v]) => v && v.length > 0)
                .map(([k, v]) => `-H '${k}: ${v}'`)
                .join(' ');

            // console.log("Request headers: ", JSON.stringify(requestHeaders));
            // console.log("Header string: ", headerString);

            /* Get authorization header from strategy */
            const authHeader = requester.currentStrategy.buildAuthorizationHeader(root.apiKeyEnvVarName);
            
            /* Script shebang */
            const scriptShebang = "#!/usr/bin/env bash\n";

            /* Create extra setup when there's an attached file */
            let scriptFileSetupContent = ""
            if (root.pendingFilePath && root.pendingFilePath.length > 0) {
                requester.message.localFilePath = root.pendingFilePath;
                scriptFileSetupContent = requester.currentStrategy.buildScriptFileSetup(root.pendingFilePath);
                root.pendingFilePath = ""
            }

            /* Create command string */
            let scriptRequestContent = ""
            scriptRequestContent += `curl --no-buffer --max-time 120 --connect-timeout 15 "${endpoint}"`
                + ` ${headerString}`
                + (authHeader ? ` ${authHeader}` : "")
                + ` --data '${CF.StringUtils.shellSingleQuoteEscape(JSON.stringify(data))}'`
                + "\n"
            
            /* Send the request */
            const scriptContent = requester.currentStrategy.finalizeScriptContent(scriptShebang + scriptFileSetupContent + scriptRequestContent)
            const shellScriptPath = CF.FileUtils.trimFileProtocol(root.requestScriptFilePath)
            requesterScriptFile.path = Qt.resolvedUrl(shellScriptPath)
            requesterScriptFile.setText(scriptContent)
            requester.command = baseCommand.concat([shellScriptPath]);
            requester.running = true
        }

        stdout: SplitParser {
            onRead: data => {
                if (data.length === 0) return;
                if (requester.message.thinking) requester.message.thinking = false;
                // console.log("[Ai] Raw response line: ", data);

                // Handle response line
                try {
                    const result = requester.currentStrategy.parseResponseLine(data, requester.message);
                    // console.log("[Ai] Parsed response result: ", JSON.stringify(result, null, 2));

                    if (result.functionCall) {
                        console.log("[AI] Dispatching functionCall:", result.functionCall.name);
                        requester.message.functionCall = result.functionCall;
                        root.handleFunctionCall(result.functionCall.name, result.functionCall.args, requester.message);
                    }
                    if (result.tokenUsage) {
                        root.tokenCount.input = result.tokenUsage.input;
                        root.tokenCount.output = result.tokenUsage.output;
                        root.tokenCount.total = result.tokenUsage.total;
                    }
                    if (result.finished) {
                        requester.markDone();
                    }
                    
                } catch (e) {
                    console.log("[AI] Could not parse response: ", e);
                    requester.message.rawContent += data;
                    requester.message.content += data;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            const result = requester.currentStrategy.onRequestFinished(requester.message);
            
            if (result.finished) {
                requester.markDone();
            } else if (!requester.message.done) {
                requester.markDone();
            }

            // Handle error responses
            if (requester.message.content.includes("API key not valid")) {
                root.addApiKeyAdvice(models[requester.message.model]);
            }
        }
    }

    property int consecutiveToolCalls: 0
    property bool _turnHadPlan: false
    readonly property int maxConsecutiveToolCalls: 25

    function sendUserMessage(message) {
        if (message.length === 0) return;
        root.consecutiveToolCalls = 0;
        root._turnHadPlan = false;
        root.requestRestoreSidebars();
        root.addMessage(message, "user");
        requester.makeRequest();
    }

    function attachFile(filePath: string) {
        root.pendingFilePath = CF.FileUtils.trimFileProtocol(filePath);
    }

    function regenerate(messageIndex) {
        if (messageIndex < 0 || messageIndex >= messageIDs.length) return;
        const id = root.messageIDs[messageIndex];
        const message = root.messageByID[id];
        if (message.role !== "assistant") return;
        // Remove all messages after this one
        for (let i = root.messageIDs.length - 1; i >= messageIndex; i--) {
            root.removeMessage(i);
        }
        requester.makeRequest();
    }

    function createFunctionOutputMessage(name, output, includeOutputInChat = true) {
        return aiMessageComponent.createObject(root, {
            "role": "user",
            "content": `[[ Output of ${name} ]]${includeOutputInChat ? ("\n\n<think>\n" + output + "\n</think>") : ""}`,
            "rawContent": `[[ Output of ${name} ]]${includeOutputInChat ? ("\n\n<think>\n" + output + "\n</think>") : ""}`,
            "functionName": name,
            "functionResponse": output,
            "thinking": false,
            "done": true,
            // "visibleToUser": false,
        });
    }

    function addFunctionOutputMessage(name, output) {
        const aiMessage = createFunctionOutputMessage(name, output);
        const id = idForMessage(aiMessage);
        root.messageIDs = [...root.messageIDs, id];
        root.messageByID[id] = aiMessage;
    }

    function rejectCommand(message: AiMessageData) {
        if (!message.functionPending) return;
        message.functionPending = false; // User decided, no more "thinking"
        addFunctionOutputMessage(message.functionName, Translation.tr("Command rejected by user"))
    }

    function approveCommand(message: AiMessageData) {
        if (!message.functionPending) return;
        message.functionPending = false; // User decided, no more "thinking"

        const responseMessage = createFunctionOutputMessage(message.functionName, "", false);
        const id = idForMessage(responseMessage);
        root.messageIDs = [...root.messageIDs, id];
        root.messageByID[id] = responseMessage;

        commandExecutionProc.message = responseMessage;
        commandExecutionProc.baseMessageContent = responseMessage.content;
        commandExecutionProc.shellCommand = message.functionCall.args.command;
        commandExecutionProc.running = true; // Start the command execution
    }

    Process {
        id: commandExecutionProc
        property string shellCommand: ""
        property AiMessageData message
        property string baseMessageContent: ""
        command: ["bash", "-c", shellCommand]
        stdout: SplitParser {
            onRead: (output) => {
                const MAX_OUTPUT = 4000;
                commandExecutionProc.message.functionResponse += output + "\n\n";
                let responseText = commandExecutionProc.message.functionResponse;
                if (responseText.length > MAX_OUTPUT) {
                    responseText = responseText.substring(0, MAX_OUTPUT) + "\n\n[Output truncated]";
                }
                const updatedContent = commandExecutionProc.baseMessageContent + `\n\n<think>\n<tt>${responseText}</tt>\n</think>`;
                commandExecutionProc.message.rawContent = updatedContent;
                commandExecutionProc.message.content = updatedContent;
            }
        }
        onExited: (exitCode, exitStatus) => {
            commandExecutionProc.message.functionResponse += `[[ Command exited with code ${exitCode} (${exitStatus}) ]]\n`;
            requester.makeRequest();
        }
    }

    function handleFunctionCall(name, args: var, message: AiMessageData) {
        // show_plan gate: for action tools on a new turn (2+ tool calls), require a plan first
        const actionTools = ["click_at","click_cell","type_text","press_key","launch_app","scroll"];
        if (!root._turnHadPlan && root.consecutiveToolCalls >= 2 && actionTools.includes(name)) {
            // Inject a reminder to plan first
            addFunctionOutputMessage(name, `[Gate] You attempted '${name}' without calling show_plan first. Please call show_plan with the full task breakdown before executing any actions.`);
            requester.makeRequest();
            return;
        }
        if (name === "switch_to_search_mode") {
            const modelId = root.currentModelId;
            root.currentTool = "search"
            root.postResponseHook = () => { root.currentTool = "functions" }
            addFunctionOutputMessage(name, Translation.tr("Switched to search mode. Continue with the user's request."))
            requester.makeRequest();
        } else if (name === "get_shell_config") {
            const configJson = CF.ObjectUtils.toPlainObject(Config.options)
            addFunctionOutputMessage(name, JSON.stringify(configJson));
            requester.makeRequest();
        } else if (name === "set_shell_config") {
            if (!args.changes || !Array.isArray(args.changes)) {
                addFunctionOutputMessage(name, Translation.tr("Invalid arguments. Must provide `changes` array."));
                requester.makeRequest();
                return;
            }
            let results = [];
            for (const change of args.changes) {
                if (!change.key || !change.value) {
                    results.push(`❌ Skipped invalid change: ${JSON.stringify(change)}`);
                    continue;
                }
                try {
                    Config.setNestedValue(change.key, change.value);
                    results.push(`✓ ${change.key} = ${change.value}`);
                } catch (e) {
                    results.push(`❌ Failed to set ${change.key}: ${e}`);
                }
            }
            addFunctionOutputMessage(name, results.join("\n"));
            requester.makeRequest();
        } else if (name === "run_shell_command") {
            if (!args.command || args.command.length === 0) {
                addFunctionOutputMessage(name, Translation.tr("Invalid arguments. Must provide `command`."));
                requester.makeRequest();
                return;
            }
            // Auto-approve safe read-only commands
            const safePattern = /^(ls(\s|$)|cat\s|pwd(\s|$)|df(\s|$)|ps(\s|$)|du\s|find\s|echo\s|date(\s|$)|whoami(\s|$)|uname(\s|$)|hostname(\s|$)|free(\s|$)|uptime(\s|$)|which\s|file\s|stat\s|wc\s|head\s|tail\s|lsblk(\s|$)|lscpu(\s|$)|ip\s|nmcli\s|env(\s|$)|printenv(\s|$)|systemctl status\s)/;
            if (safePattern.test(args.command.trim())) {
                const responseMessage = createFunctionOutputMessage(name, "", false);
                const id = idForMessage(responseMessage);
                root.messageIDs = [...root.messageIDs, id];
                root.messageByID[id] = responseMessage;
                commandExecutionProc.message = responseMessage;
                commandExecutionProc.baseMessageContent = responseMessage.content;
                commandExecutionProc.shellCommand = args.command;
                commandExecutionProc.running = true;
            } else {
                const contentToAppend = `\n\n**Command execution request**\n\n\`\`\`command\n${args.command}\n\`\`\``;
                message.rawContent += contentToAppend;
                message.content += contentToAppend;
                message.functionPending = true;
            }
        } else if (name === "web_search") {
            if (!args.query || args.query.length === 0) {
                addFunctionOutputMessage(name, Translation.tr("Invalid arguments. Must provide `query`."));
                requester.makeRequest();
                return;
            }
            const responseMessage = createFunctionOutputMessage(name, "", false);
            const id = idForMessage(responseMessage);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = responseMessage;
            commandExecutionProc.message = responseMessage;
            commandExecutionProc.baseMessageContent = responseMessage.content;
            commandExecutionProc.shellCommand = `bash ~/.config/quickshell/scripts/ai-search.sh "${args.query.replace(/"/g, '\\"')}"`;
            commandExecutionProc.running = true;
        } else if (name === "remember") {
            const content = args.content || "";
            if (!content) {
                addFunctionOutputMessage(name, "Invalid: content is required");
                requester.makeRequest();
                return;
            }
            // Also keep file-based memory for system prompt injection
            const existing = memoryFileView.text() || "";
            const timestamp = new Date().toISOString().split("T")[0];
            const newEntry = existing.trim().length > 0
                ? `${existing.trim()}\n- [${timestamp}] ${content}`
                : `- [${timestamp}] ${content}`;
            memoryFileView.setText(newEntry);
            // Store in SQLite with embedding
            const memMsg = createFunctionOutputMessage(name, "", false);
            const memId = idForMessage(memMsg);
            root.messageIDs = [...root.messageIDs, memId];
            root.messageByID[memId] = memMsg;
            commandExecutionProc.message = memMsg;
            commandExecutionProc.baseMessageContent = memMsg.content;
            commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" store user ${JSON.stringify(content)} 2>&1`;
            commandExecutionProc.running = true;
            return;
        } else if (name === "create_todo") {
            const title = args.title || "";
            if (!title) {
                addFunctionOutputMessage(name, "Invalid: title is required");
                requester.makeRequest();
                return;
            }
            Todo.addTask(title);
            addFunctionOutputMessage(name, `To-do added: "${title}"`);
            requester.makeRequest();
        } else if (name === "get_system_logs") {
            const lines = Math.min(parseInt(args.lines) || 50, 200);
            const filter = args.filter ? `--unit=${args.filter}` : "";
            logsProc.message = message;
            logsProc.command = ["bash", "-c", `journalctl -n ${lines} ${filter} --no-pager --output=short-monotonic 2>&1`];
            logsProc.running = true;
        } else if (name === "control_media") {
            const action = args.action || "status";
            let cmd;
            switch (action) {
                case "play":     cmd = "playerctl play 2>&1 && echo 'Playing'"; break;
                case "pause":    cmd = "playerctl pause 2>&1 && echo 'Paused'"; break;
                case "toggle":   cmd = "playerctl play-pause 2>&1 && playerctl status 2>&1"; break;
                case "next":     cmd = "playerctl next 2>&1 && echo 'Skipped to next'"; break;
                case "previous": cmd = "playerctl previous 2>&1 && echo 'Went to previous'"; break;
                default:         cmd = "playerctl metadata --format '{{artist}} - {{title}} [{{status}}]' 2>&1 || echo 'No media player found'";
            }
            const mediaMsg = createFunctionOutputMessage(name, "", false);
            const mediaId = idForMessage(mediaMsg);
            root.messageIDs = [...root.messageIDs, mediaId];
            root.messageByID[mediaId] = mediaMsg;
            commandExecutionProc.message = mediaMsg;
            commandExecutionProc.baseMessageContent = mediaMsg.content;
            commandExecutionProc.shellCommand = cmd;
            commandExecutionProc.running = true;
        } else if (name === "control_hyprland") {
            const dispatch = args.dispatch || "";
            if (!dispatch) {
                addFunctionOutputMessage(name, "Invalid: dispatch is required");
                requester.makeRequest();
                return;
            }
            const hyprMsg = createFunctionOutputMessage(name, "", false);
            const hyprId = idForMessage(hyprMsg);
            root.messageIDs = [...root.messageIDs, hyprId];
            root.messageByID[hyprId] = hyprMsg;
            commandExecutionProc.message = hyprMsg;
            commandExecutionProc.baseMessageContent = hyprMsg.content;
            commandExecutionProc.shellCommand = `hyprctl dispatch ${dispatch} 2>&1`;
            commandExecutionProc.running = true;
        } else if (name === "forget_memory") {
            const content = args.content || "";
            if (!content) {
                addFunctionOutputMessage(name, "Invalid: content is required");
                requester.makeRequest();
                return;
            }
            // Also remove from file-based memory
            const existing = memoryFileView.text() || "";
            const filtered = existing.split("\n").filter(line => !line.toLowerCase().includes(content.toLowerCase()));
            memoryFileView.setText(filtered.join("\n"));
            // Delete from SQLite by text match
            const fmMsg = createFunctionOutputMessage(name, "", false);
            const fmId = idForMessage(fmMsg);
            root.messageIDs = [...root.messageIDs, fmId];
            root.messageByID[fmId] = fmMsg;
            commandExecutionProc.message = fmMsg;
            commandExecutionProc.baseMessageContent = fmMsg.content;
            commandExecutionProc.shellCommand = `python3 -c "
import sqlite3, sys
db = '${Directories.aiMemoryPath.replace('memory.md', 'memory.db')}'
content = sys.argv[1].lower()
conn = sqlite3.connect(db)
rows = conn.execute('SELECT id, text FROM memories').fetchall()
deleted = 0
for row in rows:
    if content in row[1].lower():
        conn.execute('DELETE FROM memories WHERE id=?', (row[0],))
        deleted += 1
conn.commit()
conn.close()
print(f'Removed {deleted} matching memories for: {sys.argv[1]}')
" ${JSON.stringify(content)} 2>&1`;
            commandExecutionProc.running = true;
            return;
        } else if (name === "export_chat") {
            const ts = new Date().toISOString().replace(/[:.]/g, "-").substring(0, 19);
            const filename = (args.filename || ts).replace(/[^a-zA-Z0-9_\-]/g, "_");
            const lines = root.messageIDs.map(id => {
                const msg = root.messageByID[id];
                if (msg.role === root.interfaceRole) return "";
                const speaker = msg.role === "user" ? "You" : "AI";
                return `## ${speaker}\n\n${msg.rawContent}\n`;
            }).filter(l => l.length > 0);
            const markdown = `# AI Chat Export\n\n${lines.join("\n---\n\n")}`;
            chatExportFile.path = Qt.resolvedUrl(`${Directories.home}/Documents/${filename}.md`);
            chatExportFile.setText(markdown);
            addFunctionOutputMessage(name, `Chat exported to ~/Documents/${filename}.md`);
            requester.makeRequest();
        } else if (name === "control_system") {
            const action = args.action || "";
            const value = args.value || "10";
            let cmd;
            switch (action) {
                case "volume_up":         cmd = `wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ && wpctl get-volume @DEFAULT_AUDIO_SINK@`; break;
                case "volume_down":       cmd = `wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && wpctl get-volume @DEFAULT_AUDIO_SINK@`; break;
                case "volume_set":        cmd = `wpctl set-volume @DEFAULT_AUDIO_SINK@ ${parseInt(value) / 100} && wpctl get-volume @DEFAULT_AUDIO_SINK@`; break;
                case "volume_get":        cmd = `wpctl get-volume @DEFAULT_AUDIO_SINK@`; break;
                case "brightness_up":     cmd = `brightnessctl set 10%+ && echo "Brightness: $(brightnessctl get)/$(brightnessctl max)"`; break;
                case "brightness_down":   cmd = `brightnessctl set 10%- && echo "Brightness: $(brightnessctl get)/$(brightnessctl max)"`; break;
                case "brightness_set":    cmd = `brightnessctl set ${value}% && echo "Brightness: $(brightnessctl get)/$(brightnessctl max)"`; break;
                case "brightness_get":    cmd = `echo "Brightness: $(brightnessctl get)/$(brightnessctl max)"`; break;
                case "power_profile_get": cmd = `powerprofilesctl get 2>/dev/null || echo 'powerprofilesctl not available'`; break;
                case "power_profile_set": cmd = `powerprofilesctl set ${value} 2>/dev/null && echo "Power profile: ${value}"` ; break;
                default: cmd = `echo 'Unknown action: ${action}'`;
            }
            const sysMsg = createFunctionOutputMessage(name, "", false);
            const sysId = idForMessage(sysMsg);
            root.messageIDs = [...root.messageIDs, sysId];
            root.messageByID[sysId] = sysMsg;
            commandExecutionProc.message = sysMsg;
            commandExecutionProc.baseMessageContent = sysMsg.content;
            commandExecutionProc.shellCommand = cmd;
            commandExecutionProc.running = true;
        } else if (name === "kill_process") {
            const target = args.process || "";
            if (!target) {
                addFunctionOutputMessage(name, "Invalid: process is required");
                requester.makeRequest();
                return;
            }
            const killCmd = `pkill -f "${target.replace(/"/g, '\\"')}" 2>&1 && echo "Killed: ${target}" || echo "No process found: ${target}"`;
            message.functionCall.args.command = killCmd;
            const contentToAppend = `\n\n**Kill process request**\n\n\`\`\`command\n${killCmd}\n\`\`\``;
            message.rawContent += contentToAppend;
            message.content += contentToAppend;
            message.functionPending = true;
        } else if (name === "take_screenshot") {
            const screenshotPath = `${Directories.aiSttTemp}/screenshot.png`;
            const dest = CF.FileUtils.trimFileProtocol(screenshotPath);
            screenshotProc.targetPath = dest;
            screenshotProc.message = message;
            // Capture all monitors, downscale to 1920px wide, output metadata
            const cmd = `
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys
mons=json.loads(os.environ.get("MONITORS","[]"))
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import os, json
dest = os.environ['DEST']
cx   = int(os.environ.get('CX', 0))
cy   = int(os.environ.get('CY', 0))
img  = Image.open(dest).convert('RGBA')
W, H = img.size
cols = 12
rows = max(5, round(cols * H / W))
cell_w = W // cols
cell_h = H // rows
overlay = Image.new('RGBA', (W, H), (0,0,0,0))
draw = ImageDraw.Draw(overlay)
font = None
for p in ['/usr/share/fonts/TTF/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/noto/NotoSans-Bold.ttf']:
    try: font = ImageFont.truetype(p, max(14, min(28, cell_h//8))); break
    except: pass
if font is None: font = ImageFont.load_default()
for row in range(rows):
    for col in range(cols):
        n  = row * cols + col + 1
        x1 = col * cell_w; y1 = row * cell_h
        x2 = x1 + cell_w - 1; y2 = y1 + cell_h - 1
        ccx = x1 + cell_w // 2; ccy = y1 + cell_h // 2
        draw.rectangle([x1,y1,x2,y2], outline=(255,255,255,60), width=1)
        t = str(n)
        bb = draw.textbbox((ccx,ccy), t, font=font, anchor='mm')
        draw.rectangle([bb[0]-3,bb[1]-3,bb[2]+3,bb[3]+3], fill=(0,0,0,150))
        draw.text((ccx,ccy), t, fill=(255,255,255,210), font=font, anchor='mm')
monitors = json.loads(os.environ.get('MONITORS','[]'))
mon_name = os.environ.get('MON_NAME','')
off_x, off_y = 0, 0
if mon_name:
    for m in monitors:
        if m.get('name') == mon_name:
            off_x = m.get('x', 0); off_y = m.get('y', 0); break
else:
    off_x = min((m.get('x',0) for m in monitors), default=0)
    off_y = min((m.get('y',0) for m in monitors), default=0)
cx_img = cx - off_x; cy_img = cy - off_y
r = 18
if 0 <= cx_img < W and 0 <= cy_img < H:
    draw.ellipse([cx_img-r,cy_img-r,cx_img+r,cy_img+r], outline=(255,60,60,230), width=3)
    draw.line([cx_img-26,cy_img,cx_img+26,cy_img], fill=(255,60,60,230), width=2)
    draw.line([cx_img,cy_img-26,cx_img,cy_img+26], fill=(255,60,60,230), width=2)
Image.alpha_composite(img, overlay).convert('RGB').save(dest)
print(f"GRID_META:{W}:{H}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
CURSOR_SS_X=$((\${CX} - \${SS_OFFSET_X}))
CURSOR_SS_Y=$((\${CY} - \${SS_OFFSET_Y}))
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:1"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
            root.requestHideSidebars();
            const _cmd = cmd;
            sidebarHideTimer.pendingAction = () => {
                screenshotProc.command = ["bash", "-c", _cmd];
                screenshotProc.running = true;
            };
            sidebarHideTimer.restart();
        } else if (name === "launch_app") {
            const app = args.app || "";
            if (!app) { addFunctionOutputMessage(name, "Invalid: app is required"); requester.makeRequest(); return; }
            const launchMsg = createFunctionOutputMessage(name, "", false);
            const launchId = idForMessage(launchMsg);
            root.messageIDs = [...root.messageIDs, launchId];
            root.messageByID[launchId] = launchMsg;
            commandExecutionProc.message = launchMsg;
            commandExecutionProc.baseMessageContent = launchMsg.content;
            const appBin = app.split(" ")[0].toLowerCase().replace(/[^a-z0-9_\-]/g, "");
            commandExecutionProc.shellCommand = `hyprctl dispatch exec "${app.replace(/"/g, '\\"')}" 2>&1; sleep 2; pgrep -xi "${appBin}" > /dev/null && echo "Started: ${app}" || echo "Launch command sent but process '${appBin}' not detected. If this is a Steam game, use open_file with its steam://rungameid/APPID URI instead."`;
            commandExecutionProc.running = true;
        } else if (name === "open_file") {
            const path = args.path || "";
            if (!path) { addFunctionOutputMessage(name, "Invalid: path is required"); requester.makeRequest(); return; }
            Quickshell.execDetached(["xdg-open", path]);
            addFunctionOutputMessage(name, `Opened: ${path}`);
            requester.makeRequest();
        } else if (name === "notify") {
            const title = args.title || "AI Assistant";
            const body = args.body || "";
            Quickshell.execDetached(["notify-send", title, body]);
            addFunctionOutputMessage(name, `Notification sent: "${title}"`);
            requester.makeRequest();
        } else if (name === "set_timer") {
            const seconds = Math.max(1, parseInt(args.seconds) || 60);
            const label = args.label || "Timer";
            Quickshell.execDetached(["bash", "-c",
                `(sleep ${seconds} && notify-send "Timer: ${label.replace(/"/g, '\\"')}" "Time's up!" --urgency=normal) &`
            ]);
            addFunctionOutputMessage(name, `Timer set: ${label} in ${seconds}s`);
            requester.makeRequest();
        } else if (name === "calculate") {
            const expression = args.expression || "";
            if (!expression) { addFunctionOutputMessage(name, "Invalid: expression is required"); requester.makeRequest(); return; }
            const calcMsg = createFunctionOutputMessage(name, "", false);
            const calcId = idForMessage(calcMsg);
            root.messageIDs = [...root.messageIDs, calcId];
            root.messageByID[calcId] = calcMsg;
            commandExecutionProc.message = calcMsg;
            commandExecutionProc.baseMessageContent = calcMsg.content;
            commandExecutionProc.shellCommand = `python3 -c "import math; print(${expression.replace(/"/g, '\\"')})" 2>&1`;
            commandExecutionProc.running = true;
        } else if (name === "pick_color") {
            const colorMsg = createFunctionOutputMessage(name, "", false);
            const colorId = idForMessage(colorMsg);
            root.messageIDs = [...root.messageIDs, colorId];
            root.messageByID[colorId] = colorMsg;
            commandExecutionProc.message = colorMsg;
            commandExecutionProc.baseMessageContent = colorMsg.content;
            commandExecutionProc.shellCommand = `hyprpicker 2>/dev/null || echo 'hyprpicker not installed'`;
            commandExecutionProc.running = true;
        } else if (name === "manage_notes") {
            const action = args.action || "list";
            const content = args.content || "";
            const tags = args.tags || "";
            const mnMsg = createFunctionOutputMessage(name, "", false);
            const mnId = idForMessage(mnMsg);
            root.messageIDs = [...root.messageIDs, mnId];
            root.messageByID[mnId] = mnMsg;
            commandExecutionProc.message = mnMsg;
            commandExecutionProc.baseMessageContent = mnMsg.content;
            if (action === "list" || action === "read") {
                commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" list 50 2>&1`;
            } else if (action === "add") {
                if (!content) { addFunctionOutputMessage(name, "Invalid: content is required for add"); requester.makeRequest(); return; }
                commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" store notes ${JSON.stringify(content)} ${JSON.stringify(tags)} 2>&1`;
            } else if (action === "clear") {
                commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" clear 2>&1`;
            } else {
                addFunctionOutputMessage(name, `Unknown action: ${action}. Use 'list', 'add', or 'clear'.`);
                requester.makeRequest();
                return;
            }
            commandExecutionProc.running = true;
            return;
        } else if (name === "search_memory") {
            const query = args.query || "";
            if (!query) { addFunctionOutputMessage(name, "Invalid: query is required"); requester.makeRequest(); return; }
            const limit = Math.min(parseInt(args.limit) || 5, 20);
            const smMsg = createFunctionOutputMessage(name, "", false);
            const smId = idForMessage(smMsg);
            root.messageIDs = [...root.messageIDs, smId];
            root.messageByID[smId] = smMsg;
            commandExecutionProc.message = smMsg;
            commandExecutionProc.baseMessageContent = smMsg.content;
            commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" search ${JSON.stringify(query)} ${limit} 2>&1`;
            commandExecutionProc.running = true;
            return;
        } else if (name === "schedule_task") {
            const action = args.action || "list";
            const stMsg = createFunctionOutputMessage(name, "", false);
            const stId = idForMessage(stMsg);
            root.messageIDs = [...root.messageIDs, stId];
            root.messageByID[stId] = stMsg;
            commandExecutionProc.message = stMsg;
            commandExecutionProc.baseMessageContent = stMsg.content;
            if (action === "add") {
                const cron = args.cron || "";
                const prompt = args.prompt || "";
                if (!cron || !prompt) { addFunctionOutputMessage(name, "Invalid: cron and prompt required for add"); requester.makeRequest(); return; }
                commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" schedule_add ${JSON.stringify(cron)} ${JSON.stringify(prompt)} 2>&1`;
            } else if (action === "list") {
                commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" schedule_list 2>&1`;
            } else if (action === "delete") {
                const taskId = parseInt(args.id) || 0;
                if (!taskId) { addFunctionOutputMessage(name, "Invalid: id required for delete"); requester.makeRequest(); return; }
                commandExecutionProc.shellCommand = `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" schedule_delete ${taskId} 2>&1`;
            } else {
                addFunctionOutputMessage(name, `Unknown action: ${action}. Use 'add', 'list', or 'delete'.`);
                requester.makeRequest();
                return;
            }
            commandExecutionProc.running = true;
            return;
        } else if (name === "capture_region") {
            const capPath = CF.FileUtils.trimFileProtocol(`${Directories.aiSttTemp}/region_capture.png`);
            regionCaptureProc.targetPath = capPath;
            regionCaptureProc.command = ["bash", "-c",
                `region=$(slurp 2>/dev/null) && [ -n "$region" ] && grim -g "$region" "${capPath}" && echo "ok" || echo "cancelled"`
            ];
            regionCaptureProc.running = true;
        } else if (name === "ocr_region") {
            const ocrImg = CF.FileUtils.trimFileProtocol(`${Directories.aiSttTemp}/ocr_capture.png`);
            const ocrOut = CF.FileUtils.trimFileProtocol(`${Directories.aiSttTemp}/ocr_out`);
            const ocrMsg = createFunctionOutputMessage(name, "", false);
            const ocrId = idForMessage(ocrMsg);
            root.messageIDs = [...root.messageIDs, ocrId];
            root.messageByID[ocrId] = ocrMsg;
            commandExecutionProc.message = ocrMsg;
            commandExecutionProc.baseMessageContent = ocrMsg.content;
            commandExecutionProc.shellCommand = `region=$(slurp 2>/dev/null) && [ -n "$region" ] && grim -g "$region" "${ocrImg}" && tesseract "${ocrImg}" "${ocrOut}" 2>/dev/null && cat "${ocrOut}.txt" || echo 'Cancelled or missing tools (need: slurp, grim, tesseract)'`;
            commandExecutionProc.running = true;
        } else if (name === "speak") {
            const raw = args.text || "";
            if (!raw) { addFunctionOutputMessage(name, "Invalid: text is required"); requester.makeRequest(); return; }
            const escaped = raw.replace(/'/g, "'\\''");
            Quickshell.execDetached(["bash", "-c",
                `espeak-ng '${escaped}' 2>/dev/null || espeak '${escaped}' 2>/dev/null`
            ]);
            addFunctionOutputMessage(name, `Speaking: "${raw.substring(0, 60)}${raw.length > 60 ? "..." : ""}"`);
            requester.makeRequest();
        } else if (name === "read_clipboard_image") {
            const clipPath = CF.FileUtils.trimFileProtocol(`${Directories.aiSttTemp}/clipboard_image.png`);
            clipboardImageProc.targetPath = clipPath;
            clipboardImageProc.command = ["bash", "-c", `wl-paste --type image/png > "${clipPath}" 2>&1 && echo "saved" || echo "no_image"`];
            clipboardImageProc.running = true;
        } else if (name === "click_at") {
            const imgW   = root.lastScreenshotWidth  > 0 ? root.lastScreenshotWidth  : 1920;
            const imgH   = root.lastScreenshotHeight > 0 ? root.lastScreenshotHeight : 1080;
            const scale  = root.lastScreenshotScale  > 0 ? root.lastScreenshotScale  : 1.0;
            const rawX   = parseFloat(args.x) || 0;
            const rawY   = parseFloat(args.y) || 0;
            const button = (args.button || "left").toLowerCase();
            // Scale coords from screenshot space back to real display space
            const sx = Math.max(0, Math.min(Math.round(rawX * scale), imgW)) + root.lastScreenshotOffsetX;
            const sy = Math.max(0, Math.min(Math.round(rawY * scale), imgH)) + root.lastScreenshotOffsetY;
            const ydoBtn = button === "right" ? "3" : button === "middle" ? "2" : "1";
            root._lastClickInfo = `click_at (${rawX}, ${rawY})`;
            addFunctionOutputMessage(name, `Clicking (${rawX}, ${rawY}) → screen (${sx}, ${sy})`);
            // Move mouse and click, then take a new screenshot automatically
            const clickCmd = `sleep 0.15 && ydotool mousemove --absolute -x ${sx} -y ${sy} && ydotool click --button-up --button-down ${ydoBtn}`;
            root.requestHideSidebars();
            Quickshell.execDetached(["bash", "-c", clickCmd]);
            // After click, auto-take a fresh screenshot so the model can see the result
            Qt.callLater(() => {
                const screenshotPath = `${Directories.aiSttTemp}/screenshot.png`;
                const dest = CF.FileUtils.trimFileProtocol(screenshotPath);
                screenshotProc.targetPath = dest;
                const cmd = `
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys
mons=json.loads(os.environ.get("MONITORS","[]"))
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import os, json
dest = os.environ['DEST']
cx   = int(os.environ.get('CX', 0))
cy   = int(os.environ.get('CY', 0))
img  = Image.open(dest).convert('RGBA')
W, H = img.size
cols = 12
rows = max(5, round(cols * H / W))
cell_w = W // cols
cell_h = H // rows
overlay = Image.new('RGBA', (W, H), (0,0,0,0))
draw = ImageDraw.Draw(overlay)
font = None
for p in ['/usr/share/fonts/TTF/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/noto/NotoSans-Bold.ttf']:
    try: font = ImageFont.truetype(p, max(14, min(28, cell_h//8))); break
    except: pass
if font is None: font = ImageFont.load_default()
for row in range(rows):
    for col in range(cols):
        n  = row * cols + col + 1
        x1 = col * cell_w; y1 = row * cell_h
        x2 = x1 + cell_w - 1; y2 = y1 + cell_h - 1
        ccx = x1 + cell_w // 2; ccy = y1 + cell_h // 2
        draw.rectangle([x1,y1,x2,y2], outline=(255,255,255,60), width=1)
        t = str(n)
        bb = draw.textbbox((ccx,ccy), t, font=font, anchor='mm')
        draw.rectangle([bb[0]-3,bb[1]-3,bb[2]+3,bb[3]+3], fill=(0,0,0,150))
        draw.text((ccx,ccy), t, fill=(255,255,255,210), font=font, anchor='mm')
monitors = json.loads(os.environ.get('MONITORS','[]'))
mon_name = os.environ.get('MON_NAME','')
off_x, off_y = 0, 0
if mon_name:
    for m in monitors:
        if m.get('name') == mon_name:
            off_x = m.get('x', 0); off_y = m.get('y', 0); break
else:
    off_x = min((m.get('x',0) for m in monitors), default=0)
    off_y = min((m.get('y',0) for m in monitors), default=0)
cx_img = cx - off_x; cy_img = cy - off_y
r = 18
if 0 <= cx_img < W and 0 <= cy_img < H:
    draw.ellipse([cx_img-r,cy_img-r,cx_img+r,cy_img+r], outline=(255,60,60,230), width=3)
    draw.line([cx_img-26,cy_img,cx_img+26,cy_img], fill=(255,60,60,230), width=2)
    draw.line([cx_img,cy_img-26,cx_img,cy_img+26], fill=(255,60,60,230), width=2)
Image.alpha_composite(img, overlay).convert('RGB').save(dest)
print(f"GRID_META:{W}:{H}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
CURSOR_SS_X=$((\${CX} - \${SS_OFFSET_X}))
CURSOR_SS_Y=$((\${CY} - \${SS_OFFSET_Y}))
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:1"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
                screenshotProc.command = ["bash", "-c", cmd];
                screenshotProc.running = true;
            });
        } else if (name === "click_cell") {
            const cellNum = Math.max(1, parseInt(args.cell) || 1);
            const cols    = root.lastGridCols  > 0 ? root.lastGridCols  : 8;
            const rows    = root.lastGridRows  > 0 ? root.lastGridRows  : 5;
            const imgW    = root.lastScreenshotWidth  > 0 ? root.lastScreenshotWidth  : 3840;
            const imgH    = root.lastScreenshotHeight > 0 ? root.lastScreenshotHeight : 2160;
            const idx     = Math.min(cellNum - 1, cols * rows - 1);
            const col     = idx % cols;
            const row     = Math.floor(idx / cols);
            const rawX    = Math.round(col * (imgW / cols) + (imgW / cols) / 2);
            const rawY    = Math.round(row * (imgH / rows) + (imgH / rows) / 2);
            const button  = (args.button || "left").toLowerCase();
            const ydoBtn  = button === "right" ? "3" : button === "middle" ? "2" : "1";
            const sx = rawX + root.lastScreenshotOffsetX;
            const sy = rawY + root.lastScreenshotOffsetY;
            root._lastClickInfo = `click_cell ${cellNum}`;
            addFunctionOutputMessage(name, `Clicking cell ${cellNum} (row ${row+1}, col ${col+1}) → screen (${sx}, ${sy})`);
            const clickCmd = `sleep 0.15 && ydotool mousemove --absolute -x ${sx} -y ${sy} && ydotool click --button-up --button-down ${ydoBtn}`;
            root.requestHideSidebars();
            Quickshell.execDetached(["bash", "-c", clickCmd]);
            Qt.callLater(() => {
                const screenshotPath = `${Directories.aiSttTemp}/screenshot.png`;
                const dest = CF.FileUtils.trimFileProtocol(screenshotPath);
                screenshotProc.targetPath = dest;
                const cmd = `
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys
mons=json.loads(os.environ.get("MONITORS","[]"))
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import os, json
dest = os.environ['DEST']
cx   = int(os.environ.get('CX', 0))
cy   = int(os.environ.get('CY', 0))
img  = Image.open(dest).convert('RGBA')
W, H = img.size
cols = 12
rows = max(5, round(cols * H / W))
cell_w = W // cols
cell_h = H // rows
overlay = Image.new('RGBA', (W, H), (0,0,0,0))
draw = ImageDraw.Draw(overlay)
font = None
for p in ['/usr/share/fonts/TTF/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf',
          '/usr/share/fonts/noto/NotoSans-Bold.ttf']:
    try: font = ImageFont.truetype(p, max(14, min(28, cell_h//8))); break
    except: pass
if font is None: font = ImageFont.load_default()
for row in range(rows):
    for col in range(cols):
        n  = row * cols + col + 1
        x1 = col * cell_w; y1 = row * cell_h
        x2 = x1 + cell_w - 1; y2 = y1 + cell_h - 1
        ccx = x1 + cell_w // 2; ccy = y1 + cell_h // 2
        draw.rectangle([x1,y1,x2,y2], outline=(255,255,255,60), width=1)
        t = str(n)
        bb = draw.textbbox((ccx,ccy), t, font=font, anchor='mm')
        draw.rectangle([bb[0]-3,bb[1]-3,bb[2]+3,bb[3]+3], fill=(0,0,0,150))
        draw.text((ccx,ccy), t, fill=(255,255,255,210), font=font, anchor='mm')
monitors = json.loads(os.environ.get('MONITORS','[]'))
mon_name = os.environ.get('MON_NAME','')
off_x, off_y = 0, 0
if mon_name:
    for m in monitors:
        if m.get('name') == mon_name:
            off_x = m.get('x', 0); off_y = m.get('y', 0); break
else:
    off_x = min((m.get('x',0) for m in monitors), default=0)
    off_y = min((m.get('y',0) for m in monitors), default=0)
cx_img = cx - off_x; cy_img = cy - off_y
r = 18
if 0 <= cx_img < W and 0 <= cy_img < H:
    draw.ellipse([cx_img-r,cy_img-r,cx_img+r,cy_img+r], outline=(255,60,60,230), width=3)
    draw.line([cx_img-26,cy_img,cx_img+26,cy_img], fill=(255,60,60,230), width=2)
    draw.line([cx_img,cy_img-26,cx_img,cy_img+26], fill=(255,60,60,230), width=2)
Image.alpha_composite(img, overlay).convert('RGB').save(dest)
print(f"GRID_META:{W}:{H}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
CURSOR_SS_X=$((\${CX} - \${SS_OFFSET_X}))
CURSOR_SS_Y=$((\${CY} - \${SS_OFFSET_Y}))
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:1"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
                screenshotProc.command = ["bash", "-c", cmd];
                screenshotProc.running = true;
            });
        } else if (name === "type_text") {
            const text = args.text || "";
            if (!text) { addFunctionOutputMessage(name, "Invalid: text is required"); requester.makeRequest(); return; }
            const escaped = text.replace(/'/g, "'\\''");
            Quickshell.execDetached(["bash", "-c", `ydotool type --key-delay 20 -- '${escaped}'`]);
            addFunctionOutputMessage(name, `Typed: "${text.substring(0, 60)}${text.length > 60 ? "..." : ""}"`);
            requester.makeRequest();
        } else if (name === "press_key") {
            const key = (args.key || "Return").trim();
            // Convert common key names to ydotool key codes
            const keyMap = {
                "Return": "28", "Enter": "28", "Escape": "1", "Tab": "15",
                "space": "57", "BackSpace": "14", "Delete": "111",
                "Up": "103", "Down": "108", "Left": "105", "Right": "106",
                "Home": "102", "End": "107", "Page_Up": "104", "Page_Down": "109",
                "F1":"59","F2":"60","F3":"61","F4":"62","F5":"63","F6":"64",
                "F7":"65","F8":"66","F9":"67","F10":"68","F11":"87","F12":"88",
            };
            // Handle combos like ctrl+a, ctrl+l, ctrl+w
            const parts = key.toLowerCase().split("+");
            const mods = { "ctrl": "29", "shift": "42", "alt": "56", "super": "125", "meta": "125" };
            let keyCodes = [];
            let pressDown = [], pressUp = [];
            for (const part of parts) {
                if (mods[part]) {
                    keyCodes.push(mods[part]);
                } else {
                    const mapped = keyMap[args.key] || keyMap[part];
                    if (mapped) keyCodes.push(mapped);
                    else keyCodes.push("28"); // fallback to Enter
                }
            }
            // Press all down then all up in reverse
            const downArgs = keyCodes.map(c => `--key-codes ${c}`).join(" ");
            Quickshell.execDetached(["bash", "-c", `ydotool key ${keyCodes.map(c => c + ":1").join(" ")} ${keyCodes.reverse().map(c => c + ":0").join(" ")}`]);
            addFunctionOutputMessage(name, `Pressed: ${key}`);
            requester.makeRequest();
        } else if (name === "memory_file") {
            const command = (args.command || "view").trim();
            const rawPath = (args.path || "/memories/").trim();
            if (!rawPath.startsWith("/memories")) {
                addFunctionOutputMessage(name, "Error: path must start with /memories/");
                requester.makeRequest();
                return;
            }
            const memBase = Directories.aiMemoryPath.replace("memory.md", "memories");
            const rel = rawPath.replace(/^\/memories\/?/, "");
            const safePath = rel.length > 0 ? `${memBase}/${rel}` : memBase;
            const memMsg = createFunctionOutputMessage(name, "", false);
            const memId = idForMessage(memMsg);
            root.messageIDs = [...root.messageIDs, memId];
            root.messageByID[memId] = memMsg;
            commandExecutionProc.message = memMsg;
            commandExecutionProc.baseMessageContent = memMsg.content;
            let shellCmd = "";
            if (command === "view") {
                shellCmd = `mkdir -p "${memBase}"; [ -d "${safePath}" ] && (echo "Directory ${rawPath}:"; ls "${safePath}" 2>/dev/null || echo "  (empty)") || ([ -f "${safePath}" ] && cat "${safePath}" || echo "Not found: ${rawPath}")`;
            } else if (command === "create") {
                const b64 = btoa(unescape(encodeURIComponent(args.file_text || "")));
                shellCmd = `mkdir -p "$(dirname "${safePath}")" 2>/dev/null; python3 -c "import base64; open('${safePath}','w').write(base64.b64decode('${b64}').decode('utf-8'))" && echo "Created: ${rawPath}"`;
            } else if (command === "str_replace") {
                const b64Old = btoa(unescape(encodeURIComponent(args.old_str || "")));
                const b64New = btoa(unescape(encodeURIComponent(args.new_str || "")));
                shellCmd = `python3 -c "
import base64
old=base64.b64decode('${b64Old}').decode()
new=base64.b64decode('${b64New}').decode()
with open('${safePath}') as f: c=f.read()
if old not in c: print('Error: text not found in file'); exit(1)
with open('${safePath}','w') as f: f.write(c.replace(old,new,1))
print('Updated: ${rawPath}')
" 2>&1`;
            } else if (command === "insert") {
                const insertLine = parseInt(args.insert_line) || 0;
                const b64Text = btoa(unescape(encodeURIComponent(args.insert_text || "")));
                shellCmd = `python3 -c "
import base64
text=base64.b64decode('${b64Text}').decode()
with open('${safePath}') as f: lines=f.readlines()
lines.insert(${insertLine}, text if text.endswith('\\\\n') else text+'\\\\n')
with open('${safePath}','w') as f: f.writelines(lines)
print('Inserted at line ${insertLine}: ${rawPath}')
" 2>&1`;
            } else if (command === "delete") {
                shellCmd = `rm -rf "${safePath}" && echo "Deleted: ${rawPath}" || echo "Not found: ${rawPath}"`;
            } else {
                addFunctionOutputMessage(name, `Unknown command: ${command}. Use: view, create, str_replace, insert, delete`);
                requester.makeRequest();
                return;
            }
            commandExecutionProc.shellCommand = shellCmd;
            commandExecutionProc.running = true;
        } else if (name === "scroll") {
            const dir = (args.direction || "down").toLowerCase();
            const amount = Math.min(Math.max(parseInt(args.amount) || 3, 1), 20);
            let ax = 0, ay = 0;
            if (dir === "up") ay = -amount;
            else if (dir === "down") ay = amount;
            else if (dir === "left") ax = -amount;
            else if (dir === "right") ax = amount;
            Quickshell.execDetached(["bash", "-c", `ydotool mousescroll --axis-x ${ax} --axis-y ${ay}`]);
            addFunctionOutputMessage(name, `Scrolled ${dir} ${amount} step(s)`);
            requester.makeRequest();
        } else if (name === "read_clipboard_text") {
            const clipMsg = createFunctionOutputMessage(name, "", false);
            const clipId = idForMessage(clipMsg);
            root.messageIDs = [...root.messageIDs, clipId];
            root.messageByID[clipId] = clipMsg;
            commandExecutionProc.message = clipMsg;
            commandExecutionProc.baseMessageContent = clipMsg.content;
            commandExecutionProc.shellCommand = `wl-paste 2>/dev/null || echo "(clipboard is empty)"`;
            commandExecutionProc.running = true;
        } else if (name === "write_clipboard") {
            const text = args.text || "";
            if (!text) { addFunctionOutputMessage(name, "Invalid: text is required"); requester.makeRequest(); return; }
            const clipMsg = createFunctionOutputMessage(name, "", false);
            const clipId = idForMessage(clipMsg);
            root.messageIDs = [...root.messageIDs, clipId];
            root.messageByID[clipId] = clipMsg;
            commandExecutionProc.message = clipMsg;
            commandExecutionProc.baseMessageContent = clipMsg.content;
            commandExecutionProc.shellCommand = `printf '%s' ${JSON.stringify(text)} | wl-copy 2>&1 && echo "Copied to clipboard"`;
            commandExecutionProc.running = true;
        } else if (name === "search_app") {
            const app = (args.app || "").toLowerCase().replace(/[_\s]/g, "");
            const query = args.query || "";
            if (!query) { addFunctionOutputMessage(name, "Invalid: query is required"); requester.makeRequest(); return; }
            const encoded = encodeURIComponent(query);
            let uri;
            switch (app) {
                case "spotify":       uri = `spotify:search:${encoded}`; break;
                case "youtube":       uri = `https://youtube.com/search?q=${encoded}`; break;
                case "youtubemusic":  uri = `https://music.youtube.com/search?q=${encoded}`; break;
                case "soundcloud":    uri = `https://soundcloud.com/search?q=${encoded}`; break;
                case "twitch":        uri = `https://twitch.tv/search?term=${encoded}`; break;
                case "bandcamp":      uri = `https://bandcamp.com/search?q=${encoded}`; break;
                case "reddit":        uri = `https://reddit.com/search?q=${encoded}`; break;
                case "github":        uri = `https://github.com/search?q=${encoded}`; break;
                case "files": {
                    const filesMsg = createFunctionOutputMessage(name, "", false);
                    const filesId = idForMessage(filesMsg);
                    root.messageIDs = [...root.messageIDs, filesId];
                    root.messageByID[filesId] = filesMsg;
                    commandExecutionProc.message = filesMsg;
                    commandExecutionProc.baseMessageContent = filesMsg.content;
                    commandExecutionProc.shellCommand = `find "$HOME" -iname "*${query.replace(/"/g, '\\"')}*" -not -path '*/.git/*' 2>/dev/null | head -20`;
                    commandExecutionProc.running = true;
                    return;
                }
                default: uri = `https://google.com/search?q=${encoded}+site:${app}`; break;
            }
            Quickshell.execDetached(["xdg-open", uri]);
            // For native apps (Spotify etc), auto-screenshot after load so AI can click results visually
            const isNativeApp = ["spotify"].includes(app);
            if (isNativeApp) {
                addFunctionOutputMessage(name, `Searching ${args.app} for: "${query}" — taking screenshot to show results...`);
                nativeAppSearchTimer.restart();
            } else {
                addFunctionOutputMessage(name, `Searching ${args.app} for: "${query}"`);
                requester.makeRequest();
            }
        } else if (name === "read_url") {
            const url = (args.url || "").trim();
            if (!url) { addFunctionOutputMessage(name, "Error: no URL provided"); requester.makeRequest(); return; }
            const readMsg = createFunctionOutputMessage(name, "", false);
            const readId = idForMessage(readMsg);
            root.messageIDs = [...root.messageIDs, readId];
            root.messageByID[readId] = readMsg;
            commandExecutionProc.message = readMsg;
            commandExecutionProc.baseMessageContent = readMsg.content;
            commandExecutionProc.shellCommand = `
curl -sL --max-time 15 -A "Mozilla/5.0" '${url.replace(/'/g, "'\\''")}' | python3 << 'PYEOF'
import sys, re
from html.parser import HTMLParser

class ElemParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.results = []
        self.title = ""
        self._in_title = False
        self._skip_tags = {"script","style","noscript","svg","head"}
        self._skip_depth = 0
        self._interactive = {"input","button","select","textarea","a","form","label"}

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in self._skip_tags:
            self._skip_depth += 1
            return
        if self._skip_depth: return
        if tag == "title":
            self._in_title = True
        if tag in self._interactive:
            parts = [tag]
            for k in ("id","name","type","placeholder","href","value","aria-label","for"):
                if k in a: parts.append(f'{k}="{a[k]}"')
            txt = " ".join(parts)
            self.results.append(txt)

    def handle_endtag(self, tag):
        if tag in self._skip_tags and self._skip_depth:
            self._skip_depth -= 1
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data

html = sys.stdin.read()
p = ElemParser()
p.feed(html)
print(f"Page: {p.title.strip()}")
print(f"URL: ${url.replace(/'/g, "'\\''")}")
print(f"Elements ({len(p.results)}):")
for e in p.results[:80]:
    print(" ", e)
if len(p.results) > 80:
    print(f"  ... and {len(p.results)-80} more")
PYEOF
`;
            commandExecutionProc.running = true;
            return;
        } else if (name === "execute_js") {
            const js = (args.code || "").trim();
            if (!js) { addFunctionOutputMessage(name, "Error: no JS code provided"); requester.makeRequest(); return; }
            const b64 = btoa(unescape(encodeURIComponent(js)));
            const jsUrl = `javascript:eval(atob('${b64}'))`;
            addFunctionOutputMessage(name, `Executing JS in browser...`);
            // Focus address bar, type JS URL, press Enter
            const execCmd = `
sleep 0.1
wtype -M ctrl l -m ctrl
sleep 0.15
wtype -s 20 ${JSON.stringify(jsUrl)}
sleep 0.05
wtype -k return
`;
            Quickshell.execDetached(["bash", "-c", execCmd]);
            // Auto-screenshot after JS has time to run (2s delay)
            Qt.callLater(() => {
                const dest = "/tmp/quickshell/ai/screenshot.png";
                const cmd = `
mkdir -p /tmp/quickshell/ai
sleep 2
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys
mons=json.loads(os.environ.get("MONITORS","[]"))
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import os, json
dest = os.environ['DEST']
cx   = int(os.environ.get('CX', 0))
cy   = int(os.environ.get('CY', 0))
img  = Image.open(dest).convert('RGBA')
W, H = img.size
cols = 12
rows = max(5, round(cols * H / W))
cell_w = W // cols
cell_h = H // rows
overlay = Image.new('RGBA', (W, H), (0,0,0,0))
draw = ImageDraw.Draw(overlay)
font = None
for p in ['/usr/share/fonts/TTF/DejaVuSans-Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', '/usr/share/fonts/TTF/LiberationSans-Bold.ttf']:
    try: font = ImageFont.truetype(p, max(14, min(28, cell_h//8))); break
    except: pass
if font is None: font = ImageFont.load_default()
for row in range(rows):
    for col in range(cols):
        n  = row * cols + col + 1
        x1 = col * cell_w; y1 = row * cell_h
        x2 = x1 + cell_w - 1; y2 = y1 + cell_h - 1
        ccx = x1 + cell_w // 2; ccy = y1 + cell_h // 2
        draw.rectangle([x1,y1,x2,y2], outline=(255,255,255,60), width=1)
        t = str(n)
        bb = draw.textbbox((ccx,ccy), t, font=font, anchor='mm')
        draw.rectangle([bb[0]-3,bb[1]-3,bb[2]+3,bb[3]+3], fill=(0,0,0,150))
        draw.text((ccx,ccy), t, fill=(255,255,255,210), font=font, anchor='mm')
monitors = json.loads(os.environ.get('MONITORS','[]'))
mon_name = os.environ.get('MON_NAME','')
off_x, off_y = 0, 0
if mon_name:
    for m in monitors:
        if m.get('name') == mon_name:
            off_x = m.get('x', 0); off_y = m.get('y', 0); break
else:
    off_x = min((m.get('x',0) for m in monitors), default=0)
    off_y = min((m.get('y',0) for m in monitors), default=0)
cx_img = cx - off_x; cy_img = cy - off_y
r = 18
if 0 <= cx_img < W and 0 <= cy_img < H:
    draw.ellipse([cx_img-r,cy_img-r,cx_img+r,cy_img+r], outline=(255,60,60,230), width=3)
    draw.line([cx_img-26,cy_img,cx_img+26,cy_img], fill=(255,60,60,230), width=2)
    draw.line([cx_img,cy_img-26,cx_img,cy_img+26], fill=(255,60,60,230), width=2)
Image.alpha_composite(img, overlay).convert('RGB').save(dest)
print(f"GRID_META:{W}:{H}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
CURSOR_SS_X=$((\${CX} - \${SS_OFFSET_X}))
CURSOR_SS_Y=$((\${CY} - \${SS_OFFSET_Y}))
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:1"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
                screenshotProc.targetPath = dest;
                screenshotProc.running = false;
                screenshotProc.command = ["bash", "-c", cmd];
                root.pendingFilePath = dest;
                screenshotProc.running = true;
            });
            return;
        } else if (name === "show_plan") {
            root._turnHadPlan = true;
            const title = args.title || "Task Plan";
            const steps = args.steps || [];
            const stepsText = steps.map((s, i) => `${i + 1}. **${s.description}**${s.tool ? ` *(${s.tool})*` : ""}`).join("\n");
            const approveCmd = `echo "Plan approved — executing ${steps.length} step(s)"`;
            const contentToAppend = `\n\n### 📋 ${title}\n\n${stepsText}\n\n\`\`\`command\n${approveCmd}\n\`\`\``;
            message.rawContent += contentToAppend;
            message.content += contentToAppend;
            message.functionCall.args.command = approveCmd;
            message.functionPending = true;
        } else if (name === "wait_for_app") {
            const app = (args.app || "").replace(/"/g, '\\"');
            const timeout = Math.min(parseInt(args.timeout) || 15, 30);
            const waitMsg = createFunctionOutputMessage(name, "", false);
            const waitId = idForMessage(waitMsg);
            root.messageIDs = [...root.messageIDs, waitId];
            root.messageByID[waitId] = waitMsg;
            commandExecutionProc.message = waitMsg;
            commandExecutionProc.baseMessageContent = waitMsg.content;
            commandExecutionProc.shellCommand = `timeout ${timeout} bash -c 'until pgrep -xi "${app}" > /dev/null 2>&1; do sleep 0.5; done && echo "${app} is ready"' 2>/dev/null || echo "${app} did not start within ${timeout}s"`;
            commandExecutionProc.running = true;
        } else if (name === "exit" || name === "done" || name === "finish") {
            // Model sometimes calls these to signal it's done — silently ignore
        } else root.addMessage(Translation.tr("Unknown function call: %1").arg(name), "assistant");
    }

    Process {
        id: logsProc
        property AiMessageData message
        stdout: StdioCollector {
            onStreamFinished: {
                logsProc.message.functionResponse = this.text;
                logsProc.message.functionName = "get_system_logs";
                requester.makeRequest();
            }
        }
    }

    Process {
        id: screenshotProc
        property string targetPath: ""
        property AiMessageData message
        stdout: StdioCollector {
            onStreamFinished: {
                // Parse CURSOR_POS, GRID, IMAGE_SIZE, IMAGE_SCALE from bash output
                const lines = this.text.split("\n");
                let imgW = 0, imgH = 0, scale = 1.0, curX = -1, curY = -1, gridCols = 8, gridRows = 5, offX = 0, offY = 0;
                for (const line of lines) {
                    if (line.startsWith("CURSOR_POS:")) {
                        const parts = line.split(":");
                        curX = parseInt(parts[1]) || 0;
                        curY = parseInt(parts[2]) || 0;
                    } else if (line.startsWith("GRID:")) {
                        const parts = line.split(":");
                        gridCols = parseInt(parts[1]) || 8;
                        gridRows = parseInt(parts[2]) || 5;
                    } else if (line.startsWith("IMAGE_SIZE:")) {
                        const parts = line.split(":");
                        imgW = parseInt(parts[1]) || 0;
                        imgH = parseInt(parts[2]) || 0;
                    } else if (line.startsWith("IMAGE_SCALE:")) {
                        scale = parseFloat(line.split(":")[1]) || 1.0;
                    } else if (line.startsWith("SCREENSHOT_OFFSET:")) {
                        const parts = line.split(":");
                        offX = parseInt(parts[1]) || 0;
                        offY = parseInt(parts[2]) || 0;
                    }
                }
                root.lastScreenshotWidth  = imgW;
                root.lastScreenshotHeight = imgH;
                root.lastScreenshotScale  = scale;
                root.lastScreenshotOffsetX = offX;
                root.lastScreenshotOffsetY = offY;
                root.lastGridCols = gridCols;
                root.lastGridRows = gridRows;

                const cursorInfo = curX >= 0 ? ` Cursor at (${curX}, ${curY}).` : "";
                const gridInfo = ` Grid: ${gridCols}×${gridRows} (cell size ${(imgW/gridCols)|0}×${(imgH/gridRows)|0}px).`;
                const evalHint = root._lastClickInfo.length > 0
                    ? ` Previous action: ${root._lastClickInfo}. CHECK: did the UI change as expected? If not, try a different approach.`
                    : " Analyze the screenshot now.";
                root._lastClickInfo = "";
                root.pendingFilePath = screenshotProc.targetPath;
                addFunctionOutputMessage("take_screenshot", `Screenshot taken (${imgW}×${imgH}).${cursorInfo}${gridInfo}${evalHint}`);
                requester.makeRequest();
            }
        }
    }

    FileView {
        id: notesFileView
        path: Qt.resolvedUrl(Directories.aiMemoryPath.replace("memory.md", "notes.json"))
        blockLoading: true
        watchChanges: false
    }

    function chatToJson() {
        return root.messageIDs.map(id => {
            const message = root.messageByID[id]
            return ({
                "role": message.role,
                "rawContent": message.rawContent,
                "fileMimeType": message.fileMimeType,
                "fileUri": message.fileUri,
                "localFilePath": message.localFilePath,
                "model": message.model,
                "thinking": false,
                "done": true,
                "annotations": message.annotations,
                "annotationSources": message.annotationSources,
                "functionName": message.functionName,
                "functionCall": message.functionCall,
                "functionResponse": message.functionResponse,
                "visibleToUser": message.visibleToUser,
            })
        })
    }

    FileView {
        id: chatSaveFile
        property string chatName: ""
        path: chatName.length > 0 ? `${Directories.aiChats}/${chatName}.json` : ""
        blockLoading: true // Prevent race conditions
    }

    FileView {
        id: chatExportFile
        blockLoading: true
    }

    Process {
        id: regionCaptureProc
        property string targetPath: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const out = this.text.trim();
                if (!out || out === "cancelled") {
                    addFunctionOutputMessage("capture_region", "Region selection cancelled.");
                    requester.makeRequest();
                    return;
                }
                root.pendingFilePath = regionCaptureProc.targetPath;
                addFunctionOutputMessage("capture_region", "Region captured. Now analyzing...");
                requester.makeRequest();
            }
        }
    }

    Process {
        id: clipboardImageProc
        property string targetPath: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const out = this.text.trim();
                if (!out || out === "no_image") {
                    addFunctionOutputMessage("read_clipboard_image", "No image found in clipboard.");
                    requester.makeRequest();
                    return;
                }
                root.pendingFilePath = clipboardImageProc.targetPath;
                addFunctionOutputMessage("read_clipboard_image", "Clipboard image attached. Now analyzing...");
                requester.makeRequest();
            }
        }
    }

    Process {
        id: windowListProc
        running: true
        command: ["bash", "-c", "hyprctl clients -j 2>/dev/null | jq -r '.[].title + \" (\" + .class + \")\"' 2>/dev/null | head -15 | tr '\\n' ',' | sed 's/,$//'" ]
        stdout: StdioCollector {
            onStreamFinished: root.openWindowsList = this.text.trim()
        }
    }

    Process {
        id: mediaContextProc
        running: true
        command: ["bash", "-c", "playerctl metadata --format '{{artist}} - {{title}}' 2>/dev/null || echo ''"]
        stdout: StdioCollector {
            onStreamFinished: root.currentMediaTitle = this.text.trim()
        }
    }

    Timer {
        id: contextRefreshTimer
        running: true
        repeat: true
        interval: 10000
        onTriggered: {
            windowListProc.running = true;
            mediaContextProc.running = true;
        }
    }

    // Auto-screenshot after native app search (e.g. Spotify) so AI can click results
    Timer {
        id: nativeAppSearchTimer
        interval: 2500
        repeat: false
        onTriggered: {
            const dest = CF.FileUtils.trimFileProtocol(`${Directories.aiSttTemp}/screenshot.png`);
            const cmd = `
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys
mons=json.loads(os.environ.get("MONITORS","[]"))
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import os, json
dest = os.environ['DEST']
cx   = int(os.environ.get('CX', 0))
cy   = int(os.environ.get('CY', 0))
img  = Image.open(dest).convert('RGBA')
W, H = img.size
cols = 12
rows = max(5, round(cols * H / W))
cell_w = W // cols
cell_h = H // rows
overlay = Image.new('RGBA', (W, H), (0,0,0,0))
draw = ImageDraw.Draw(overlay)
font = None
for p in ['/usr/share/fonts/TTF/DejaVuSans-Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', '/usr/share/fonts/TTF/LiberationSans-Bold.ttf']:
    try: font = ImageFont.truetype(p, max(14, min(28, cell_h//8))); break
    except: pass
if font is None: font = ImageFont.load_default()
for row in range(rows):
    for col in range(cols):
        n  = row * cols + col + 1
        x1 = col * cell_w; y1 = row * cell_h
        x2 = x1 + cell_w - 1; y2 = y1 + cell_h - 1
        ccx = x1 + cell_w // 2; ccy = y1 + cell_h // 2
        draw.rectangle([x1,y1,x2,y2], outline=(255,255,255,60), width=1)
        t = str(n)
        bb = draw.textbbox((ccx,ccy), t, font=font, anchor='mm')
        draw.rectangle([bb[0]-3,bb[1]-3,bb[2]+3,bb[3]+3], fill=(0,0,0,150))
        draw.text((ccx,ccy), t, fill=(255,255,255,210), font=font, anchor='mm')
monitors = json.loads(os.environ.get('MONITORS','[]'))
mon_name = os.environ.get('MON_NAME','')
off_x, off_y = 0, 0
if mon_name:
    for m in monitors:
        if m.get('name') == mon_name:
            off_x = m.get('x', 0); off_y = m.get('y', 0); break
else:
    off_x = min((m.get('x',0) for m in monitors), default=0)
    off_y = min((m.get('y',0) for m in monitors), default=0)
cx_img = cx - off_x; cy_img = cy - off_y
r = 18
if 0 <= cx_img < W and 0 <= cy_img < H:
    draw.ellipse([cx_img-r,cy_img-r,cx_img+r,cy_img+r], outline=(255,60,60,230), width=3)
    draw.line([cx_img-26,cy_img,cx_img+26,cy_img], fill=(255,60,60,230), width=2)
    draw.line([cx_img,cy_img-26,cx_img,cy_img+26], fill=(255,60,60,230), width=2)
Image.alpha_composite(img, overlay).convert('RGB').save(dest)
print(f"GRID_META:{W}:{H}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
CURSOR_SS_X=$((\${CX} - \${SS_OFFSET_X}))
CURSOR_SS_Y=$((\${CY} - \${SS_OFFSET_Y}))
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:1"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
            root.requestHideSidebars();
            screenshotProc.targetPath = dest;
            screenshotProc.running = false;
            screenshotProc.command = ["bash", "-c", cmd];
            root.pendingFilePath = dest;
            screenshotProc.running = true;
        }
    }

    // Background job scheduler — checks for due cron tasks every 60s
    Process {
        id: schedulerCheckProc
        property string dueLine: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = this.text.trim().split("\n");
                for (const line of lines) {
                    if (line.startsWith("DUE:")) {
                        const parts = line.split(":");
                        const taskId = parts[1];
                        const prompt = parts.slice(2).join(":");
                        // Mark as ran then fire the prompt as a user message
                        schedulerMarkProc.command = ["bash", "-c",
                            `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" schedule_ran ${taskId}`];
                        schedulerMarkProc.running = true;
                        root.addMessage(prompt, "user");
                    }
                }
            }
        }
    }

    Process { id: schedulerMarkProc }

    Timer {
        id: schedulerTimer
        running: true
        repeat: true
        interval: 60000
        onTriggered: {
            schedulerCheckProc.command = ["bash", "-c",
                `python3 "${Directories.aiMemoryPath.replace('memory.md', 'memory.py')}" schedule_due 2>/dev/null`];
            schedulerCheckProc.running = true;
        }
    }

    /**
     * Saves chat to a JSON list of message objects.
     * @param chatName name of the chat
     */
    function saveChat(chatName) {
        chatSaveFile.chatName = chatName.trim()
        const saveContent = JSON.stringify(root.chatToJson())
        chatSaveFile.setText(saveContent)
        getSavedChats.running = true;
    }

    /**
     * Loads chat from a JSON list of message objects.
     * @param chatName name of the chat
     */
    function loadChat(chatName) {
        try {
            chatSaveFile.chatName = chatName.trim()
            chatSaveFile.reload()
            const saveContent = chatSaveFile.text()
            // console.log(saveContent)
            const saveData = JSON.parse(saveContent)
            root.clearMessages()
            root.messageIDs = saveData.map((_, i) => {
                return i
            })
            // console.log(JSON.stringify(messageIDs))
            for (let i = 0; i < saveData.length; i++) {
                const message = saveData[i];
                root.messageByID[i] = root.aiMessageComponent.createObject(root, {
                    "role": message.role,
                    "rawContent": message.rawContent,
                    "content": message.rawContent,
                    "fileMimeType": message.fileMimeType,
                    "fileUri": message.fileUri,
                    "localFilePath": message.localFilePath,
                    "model": message.model,
                    "thinking": message.thinking,
                    "done": message.done,
                    "annotations": message.annotations,
                    "annotationSources": message.annotationSources,
                    "functionName": message.functionName,
                    "functionCall": message.functionCall,
                    "functionResponse": message.functionResponse,
                    "visibleToUser": message.visibleToUser,
                });
            }
        } catch (e) {
            console.log("[AI] Could not load chat: ", e);
        } finally {
            getSavedChats.running = true;
        }
    }
}
