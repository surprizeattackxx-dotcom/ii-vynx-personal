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
                    "description": "Execute a bash command and return its output. IMPORTANT: This requires user approval before execution. Only use for quick, non-interactive commands (queries, checks, simple operations). For interactive commands, long-running processes, or dangerous operations, ask the user to run them manually instead. The command will be shown to the user for approval.",
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
                    "description": "Save a piece of information to persistent memory across sessions. Use when the user asks you to remember something, or when you learn an important preference or fact about them.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "content": {
                                "type": "string",
                                "description": "The information to remember, written in third person (e.g., 'User prefers dark mode')"
                            }
                        },
                        "required": ["content"]
                    }
                },
                {
                    "name": "create_todo",
                    "description": "Add a new task to the user's to-do list. Use when the user asks to be reminded of something or wants to track a task. Don't ask for permission, run directly.",
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
                    "description": "Control media playback via MPRIS/playerctl. Use for play, pause, skip, or get what's currently playing. Runs automatically without approval.",
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
                    "description": "Control Hyprland window manager. Switch workspaces, focus windows, move windows, etc. Runs automatically without approval.",
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
                    "description": "Take a screenshot of the current screen and attach it to the conversation for analysis. Runs automatically.",
                    "parameters": {}
                },
                {
                    "name": "launch_app",
                    "description": "Launch an application. Runs automatically without approval.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "app": {
                                "type": "string",
                                "description": "Application command or name to launch (e.g. 'firefox', 'dolphin', 'spotify')"
                            }
                        },
                        "required": ["app"]
                    }
                },
                {
                    "name": "open_file",
                    "description": "Open a file or URL with the default application via xdg-open. Runs automatically without approval.",
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
                    "description": "Send a desktop notification popup. Use to alert the user after completing a task. Runs automatically.",
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
                    "description": "Set a countdown timer that fires a desktop notification when it expires. Runs automatically.",
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
                    "description": "Evaluate a math expression and return the result. Supports Python math syntax. Runs automatically.",
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
                    "description": "Read or write persistent notes. Use to save information the user wants to keep, or read back saved notes.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'list', 'add', 'clear'" },
                            "content": { "type": "string", "description": "Note content for 'add' action" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "capture_region",
                    "description": "Open an interactive region selector so the user can draw a box around part of their screen. Captures that region as an image and attaches it for visual analysis. Use when the user wants to analyze, read, or describe a specific part of their screen.",
                    "parameters": {}
                },
                {
                    "name": "ocr_region",
                    "description": "Open an interactive region selector, capture that area of the screen, and extract text from it using OCR. Returns the text found. Use when the user wants to copy or read text from an image or part of the screen.",
                    "parameters": {}
                },
                {
                    "name": "speak",
                    "description": "Read text aloud using text-to-speech. Use when the user asks you to read something out loud or narrate a response.",
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
                    "name": "show_plan",
                    "description": "Before executing any multi-step task (2+ actions, app launching, system changes), present a numbered plan to the user and wait for their approval. After approval, execute each step in order using the appropriate tools. Always use this for complex or chained tasks.",
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
                        "description": "Search the web for current information, news, or facts beyond your knowledge cutoff. Use this whenever the user asks about recent events or anything that may have changed.",
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
                        "description": "Save a piece of information to persistent memory across sessions.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "content": { "type": "string", "description": "Information to remember in third person" }
                            },
                            "required": ["content"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "create_todo",
                        "description": "Add a task to the user's to-do list.",
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
                        "description": "Control Hyprland window manager via hyprctl dispatch. Runs automatically without approval.",
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
                        "description": "Launch an application by command name. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "App command to launch (e.g. 'firefox', 'dolphin')" }
                            },
                            "required": ["app"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "open_file",
                        "description": "Open a file or URL with xdg-open. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "File path or URL to open" }
                            },
                            "required": ["path"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "notify",
                        "description": "Send a desktop notification popup. Runs automatically.",
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
                        "description": "Set a countdown timer that fires a desktop notification. Runs automatically.",
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
                        "description": "Evaluate a math expression using Python. Runs automatically.",
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
                        "description": "Read or write persistent notes.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'list', 'add', 'clear'" },
                                "content": { "type": "string", "description": "Note content for 'add' action" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "capture_region",
                        "description": "Open an interactive region selector to capture a specific screen area for visual analysis. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "ocr_region",
                        "description": "Open an interactive region selector, capture that screen area, and extract text via OCR. Returns the text. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "speak",
                        "description": "Read text aloud using text-to-speech. Runs automatically.",
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
                        "description": "Save a piece of information to persistent memory across sessions.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "content": { "type": "string", "description": "Information to remember in third person" }
                            },
                            "required": ["content"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "create_todo",
                        "description": "Add a task to the user's to-do list.",
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
                        "description": "Control Hyprland window manager via hyprctl dispatch. Runs automatically without approval.",
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
                        "description": "Launch an application by command name. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "app": { "type": "string", "description": "App command to launch (e.g. 'firefox', 'dolphin')" }
                            },
                            "required": ["app"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "open_file",
                        "description": "Open a file or URL with xdg-open. Runs automatically.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "File path or URL to open" }
                            },
                            "required": ["path"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "notify",
                        "description": "Send a desktop notification popup. Runs automatically.",
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
                        "description": "Set a countdown timer that fires a desktop notification. Runs automatically.",
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
                        "description": "Evaluate a math expression using Python. Runs automatically.",
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
                        "description": "Read or write persistent notes.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'list', 'add', 'clear'" },
                                "content": { "type": "string", "description": "Note content for 'add' action" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "capture_region",
                        "description": "Open an interactive region selector to capture a specific screen area for visual analysis. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "ocr_region",
                        "description": "Open an interactive region selector, capture that screen area, and extract text via OCR. Returns the text. Runs automatically.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "speak",
                        "description": "Read text aloud using text-to-speech. Runs automatically.",
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

    Component.onCompleted: {
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
                    root.modelsOfProviders = Object.assign({}, root.modelsOfProviders, {
                        "ollama": dataJson.map(model => ({
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
            root.saveChat("lastSession")
            root.responseFinished()
        }

        function makeRequest() {
            const model = models[currentModelId];

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
            const data = root.currentApiStrategy.buildRequestData(model, filteredMessageArray, root.systemPrompt, root.temperature, root.tools[model.api_format][root.currentTool], root.pendingFilePath);
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
            scriptRequestContent += `curl --no-buffer "${endpoint}"`
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

    function sendUserMessage(message) {
        if (message.length === 0) return;
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
            requester.makeRequest(); // Continue
        }
    }

    function handleFunctionCall(name, args: var, message: AiMessageData) {
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
            const existing = memoryFileView.text() || "";
            const timestamp = new Date().toISOString().split("T")[0];
            const newEntry = existing.trim().length > 0
                ? `${existing.trim()}\n- [${timestamp}] ${content}`
                : `- [${timestamp}] ${content}`;
            memoryFileView.setText(newEntry);
            addFunctionOutputMessage(name, `Memory saved: "${content}"`);
            requester.makeRequest();
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
            const existing = memoryFileView.text() || "";
            const filtered = existing.split("\n").filter(line => !line.toLowerCase().includes(content.toLowerCase()));
            memoryFileView.setText(filtered.join("\n"));
            addFunctionOutputMessage(name, `Memory entry removed: "${content}"`);
            requester.makeRequest();
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
            screenshotProc.targetPath = CF.FileUtils.trimFileProtocol(screenshotPath);
            screenshotProc.message = message;
            screenshotProc.command = ["bash", "-c", `grim "${CF.FileUtils.trimFileProtocol(screenshotPath)}" 2>&1`];
            screenshotProc.running = true;
        } else if (name === "launch_app") {
            const app = args.app || "";
            if (!app) { addFunctionOutputMessage(name, "Invalid: app is required"); requester.makeRequest(); return; }
            Quickshell.execDetached(["bash", "-c", `hyprctl dispatch exec "${app.replace(/"/g, '\\"')}" 2>&1`]);
            addFunctionOutputMessage(name, `Launched: ${app}`);
            requester.makeRequest();
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
            if (action === "list" || action === "read") {
                const text = notesFileView.text() || "[]";
                try {
                    const notes = JSON.parse(text);
                    const formatted = notes.length === 0 ? "No notes saved." :
                        notes.map((n, i) => `${i + 1}. [${n.timestamp}] ${n.content}`).join("\n");
                    addFunctionOutputMessage(name, formatted);
                } catch(e) {
                    addFunctionOutputMessage(name, text);
                }
                requester.makeRequest();
            } else if (action === "add") {
                if (!content) { addFunctionOutputMessage(name, "Invalid: content is required for add"); requester.makeRequest(); return; }
                let notes = [];
                try { notes = JSON.parse(notesFileView.text() || "[]"); } catch(e) {}
                notes.push({ timestamp: new Date().toISOString().split("T")[0], content: content });
                notesFileView.setText(JSON.stringify(notes));
                addFunctionOutputMessage(name, `Note added: "${content}"`);
                requester.makeRequest();
            } else if (action === "clear") {
                notesFileView.setText("[]");
                addFunctionOutputMessage(name, "All notes cleared.");
                requester.makeRequest();
            } else {
                addFunctionOutputMessage(name, `Unknown action: ${action}. Use 'list', 'add', or 'clear'.`);
                requester.makeRequest();
            }
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
            addFunctionOutputMessage(name, `Searching ${args.app} for: "${query}"`);
            requester.makeRequest();
        } else if (name === "show_plan") {
            const title = args.title || "Task Plan";
            const steps = args.steps || [];
            const stepsText = steps.map((s, i) => `${i + 1}. **${s.description}**${s.tool ? ` *(${s.tool})*` : ""}`).join("\n");
            const contentToAppend = `\n\n### 📋 ${title}\n\n${stepsText}\n\n*Approve to execute all steps?*`;
            message.rawContent += contentToAppend;
            message.content += contentToAppend;
            // On approval the existing approveCommand flow runs this, signalling the AI to proceed
            message.functionCall.args.command = `echo "Plan approved — executing ${steps.length} step(s)"`;
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
                root.pendingFilePath = screenshotProc.targetPath;
                addFunctionOutputMessage("take_screenshot", "Screenshot taken. Now analyzing...");
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
