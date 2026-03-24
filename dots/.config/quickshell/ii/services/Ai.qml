pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common.functions as CF
import qs.modules.common
import qs.services
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.services.ai

/**
 * LLM chat service. API formats:
 * - `openai`: OpenAI Chat Completions (also used for Ollama, OpenRouter, Mistral — all OpenAI-compatible).
 * - `gemini`: Google Gemini `streamGenerateContent`.
 */
Singleton {
    id: root

    property Component aiMessageComponent: AiMessageData {}
    property Component aiModelComponent: AiModel {}
    property Component geminiApiStrategy: GeminiApiStrategy {}
    property Component openaiApiStrategy: OpenAiApiStrategy {}
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

    // ── Multi-agent state ──────────────────────────────────────────────────────
    property string activeAgentType: ""       // "" = Aria (coordinator) mode
    property string _pendingAgentResult: ""   // set by return_result, consumed by markDone
    property bool _pendingDesktopAction: false // true while commandExecutionProc runs a desktop action — suppresses premature requestRestoreSidebars
    property var agentCallStack: []           // [{parentAgentType, toolCallId, savedCalls}]
    property var agentMsgIDs: ({})            // agentType -> [id, ...]
    property var agentMsgByID: ({})           // id -> AiMessageData (agent-private, not in UI)

    // Default cloud model for agent escalation — used when local model delegates via call_agent
    readonly property string agentCloudModel: "minimax-m2.7:cloud"

    readonly property var agentDefs: ({
        "desktop": {
            displayName: "Vector",
            emoji: "🖥️",
            useCloudModel: true,
            systemPrompt: "You are Vector, a desktop automation specialist on a Linux/Wayland desktop (Hyprland, 3 monitors). Your job: control the desktop by taking screenshots, clicking UI elements, typing text, scrolling, and launching apps. Always take a screenshot first to see current state. Work step by step, verify each action. When your task is complete, call return_result with a clear summary.",
            toolNames: ["run_task", "take_screenshot", "click_at", "click_cell", "type_text", "press_key",
                        "scroll", "drag_to", "hover", "launch_app", "kill_process", "open_file", "capture_region",
                        "ocr_region", "read_clipboard_text", "write_clipboard", "read_clipboard_image",
                        "read_screen_text", "manage_tabs", "wait_and_screenshot",
                        "control_hyprland", "return_result"]
        },
        "research": {
            displayName: "Scout",
            emoji: "🔍",
            useCloudModel: true,
            systemPrompt: "You are Scout, a research specialist. Your job: search the web, read URLs, and gather accurate information. Be thorough and cite sources. ALWAYS end by calling return_result with your findings — never produce a plain text response without calling return_result first.\n\nIMPORTANT: For any news request (headlines, NPR, BBC, current events), ALWAYS use get_news. Do NOT use read_url for news — most news sites require JavaScript and read_url will return empty results.\n\nFor JavaScript-heavy sites (YouTube, Google, Twitter, Reddit), read_url will return 0 elements — use web_search instead to find URLs and information, then return_result with what you found.",
            toolNames: ["get_news", "web_search", "read_url", "execute_js", "search_app", "calculate", "rag_search", "return_result"]
        },
        "system": {
            displayName: "Forge",
            emoji: "⚙️",
            useCloudModel: true,
            systemPrompt: "You are Forge, a system administration specialist on Linux. Your job: execute shell commands, manage processes, control media, interact with Hyprland, and modify shell config. Be careful with destructive commands. When your task is complete, call return_result with the outcome.",
            toolNames: ["run_task", "run_shell_command", "get_system_logs", "control_media", "control_hyprland",
                        "get_shell_config", "set_shell_config", "calculate", "workspace_layout", "return_result"]
        },
        "personal": {
            displayName: "Sage",
            emoji: "📚",
            useCloudModel: true,
            systemPrompt: "You are Sage, a personal assistant specialist. Your job: manage memory, notes, todos, timers, and scheduled tasks. Organise information clearly. When your task is complete, call return_result with a summary.",
            toolNames: ["remember", "memory_file", "search_memory", "manage_notes",
                        "create_todo", "set_timer", "schedule_task", "kg_store", "kg_query", "calendar", "return_result"]
        }
    })

    // Injected tool definitions (not in static tools property — added dynamically by getActiveTools)
    readonly property var _callAgentDefGemini: ({
        "name": "call_agent",
        "description": "Delegate a task to a specialist agent. Vector=desktop UI/clicking, Scout=deep web research only, Forge=system/shell, Sage=memory/notes/todos. Do NOT use Scout for browser interaction — use execute_js directly. Do NOT use for news (get_news), music (play_music), apps (run_task/open_app), or anything you can do yourself with available tools.",
        "parameters": { "type": "object", "properties": {
            "agent": { "type": "string", "description": "Agent type: 'desktop' (Vector), 'research' (Scout), 'system' (Forge), 'personal' (Sage)" },
            "task":  { "type": "string", "description": "Complete self-contained task description with all required context" }
        }, "required": ["agent", "task"] }
    })
    readonly property var _callAgentDefOai: ({
        "type": "function", "function": {
            "name": "call_agent",
            "description": "Delegate a task to a specialist agent. Vector=desktop UI/clicking, Scout=deep web research only, Forge=system/shell, Sage=memory/notes/todos. Do NOT use Scout for browser interaction — use execute_js directly. Do NOT use for news (get_news), music (play_music), apps (run_task/open_app), or anything you can do yourself with available tools.",
            "parameters": { "type": "object", "properties": {
                "agent": { "type": "string", "description": "Agent type: 'desktop' (Vector), 'research' (Scout), 'system' (Forge), 'personal' (Sage)" },
                "task":  { "type": "string", "description": "Complete self-contained task description with all required context" }
            }, "required": ["agent", "task"] }
        }
    })
    readonly property var _returnResultDefGemini: ({
        "name": "return_result",
        "description": "Signal task completion and return the result to Aria (coordinator). Call this when your task is fully done.",
        "parameters": { "type": "object", "properties": {
            "result": { "type": "string", "description": "Clear summary of what was accomplished or the answer found" }
        }, "required": ["result"] }
    })
    readonly property var _returnResultDefOai: ({
        "type": "function", "function": {
            "name": "return_result",
            "description": "Signal task completion and return the result to Aria (coordinator). Call this when your task is fully done.",
            "parameters": { "type": "object", "properties": {
                "result": { "type": "string", "description": "Clear summary of what was accomplished or the answer found" }
            }, "required": ["result"] }
        }
    })

    // ── Auto-routing tool system ──────────────────────────────────────────────
    // Instead of forcing model to delegate via call_agent, the code detects
    // intent from the user message and gives the model only relevant tools.
    // Small models get focused subsets; cloud/large models get everything.

    property string _lastUserMessageText: ""

    // Tool sets by intent category
    readonly property var _toolSets: ({
        "desktop": ["take_screenshot", "click_at", "click_cell", "type_text", "press_key",
                     "scroll", "drag_to", "hover", "launch_app", "open_file", "wait_for_app",
                     "wait_and_screenshot", "manage_tabs", "read_screen_text"],
        "media":   ["play_music", "control_media"],
        "research":["web_search", "read_url", "get_news", "calculate"],
        "memory":  ["remember", "search_memory", "forget_memory"],
        "system":  ["run_shell_command", "control_hyprland", "kill_process", "get_system_logs"],
        "comms":   ["notify", "speak", "send_message"],
        "clipboard":["read_clipboard_text", "write_clipboard"],
        // Advanced tools — only for large/cloud models
        "advanced":["execute_js", "search_app", "capture_region", "ocr_region",
                    "read_clipboard_image", "memory_file", "kg_store", "kg_query",
                    "rag_search", "rag_index", "schedule_task", "set_timer",
                    "create_todo", "manage_notes", "get_notifications", "reply_notification",
                    "control_system", "get_shell_config", "set_shell_config",
                    "workspace_layout", "open_app", "run_task", "calendar",
                    "pick_color", "export_chat", "call_agent", "show_plan"]
    })

    // Intent detection keywords
    readonly property var _intentKeywords: ({
        "desktop": ["screenshot", "screen", "click", "drag", "open ", "launch", "close ",
                     "tab", "hover", "scroll", "type ", "press ", "file manager", "browser",
                     "window", "app", "application", "desktop"],
        "media":   ["music", "play ", "song", "spotify", "pause", "skip", "shuffle",
                     "next song", "previous", "volume", "queue", "playlist", "album",
                     "artist", "track", "listen"],
        "research":["search", "look up", "find ", "what is", "what are", "who is",
                     "how to", "why ", "news", "article", "website", "url", "google",
                     "calculate", "math"],
        "memory":  ["remember", "recall", "forget", "memory", "you know", "last time",
                     "previously"],
        "system":  ["command", "terminal", "shell", "logs", "process", "kill ",
                     "workspace", "monitor", "volume", "brightness", "shutdown",
                     "reboot", "restart"],
        "comms":   ["notify", "notification", "speak", "say ", "tell ", "message",
                     "send ", "text "],
        "clipboard":["clipboard", "copy", "paste", "copied"]
    })

    // Detect model tier: "small" (<14B local), "medium" (14-30B local), "large" (cloud or 30B+)
    function _getModelTier() {
        const provider = root.currentModelId || "";
        // Cloud providers are always "large"
        if (provider === "openrouter" || provider === "google" || provider === "mistral") return "large";
        // Ollama: parse model name for size hints
        const modelName = (root.currentModel || "").toLowerCase();
        // Check for size indicators in model name
        const sizeMatch = modelName.match(/(\d+)b/);
        if (sizeMatch) {
            const paramB = parseInt(sizeMatch[1]);
            if (paramB >= 30) return "large";
            if (paramB >= 14) return "medium";
            return "small";
        }
        // No size in name — assume small for safety
        return "small";
    }

    // Detect intents from user message
    function _detectIntents(message) {
        const msg = message.toLowerCase();
        const detected = [];
        const intentKeys = Object.keys(root._intentKeywords);
        for (let i = 0; i < intentKeys.length; i++) {
            const intent = intentKeys[i];
            const keywords = root._intentKeywords[intent];
            for (let k = 0; k < keywords.length; k++) {
                if (msg.includes(keywords[k])) {
                    detected.push(intent);
                    break; // One match per intent is enough
                }
            }
        }
        // Default: if nothing detected, give desktop + research (most common)
        if (detected.length === 0) detected.push("desktop", "research");
        return detected;
    }

    // Build tool list based on intent + model tier
    function _getToolsForContext() {
        const tier = root._getModelTier();

        // Large models get everything — no filtering
        if (tier === "large") return null; // null = no filtering

        const intents = root._detectIntents(root._lastUserMessageText);
        let toolNames = [];

        // Collect tools from detected intents
        for (let i = 0; i < intents.length; i++) {
            const intentTools = root._toolSets[intents[i]];
            if (intentTools) {
                for (let t = 0; t < intentTools.length; t++) {
                    if (toolNames.indexOf(intentTools[t]) === -1) toolNames.push(intentTools[t]);
                }
            }
        }

        // Medium models also get clipboard + advanced subset
        if (tier === "medium") {
            const extras = root._toolSets["clipboard"].concat([
                "run_task", "open_app", "show_plan", "execute_js", "search_app",
                "control_system", "workspace_layout", "call_agent"
            ]);
            for (let e = 0; e < extras.length; e++) {
                if (toolNames.indexOf(extras[e]) === -1) toolNames.push(extras[e]);
            }
        }

        // Always include clipboard for small models too (very useful)
        const clip = root._toolSets["clipboard"];
        for (let c = 0; c < clip.length; c++) {
            if (toolNames.indexOf(clip[c]) === -1) toolNames.push(clip[c]);
        }

        return toolNames;
    }

    function getActiveTools(apiFormat) {
        const isGemini = (apiFormat === "gemini");

        // Sub-agent mode: filter to agent's tool subset + inject return_result
        if (root.activeAgentType) {
            const agentDef = root.agentDefs[root.activeAgentType];
            if (!agentDef) return root.tools[apiFormat]["none"] || [];
            const toolNames = agentDef.toolNames;
            const allFunctions = root.tools[apiFormat]["functions"];
            if (isGemini) {
                const allDecls = allFunctions[0]?.functionDeclarations || [];
                const filtered = allDecls.filter(t => toolNames.includes(t.name));
                return [{ functionDeclarations: [...filtered, root._returnResultDefGemini] }];
            }
            const filtered = (allFunctions || []).filter(t => toolNames.includes(t.function?.name || t.name));
            return [...filtered, root._returnResultDefOai];
        }

        // Coordinator mode
        const base = root.tools[apiFormat][root.currentTool];
        if (root.currentTool !== "functions") return base;

        // Get context-aware tool filter
        const allowedTools = root._getToolsForContext();

        // All tiers get call_agent — small/medium models can escalate to cloud
        if (isGemini) {
            let decls = base[0]?.functionDeclarations || [];
            if (allowedTools !== null) {
                decls = decls.filter(t => allowedTools.includes(t.name));
            }
            return [{ functionDeclarations: [...decls, root._callAgentDefGemini] }];
        }

        let filtered = base;
        if (allowedTools !== null) {
            filtered = base.filter(t => allowedTools.includes(t.function?.name || t.name));
        }
        return [...filtered, root._callAgentDefOai];
    }

    function _finalizeCurrentAgent(result) {
        if (root.agentCallStack.length === 0) return;
        const frame = root.agentCallStack[root.agentCallStack.length - 1];
        root.agentCallStack = root.agentCallStack.slice(0, -1);
        const agentType = root.activeAgentType;
        const agentDisplay = root.agentDefs[agentType]?.displayName || agentType;
        // Clean up agent message objects
        const ids = root.agentMsgIDs[agentType] || [];
        for (const id of ids) { delete root.agentMsgByID[id]; }
        const newAgentMsgIDs = Object.assign({}, root.agentMsgIDs);
        delete newAgentMsgIDs[agentType];
        root.agentMsgIDs = newAgentMsgIDs;
        // Restore parent context
        root.activeAgentType = frame.parentAgentType;
        root.consecutiveToolCalls = frame.savedCalls;
        // Inject result into parent (coordinator) context
        root._pendingToolCallId = frame.toolCallId;
        root.addFunctionOutputMessage("call_agent", `[${agentDisplay}]: ${result}`);
        requester.makeRequest();
    }
    // ── End multi-agent ────────────────────────────────────────────────────────
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
    property string activityContext: ""

    property var promptSubstitutions: {
        "{DISTRO}": SystemInfo.distroName,
        "{DATETIME}": `${DateTime.time}, ${DateTime.collapsedCalendarFormat}`,
        "{WINDOWCLASS}": ToplevelManager.activeToplevel?.appId ?? "Unknown",
        "{WINDOWTITLE}": ToplevelManager.activeToplevel?.title ?? "Unknown",
        "{CLIPBOARD}": (Quickshell.clipboardText ?? "").substring(0, 300),
        "{DE}": `${SystemInfo.desktopEnvironment} (${SystemInfo.windowingSystem})`,
        "{OPENWINDOWS}": root.openWindowsList,
        "{CURRENTMEDIA}": root.currentMediaTitle,
        "{ACTIVITY}": root.activityContext,
    }

    property string aiMemoryContent: ""
    FileView {
        id: memoryFileView
        path: Directories.aiMemoryPath
        onTextChanged: root.aiMemoryContent = memoryFileView.text() ?? ""
        Component.onCompleted: memoryFileView.reload()
    }

    // Gemini: https://ai.google.dev/gemini-api/docs/function-calling
    // OpenAI-compatible (Ollama, OpenRouter, Mistral, etc.): https://platform.openai.com/docs/guides/function-calling
    // Gemini `functionDeclarations` may include extras (e.g. switch_to_search_mode) not present under tools.openai.
    property string currentTool: Config?.options.ai.tool ?? "search"
    property var tools: {
        "gemini": {
            "functions": [{"functionDeclarations": [
                {
                    "name": "get_news",
                    "description": "Get current news headlines. Use for ANY news request: 'what's in the news', 'NPR today', 'latest on X'. ALWAYS use this instead of read_url for news.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "topic": { "type": "string", "description": "Topic or news source, e.g. 'NPR top stories', 'technology', 'world news'" }
                        },
                        "required": ["topic"]
                    }
                },
                {
                    "name": "play_music",
                    "description": "Spotify music control. Examples: play_music(query='Yung Gravy') to play, play_music(action='shuffle') to toggle shuffle, play_music(action='like') to add current song to Liked Songs, play_music(action='unlike') to remove it. Use for ALL music requests.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": { "type": "string", "description": "Artist, song, album, or playlist name (required for action=play)" },
                            "action": { "type": "string", "description": "Action: 'play' (default), 'shuffle' (toggle shuffle), 'like' (add to Liked Songs), 'unlike' (remove from Liked Songs)" },
                            "service": { "type": "string", "description": "Music service: 'spotify' (default)" }
                        },
                        "required": []
                    }
                },
                {
                    "name": "open_app",
                    "description": "Launch a desktop application by name (via Open Interpreter). For multi-step in-app actions (search, open a channel, play media), use run_task with explicit steps if launch alone is not enough. Not for browser DMs — send_message is separate.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "name": { "type": "string", "description": "Application name, e.g. 'spotify', 'discord', 'firefox'" }
                        },
                        "required": ["name"]
                    }
                },
                {
                    "name": "run_task",
                    "description": "Execute a desktop task autonomously using Open Interpreter (AI code execution engine). Use for: opening apps, controlling Spotify/media, managing files, system control. NOT for browser interaction — use read_url + execute_js to click buttons/inputs on web pages. OI writes and runs Python/bash in a loop until done.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "task": {
                                "type": "string",
                                "description": "What to accomplish. Be specific — include app names, search terms, file paths, etc.",
                            },
                        },
                        "required": ["task"]
                    }
                },
                {
                    "name": "web_search",
                    "description": "Search the web for current information or facts beyond your knowledge cutoff. Use for general web searches.",
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
                    "description": "Take a screenshot for visual analysis ONLY. Do NOT use this to interact with apps — use run_task instead (it's faster and more reliable). Only use take_screenshot when you genuinely need to SEE what's on screen: verifying visual state, reading text/UI you can't get another way, or tasks that truly require visual feedback.",
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
                                "description": "File path or URI to open. IMPORTANT: this parameter is always named 'path', not 'url'. For Steam games use 'steam://rungameid/APPID'"
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
                    "name": "get_notifications",
                    "description": "Read current desktop notifications — incoming messages, alerts, etc. Returns app name, sender, message body, and notification ID. Call this when user wants to reply to a message or asks what notifications they have.",
                    "parameters": { "type": "object", "properties": {} }
                },
                {
                    "name": "reply_notification",
                    "description": "Send an inline reply to a notification (Telegram, WhatsApp, Discord, etc.). Get the notification_id from get_notifications first.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "notification_id": { "type": "number", "description": "The notificationId from get_notifications" },
                            "message": { "type": "string", "description": "The reply text to send" }
                        },
                        "required": ["notification_id", "message"]
                    }
                },
                {
                    "name": "send_message",
                    "description": "Send a message to someone on a browser-based platform. Opens the platform, waits for it to load, then automatically finds the contact and sends the message — no extra tools needed. Just call this once and it handles everything. Example: send_message(to='Alice', message='Hi, are you free tonight?', platform='facebook messenger'). Supports: facebook messenger, telegram, discord, whatsapp, instagram.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "to": { "type": "string", "description": "Recipient name or username" },
                            "message": { "type": "string", "description": "The message to send" },
                            "platform": { "type": "string", "description": "App to use: telegram, discord, whatsapp, email, etc." }
                        },
                        "required": ["to", "message", "platform"]
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
                    "description": "Search stored user preferences and past experience. Use ONLY when the user explicitly asks about their own settings, history, or saved preferences. NEVER call this mid-task or before executing actions — just do the task.",
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
                    "description": "Move the mouse to pixel coordinates (x, y) in the screenshot you just received and click. Coordinates are in the screenshot's pixel space — use the exact values you see in the image. After clicking, a new screenshot is taken automatically. Supports double-click and modifier keys (ctrl+click for multi-select, shift+click for range select).",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                            "y": { "type": "number", "description": "Vertical pixel position in the screenshot" },
                            "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" },
                            "double": { "type": "boolean", "description": "Double-click instead of single click (default false). Use for opening files, selecting words." },
                            "modifiers": { "type": "string", "description": "Hold modifier keys while clicking: 'ctrl', 'shift', 'alt', 'ctrl+shift'. Use ctrl+click for multi-select, shift+click for range select." }
                        },
                        "required": ["x", "y"]
                    }
                },
                {
                    "name": "click_cell",
                    "description": "Click the center of a numbered grid cell from the screenshot overlay. The screenshot is divided into a numbered grid — use the cell number you see in the image to click that region. After clicking, a new screenshot is taken automatically. Supports double-click and modifier keys.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "cell": { "type": "number", "description": "The grid cell number shown in the screenshot overlay" },
                            "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" },
                            "double": { "type": "boolean", "description": "Double-click instead of single click (default false)" },
                            "modifiers": { "type": "string", "description": "Hold modifier keys while clicking: 'ctrl', 'shift', 'alt', 'ctrl+shift'" }
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
                    "description": "Search within a specific app: youtube, reddit, github, files (local filesystem). NOT for playing music — use play_music for Spotify/music requests.",
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
                    "description": "Browser only. Fetch a static web page and return its interactive elements (inputs, buttons, links) with their IDs. Only works on static/server-rendered pages. For JavaScript-heavy sites (YouTube, Google, Facebook, Twitter, Reddit, Instagram, etc.) skip this and use execute_js directly with CSS selectors. NOT for messaging — use send_message. NOT for desktop apps — use run_task or open_app.",
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
                    "description": "Browser only. Execute JavaScript in the active browser tab via the address bar. Use element IDs from read_url: e.g. document.getElementById('search').click(). NOT for desktop apps — use run_task for those. YouTube: after starting a video, turn off repeat — set document.querySelector('video').loop=false and click the loop button off if active. Then STOP (no more execute_js/take_screenshot) unless the user asked to verify; answer in text.",
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
                    "name": "drag_to",
                    "description": "Click and drag from one point to another. Use for sliders, rearranging items, drag-and-drop, selecting text regions, or resizing elements. Coordinates are in screenshot pixel space. Auto-screenshots after.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "x1": { "type": "number", "description": "Start X position (screenshot pixels)" },
                            "y1": { "type": "number", "description": "Start Y position (screenshot pixels)" },
                            "x2": { "type": "number", "description": "End X position (screenshot pixels)" },
                            "y2": { "type": "number", "description": "End Y position (screenshot pixels)" },
                            "button": { "type": "string", "description": "Mouse button: 'left' (default) or 'right'" }
                        },
                        "required": ["x1", "y1", "x2", "y2"]
                    }
                },
                {
                    "name": "hover",
                    "description": "Move the mouse to pixel coordinates without clicking. Use to reveal tooltips, dropdown menus, hover states, or preview cards. Auto-screenshots after so you can see what appeared.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                            "y": { "type": "number", "description": "Vertical pixel position in the screenshot" }
                        },
                        "required": ["x", "y"]
                    }
                },
                {
                    "name": "read_screen_text",
                    "description": "OCR: read text from the screen or a specific region without the grid overlay. Faster than take_screenshot when you just need to read text (error messages, prices, status bars). Returns plain text.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number", "description": "Left edge X (screenshot pixels, optional — omit for full screen)" },
                            "y": { "type": "number", "description": "Top edge Y (screenshot pixels, optional)" },
                            "width": { "type": "number", "description": "Region width in pixels (optional)" },
                            "height": { "type": "number", "description": "Region height in pixels (optional)" }
                        }
                    }
                },
                {
                    "name": "manage_tabs",
                    "description": "Control browser tabs. Use to switch between tabs, close tabs, or jump to a specific tab number. Works via keyboard shortcuts in the focused browser.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'next' (ctrl+tab), 'prev' (ctrl+shift+tab), 'close' (ctrl+w), 'goto' (ctrl+N), 'new' (ctrl+t), 'reopen' (ctrl+shift+t)" },
                            "index": { "type": "integer", "description": "Tab number 1-9 for 'goto' action" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "wait_and_screenshot",
                    "description": "Wait a specified number of seconds then take a screenshot. Use when you need to wait for a page to load, animation to finish, or popup to appear before checking the result. Lighter than polling.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "seconds": { "type": "number", "description": "Seconds to wait (1-15, default 3)" },
                            "reason": { "type": "string", "description": "Why you're waiting (shown in output)" }
                        }
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
                {
                    "name": "kg_store",
                    "description": "Store structured knowledge in the knowledge graph. Creates entities (people, projects, concepts, preferences) with typed observations and relations between them. More powerful than 'remember' for interconnected facts. Use for: user preferences with context, project relationships, people and their roles, technical stack mappings.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'entity' (create/update entity), 'relation' (link two entities), 'observe' (add observations to existing entity)" },
                            "name": { "type": "string", "description": "Entity name (for 'entity' and 'observe')" },
                            "entity_type": { "type": "string", "description": "Entity type (for 'entity'): person, project, tool, preference, concept, location, etc." },
                            "observations": { "type": "array", "items": { "type": "string" }, "description": "List of observations/facts about the entity" },
                            "from_entity": { "type": "string", "description": "Source entity name (for 'relation')" },
                            "relation": { "type": "string", "description": "Relation type in active voice (for 'relation'): 'uses', 'prefers', 'works_on', 'depends_on', etc." },
                            "to_entity": { "type": "string", "description": "Target entity name (for 'relation')" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "kg_query",
                    "description": "Query the knowledge graph. Search for entities by keyword, read specific entities with their relations, or view the full graph. Use when you need structured context about the user's world — projects, preferences, relationships between things.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'search' (keyword search), 'read' (read specific entity or full graph), 'delete_entity', 'delete_relation', 'delete_observation'" },
                            "query": { "type": "string", "description": "Search query (for 'search')" },
                            "name": { "type": "string", "description": "Entity name (for 'read', 'delete_entity', 'delete_observation')" },
                            "observation": { "type": "string", "description": "Observation text to remove (for 'delete_observation')" },
                            "from_entity": { "type": "string", "description": "Source entity (for 'delete_relation')" },
                            "relation": { "type": "string", "description": "Relation type (for 'delete_relation')" },
                            "to_entity": { "type": "string", "description": "Target entity (for 'delete_relation')" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "rag_search",
                    "description": "Semantic search over the user's indexed local documents (notes, code, configs, docs). Returns the most relevant chunks with source file paths. Use when the user asks about their own files, projects, or notes, or when you need context from their local documents.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "query": { "type": "string", "description": "What to search for — natural language query" },
                            "limit": { "type": "integer", "description": "Max results to return (default 5)" }
                        },
                        "required": ["query"]
                    }
                },
                {
                    "name": "rag_index",
                    "description": "Index local files or directories for semantic search via rag_search. Supports markdown, text, code files, configs. Skips hidden dirs, node_modules, etc. Re-indexing a file updates it if changed.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "path": { "type": "string", "description": "File or directory path to index (e.g. '~/Documents', '~/projects/myapp')" },
                            "extensions": { "type": "string", "description": "Comma-separated file extensions to include (e.g. '.md,.txt,.py'). Defaults to common text/code extensions." }
                        },
                        "required": ["path"]
                    }
                },
                {
                    "name": "calendar",
                    "description": "Access the user's calendar (synced via Google Calendar). Check schedule, find free time, add events, search upcoming events. Use when the user asks about meetings, schedule, availability, or wants to create/find events.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'today' (today's events), 'list' (next N days), 'now' (current event), 'add' (create event), 'search' (find events by keyword), 'sync' (force sync with Google)" },
                            "days": { "type": "integer", "description": "Number of days to list (for 'list', default 3)" },
                            "query": { "type": "string", "description": "Search query (for 'search')" },
                            "event_args": { "type": "string", "description": "Event arguments for 'add' in khal format: '<start> [end] <summary> [:: description]'. Example: '2026-03-23 14:00 15:00 Team standup :: Weekly sync'" }
                        },
                        "required": ["action"]
                    }
                },
                {
                    "name": "workspace_layout",
                    "description": "Save and restore Hyprland window layouts across workspaces and monitors. Use when the user wants to set up a specific arrangement ('coding layout', 'streaming setup') or save their current window arrangement for later.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action: 'save' (save current layout), 'restore' (apply saved layout), 'list' (show saved layouts), 'delete' (remove layout), 'current' (show current window arrangement)" },
                            "name": { "type": "string", "description": "Layout name (for save/restore/delete)" }
                        },
                        "required": ["action"]
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
                        "name": "get_news",
                        "description": "Get current news headlines. Use for ANY news request: 'what's in the news', 'NPR today', 'latest on X'. ALWAYS use this instead of read_url for news.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "topic": { "type": "string", "description": "Topic or news source, e.g. 'NPR top stories', 'technology', 'world news'" }
                            },
                            "required": ["topic"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "play_music",
                        "description": "Spotify music control. Examples: play_music(query='Yung Gravy') to play, play_music(action='shuffle') to toggle shuffle, play_music(action='like') to add current song to Liked Songs, play_music(action='unlike') to remove it. Use for ALL music requests.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string", "description": "Artist, song, album, or playlist name (required for action=play)" },
                                "action": { "type": "string", "description": "Action: 'play' (default), 'shuffle' (toggle shuffle), 'like' (add to Liked Songs), 'unlike' (remove from Liked Songs)" },
                                "service": { "type": "string", "description": "Music service: 'spotify' (default)" }
                            },
                            "required": []
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "open_app",
                        "description": "Launch a desktop application by name (via Open Interpreter). For multi-step in-app actions (search, open a channel, play media), use run_task with explicit steps if launch alone is not enough. Not for browser DMs — send_message is separate.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "name": { "type": "string", "description": "Application name, e.g. 'spotify', 'discord', 'firefox'" }
                            },
                            "required": ["name"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "run_task",
                        "description": "Execute a desktop task autonomously using Open Interpreter (AI code execution engine). Use for: opening apps, controlling Spotify/media, managing files, system control. NOT for browser interaction — use read_url + execute_js to click buttons/inputs on web pages. OI writes and runs Python/bash in a loop until done.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "task": {
                                    "type": "string",
                                    "description": "What to accomplish. Be specific — include app names, search terms, file paths, etc.",
                                },
                            },
                            "required": ["task"]
                        }
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "web_search",
                        "description": "Search the web for current information or facts beyond your knowledge cutoff. Use for general web searches.",
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
                        "description": "Take a screenshot for visual analysis ONLY. Do NOT use this to interact with apps — use run_task instead (it's faster and more reliable). Only use take_screenshot when you genuinely need to SEE what's on screen: verifying visual state, reading text/UI you can't get another way, or tasks that truly require visual feedback.",
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
                                "path": { "type": "string", "description": "File path or URI to open. IMPORTANT: this parameter is always named 'path', not 'url'. For Steam games use 'steam://rungameid/APPID'" }
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
                        "name": "get_notifications",
                        "description": "Read current desktop notifications — incoming messages, alerts, etc. Returns app name, sender, message body, and notification ID. Call this when user wants to reply to a message or asks what notifications they have.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "reply_notification",
                        "description": "Send an inline reply to a notification (Telegram, WhatsApp, Discord, etc.). Get the notification_id from get_notifications first.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "notification_id": { "type": "number", "description": "The notificationId from get_notifications" },
                                "message": { "type": "string", "description": "The reply text to send" }
                            },
                            "required": ["notification_id", "message"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "send_message",
                        "description": "Send a message to someone on a browser-based platform. Opens the platform, waits for it to load, then automatically finds the contact and sends the message — no extra tools needed. Just call this once and it handles everything. Example: send_message(to='Alice', message='Hi, are you free tonight?', platform='facebook messenger'). Supports: facebook messenger, telegram, discord, whatsapp, instagram.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "to": { "type": "string", "description": "Recipient name or username" },
                                "message": { "type": "string", "description": "The message to send" },
                                "platform": { "type": "string", "description": "App to use: telegram, discord, whatsapp, email, etc." }
                            },
                            "required": ["to", "message", "platform"]
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
                        "description": "Search stored user preferences and past experience. Use ONLY when the user explicitly asks about their own settings, history, or saved preferences. NEVER call this mid-task or before executing actions — just do the task.",
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
                        "description": "Move the mouse to pixel coordinates (x, y) in the screenshot and click. Use the exact pixel values from the screenshot image. After clicking, a fresh screenshot is taken automatically — always check it to verify the UI changed. If the UI did NOT change, do NOT click the same spot again; try a different approach. Supports double-click and modifier keys (ctrl+click for multi-select, shift+click for range select).",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                                "y": { "type": "number", "description": "Vertical pixel position in the screenshot" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" },
                                "double": { "type": "boolean", "description": "Double-click instead of single click (default false). Use for opening files, selecting words." },
                                "modifiers": { "type": "string", "description": "Hold modifier keys while clicking: 'ctrl', 'shift', 'alt', 'ctrl+shift'. Use ctrl+click for multi-select, shift+click for range select." }
                            },
                            "required": ["x", "y"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "click_cell",
                        "description": "Click the center of a numbered grid cell shown in the screenshot overlay. Find the grid number overlaid on the region you want to click. After clicking, a fresh screenshot is taken automatically — verify the UI changed before proceeding. If it did not change, the element may be in a different cell. Supports double-click and modifier keys.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "cell": { "type": "number", "description": "The grid cell number shown in the screenshot overlay" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" },
                                "double": { "type": "boolean", "description": "Double-click instead of single click (default false)" },
                                "modifiers": { "type": "string", "description": "Hold modifier keys while clicking: 'ctrl', 'shift', 'alt', 'ctrl+shift'" }
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
                        "description": "Browser only. Fetch a static web page and return its interactive elements with their IDs. Only works on static/server-rendered pages. For JavaScript-heavy sites (YouTube, Google, Twitter, Reddit, etc.) skip this and use execute_js directly with CSS selectors. NOT for desktop apps — use run_task or open_app for those.",
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
                        "description": "Browser only. Step 2 of 2: execute JavaScript in the active browser tab using element IDs from read_url. NOT for desktop apps — use run_task for those. NOT for visual navigation — use click_at for that. YouTube: after starting a video, turn off repeat — set document.querySelector('video').loop=false and click the loop button off if active. Then STOP (no more execute_js/take_screenshot) unless the user asked to verify; answer in text.",
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
                        "name": "drag_to",
                        "description": "Click and drag from one point to another. Use for sliders, rearranging items, drag-and-drop, selecting text regions, or resizing elements. Coordinates are in screenshot pixel space. Auto-screenshots after.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x1": { "type": "number", "description": "Start X position (screenshot pixels)" },
                                "y1": { "type": "number", "description": "Start Y position (screenshot pixels)" },
                                "x2": { "type": "number", "description": "End X position (screenshot pixels)" },
                                "y2": { "type": "number", "description": "End Y position (screenshot pixels)" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default) or 'right'" }
                            },
                            "required": ["x1", "y1", "x2", "y2"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "hover",
                        "description": "Move the mouse to pixel coordinates without clicking. Use to reveal tooltips, dropdown menus, hover states, or preview cards. Auto-screenshots after so you can see what appeared.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                                "y": { "type": "number", "description": "Vertical pixel position in the screenshot" }
                            },
                            "required": ["x", "y"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_screen_text",
                        "description": "OCR: read text from the screen or a specific region without the grid overlay. Faster than take_screenshot when you just need to read text (error messages, prices, status bars). Returns plain text.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Left edge X (screenshot pixels, optional — omit for full screen)" },
                                "y": { "type": "number", "description": "Top edge Y (screenshot pixels, optional)" },
                                "width": { "type": "number", "description": "Region width in pixels (optional)" },
                                "height": { "type": "number", "description": "Region height in pixels (optional)" }
                            }
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "manage_tabs",
                        "description": "Control browser tabs. Use to switch between tabs, close tabs, or jump to a specific tab number. Works via keyboard shortcuts in the focused browser.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'next' (ctrl+tab), 'prev' (ctrl+shift+tab), 'close' (ctrl+w), 'goto' (ctrl+N), 'new' (ctrl+t), 'reopen' (ctrl+shift+t)" },
                                "index": { "type": "integer", "description": "Tab number 1-9 for 'goto' action" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "wait_and_screenshot",
                        "description": "Wait a specified number of seconds then take a screenshot. Use when you need to wait for a page to load, animation to finish, or popup to appear before checking the result.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "seconds": { "type": "number", "description": "Seconds to wait (1-15, default 3)" },
                                "reason": { "type": "string", "description": "Why you're waiting (shown in output)" }
                            }
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
                {
                    "type": "function",
                    "function": {
                        "name": "kg_store",
                        "description": "Store structured knowledge in the knowledge graph. Creates entities (people, projects, concepts, preferences) with typed observations and relations between them. More powerful than 'remember' for interconnected facts.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'entity' (create/update entity), 'relation' (link two entities), 'observe' (add observations to existing entity)" },
                                "name": { "type": "string", "description": "Entity name (for 'entity' and 'observe')" },
                                "entity_type": { "type": "string", "description": "Entity type: person, project, tool, preference, concept, location, etc." },
                                "observations": { "type": "array", "items": { "type": "string" }, "description": "List of observations/facts about the entity" },
                                "from_entity": { "type": "string", "description": "Source entity name (for 'relation')" },
                                "relation": { "type": "string", "description": "Relation type in active voice: 'uses', 'prefers', 'works_on', etc." },
                                "to_entity": { "type": "string", "description": "Target entity name (for 'relation')" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "kg_query",
                        "description": "Query the knowledge graph. Search for entities, read specific entities with relations, or view the full graph.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'search', 'read', 'delete_entity', 'delete_relation', 'delete_observation'" },
                                "query": { "type": "string", "description": "Search query (for 'search')" },
                                "name": { "type": "string", "description": "Entity name (for 'read', 'delete_entity', 'delete_observation')" },
                                "observation": { "type": "string", "description": "Observation text to remove (for 'delete_observation')" },
                                "from_entity": { "type": "string", "description": "Source entity (for 'delete_relation')" },
                                "relation": { "type": "string", "description": "Relation type (for 'delete_relation')" },
                                "to_entity": { "type": "string", "description": "Target entity (for 'delete_relation')" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "rag_search",
                        "description": "Semantic search over the user's indexed local documents (notes, code, configs). Returns most relevant chunks with source paths.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string", "description": "Natural language search query" },
                                "limit": { "type": "integer", "description": "Max results (default 5)" }
                            },
                            "required": ["query"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "rag_index",
                        "description": "Index local files or directories for semantic search via rag_search. Supports text, code, configs. Re-indexing updates changed files.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "path": { "type": "string", "description": "File or directory path to index" },
                                "extensions": { "type": "string", "description": "Comma-separated extensions (e.g. '.md,.txt,.py')" }
                            },
                            "required": ["path"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "calendar",
                        "description": "Access the user's calendar (Google Calendar via khal). Check schedule, add events, search upcoming.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'today', 'list', 'now', 'add', 'search', 'sync'" },
                                "days": { "type": "integer", "description": "Days to list (default 3)" },
                                "query": { "type": "string", "description": "Search query" },
                                "event_args": { "type": "string", "description": "Event args for 'add': '<start> [end] <summary> [:: description]'" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "workspace_layout",
                        "description": "Save and restore Hyprland window layouts. Save current arrangement or apply a named layout.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'save', 'restore', 'list', 'delete', 'current'" },
                                "name": { "type": "string", "description": "Layout name" }
                            },
                            "required": ["action"]
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
                        "name": "get_news",
                        "description": "Get current news headlines. Use for ANY news request: 'what's in the news', 'NPR today', 'latest on X'. ALWAYS use this instead of read_url for news.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "topic": { "type": "string", "description": "Topic or news source, e.g. 'NPR top stories', 'technology', 'world news'" }
                            },
                            "required": ["topic"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "play_music",
                        "description": "Spotify music control. Examples: play_music(query='Yung Gravy') to play, play_music(action='shuffle') to toggle shuffle, play_music(action='like') to add current song to Liked Songs, play_music(action='unlike') to remove it. Use for ALL music requests.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "query": { "type": "string", "description": "Artist, song, album, or playlist name (required for action=play)" },
                                "action": { "type": "string", "description": "Action: 'play' (default), 'shuffle' (toggle shuffle), 'like' (add to Liked Songs), 'unlike' (remove from Liked Songs)" },
                                "service": { "type": "string", "description": "Music service: 'spotify' (default)" }
                            },
                            "required": []
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "open_app",
                        "description": "Launch a desktop application by name (via Open Interpreter). For multi-step in-app actions (search, open a channel, play media), use run_task with explicit steps if launch alone is not enough. Not for browser DMs — send_message is separate.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "name": { "type": "string", "description": "Application name, e.g. 'spotify', 'discord', 'firefox'" }
                            },
                            "required": ["name"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "run_task",
                        "description": "Execute a desktop task autonomously using Open Interpreter (AI code execution engine). Use for: opening apps, controlling Spotify/media, managing files, system control. NOT for browser interaction — use read_url + execute_js to click buttons/inputs on web pages. OI writes and runs Python/bash in a loop until done.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "task": {
                                    "type": "string",
                                    "description": "What to accomplish. Be specific — include app names, search terms, file paths, etc.",
                                },
                            },
                            "required": ["task"]
                        }
                    },
                },
                {
                    "type": "function",
                    "function": {
                        "name": "web_search",
                        "description": "Search the web for current information or facts beyond your knowledge cutoff. Use for general web searches.",
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
                        "description": "Take a screenshot for visual analysis ONLY. Do NOT use this to interact with apps — use run_task instead. Only use when you need to SEE the screen state.",
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
                                "path": { "type": "string", "description": "File path or URI to open. IMPORTANT: this parameter is always named 'path', not 'url'. For Steam games use 'steam://rungameid/APPID'" }
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
                        "name": "get_notifications",
                        "description": "Read current desktop notifications — incoming messages, alerts, etc. Returns app name, sender, message body, and notification ID. Call this when user wants to reply to a message or asks what notifications they have.",
                        "parameters": { "type": "object", "properties": {} }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "reply_notification",
                        "description": "Send an inline reply to a notification (Telegram, WhatsApp, Discord, etc.). Get the notification_id from get_notifications first.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "notification_id": { "type": "number", "description": "The notificationId from get_notifications" },
                                "message": { "type": "string", "description": "The reply text to send" }
                            },
                            "required": ["notification_id", "message"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "send_message",
                        "description": "Send a message to someone on a browser-based platform. Opens the platform, waits for it to load, then automatically finds the contact and sends the message — no extra tools needed. Just call this once and it handles everything. Example: send_message(to='Alice', message='Hi, are you free tonight?', platform='facebook messenger'). Supports: facebook messenger, telegram, discord, whatsapp, instagram.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "to": { "type": "string", "description": "Recipient name or username" },
                                "message": { "type": "string", "description": "The message to send" },
                                "platform": { "type": "string", "description": "App to use: telegram, discord, whatsapp, email, etc." }
                            },
                            "required": ["to", "message", "platform"]
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
                        "description": "Search stored user preferences and past experience. Use ONLY when the user explicitly asks about their own settings, history, or saved preferences. NEVER call this mid-task or before executing actions — just do the task.",
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
                        "description": "Move the mouse to pixel coordinates (x, y) in the screenshot you just received and click. Coordinates are in the screenshot's pixel space — use the exact values you see in the image. After clicking, a new screenshot is taken automatically. Supports double-click and modifier keys (ctrl+click for multi-select, shift+click for range select).",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                                "y": { "type": "number", "description": "Vertical pixel position in the screenshot" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" },
                                "double": { "type": "boolean", "description": "Double-click instead of single click (default false). Use for opening files, selecting words." },
                                "modifiers": { "type": "string", "description": "Hold modifier keys while clicking: 'ctrl', 'shift', 'alt', 'ctrl+shift'. Use ctrl+click for multi-select, shift+click for range select." }
                            },
                            "required": ["x", "y"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "click_cell",
                        "description": "Click the center of a numbered grid cell from the screenshot overlay. The screenshot is divided into a numbered grid — use the cell number you see in the image to click that region. After clicking, a new screenshot is taken automatically. Supports double-click and modifier keys.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "cell": { "type": "number", "description": "The grid cell number shown in the screenshot overlay" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default), 'right', or 'middle'" },
                                "double": { "type": "boolean", "description": "Double-click instead of single click (default false)" },
                                "modifiers": { "type": "string", "description": "Hold modifier keys while clicking: 'ctrl', 'shift', 'alt', 'ctrl+shift'" }
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
                        "description": "Browser only. Fetch a static web page and return its interactive elements with their IDs. Only works on static/server-rendered pages. For JavaScript-heavy sites (YouTube, Google, Twitter, Reddit, etc.) skip this and use execute_js directly with CSS selectors. NOT for desktop apps — use run_task or open_app for those.",
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
                        "description": "Browser only. Step 2 of 2: execute JavaScript in the active browser tab using element IDs from read_url. NOT for desktop apps — use run_task for those. NOT for visual navigation — use click_at for that. YouTube: after starting a video, turn off repeat — set document.querySelector('video').loop=false and click the loop button off if active. Then STOP (no more execute_js/take_screenshot) unless the user asked to verify; answer in text.",
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
                        "name": "drag_to",
                        "description": "Click and drag from one point to another. Use for sliders, rearranging items, drag-and-drop, selecting text regions, or resizing elements. Coordinates are in screenshot pixel space. Auto-screenshots after.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x1": { "type": "number", "description": "Start X position (screenshot pixels)" },
                                "y1": { "type": "number", "description": "Start Y position (screenshot pixels)" },
                                "x2": { "type": "number", "description": "End X position (screenshot pixels)" },
                                "y2": { "type": "number", "description": "End Y position (screenshot pixels)" },
                                "button": { "type": "string", "description": "Mouse button: 'left' (default) or 'right'" }
                            },
                            "required": ["x1", "y1", "x2", "y2"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "hover",
                        "description": "Move the mouse to pixel coordinates without clicking. Use to reveal tooltips, dropdown menus, hover states, or preview cards. Auto-screenshots after so you can see what appeared.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Horizontal pixel position in the screenshot" },
                                "y": { "type": "number", "description": "Vertical pixel position in the screenshot" }
                            },
                            "required": ["x", "y"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "read_screen_text",
                        "description": "OCR: read text from the screen or a specific region without the grid overlay. Faster than take_screenshot when you just need to read text (error messages, prices, status bars). Returns plain text.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number", "description": "Left edge X (screenshot pixels, optional — omit for full screen)" },
                                "y": { "type": "number", "description": "Top edge Y (screenshot pixels, optional)" },
                                "width": { "type": "number", "description": "Region width in pixels (optional)" },
                                "height": { "type": "number", "description": "Region height in pixels (optional)" }
                            }
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "manage_tabs",
                        "description": "Control browser tabs. Use to switch between tabs, close tabs, or jump to a specific tab number. Works via keyboard shortcuts in the focused browser.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "action": { "type": "string", "description": "Action: 'next' (ctrl+tab), 'prev' (ctrl+shift+tab), 'close' (ctrl+w), 'goto' (ctrl+N), 'new' (ctrl+t), 'reopen' (ctrl+shift+t)" },
                                "index": { "type": "integer", "description": "Tab number 1-9 for 'goto' action" }
                            },
                            "required": ["action"]
                        }
                    }
                },
                {
                    "type": "function",
                    "function": {
                        "name": "wait_and_screenshot",
                        "description": "Wait a specified number of seconds then take a screenshot. Use when you need to wait for a page to load, animation to finish, or popup to appear before checking the result.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "seconds": { "type": "number", "description": "Seconds to wait (1-15, default 3)" },
                                "reason": { "type": "string", "description": "Why you're waiting (shown in output)" }
                            }
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
        // Ollama exposes `/v1/chat/completions` (OpenAI-compatible). Uses tools.openai + OpenAiApiStrategy — same path as OpenRouter/Mistral.
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
            "model": `${currentModel}`,
            "requires_key": true,
            "key_id": "mistral",
            "key_get_link": "https://console.mistral.ai/api-keys",
            "key_get_description": Translation.tr("**Instructions**: Log into Mistral account, go to Keys on the sidebar, click Create new key"),
            "api_format": "openai",
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
    // Set before each screenshotProc run; consumed in makeRequest when attaching tool_choice after vision.
    // "explicit" = user/tool take_screenshot — force next tool. "execute_js" / "followup" = automation — do not force (avoids execute_js loops).
    property string _pendingVisionFollowUpKind: ""
    // One send_message per user turn — handler fires makeRequest immediately; model otherwise loops send_message dozens of times.
    property bool _sendMessageIssuedThisTurn: false

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
            if (feedback) root.addMessage(Translation.tr("Invalid model. Supported: \n```\n") + modelList.join("\n```\n```\n") + "\n```", Ai.interfaceRole)
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
        if (isNaN(value) || value < 0 || value > 2) {
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
            // Sub-agent completion handling
            if (root.activeAgentType && root.agentCallStack.length > 0) {
                if (root._pendingAgentResult.length > 0) {
                    // Agent called return_result explicitly
                    const res = root._pendingAgentResult;
                    root._pendingAgentResult = "";
                    root._finalizeCurrentAgent(res);
                } else if (!requester.message.functionCall) {
                    // Agent produced a plain text response (no tool call) — use it as result
                    const res = requester.message.content || requester.message.rawContent || "[Agent produced no output]";
                    root._finalizeCurrentAgent(res);
                }
                // For intermediate tool-call steps: just return, makeRequest already scheduled
                return;
            }
            if (root.postResponseHook) {
                root.postResponseHook();
                root.postResponseHook = null;
            }
            if (!root._pendingDesktopAction) root.requestRestoreSidebars();
            root.saveChat("lastSession")
            root.responseFinished()
        }

        function makeRequest() {
            // Check if active agent wants cloud model escalation
            let model = models[currentModelId];
            if (root.activeAgentType) {
                const agentDef = root.agentDefs[root.activeAgentType];
                if (agentDef?.useCloudModel && root.agentCloudModel) {
                    // Create a temporary model object pointing to the cloud Ollama model
                    model = {
                        name: `Ollama - ${root.agentCloudModel}`,
                        model: root.agentCloudModel,
                        endpoint: "http://localhost:11434/v1/chat/completions",
                        requires_key: false,
                        api_format: "openai",
                        extraParams: { "num_ctx": 32768 },
                    };
                }
            }

            // Guard against infinite tool-call loops
            root.consecutiveToolCalls++;
            if (root.consecutiveToolCalls > root.maxConsecutiveToolCalls) {
                root.consecutiveToolCalls = 0;
                root.addMessage(`[Stopped: ${root.maxConsecutiveToolCalls} consecutive tool calls without user input. Please check what went wrong.]`, root.interfaceRole);
                return;
            }

            // Fetch API keys if needed
            if (model?.requires_key && !KeyringStorage.loaded) KeyringStorage.fetchKeyringData();
            
            // Use strategy matching the model's api_format (may differ from currentApiStrategy if agent overrides model)
            requester.currentStrategy = root.apiStrategies[model.api_format || "openai"];
            requester.currentStrategy.reset(); // Reset strategy state

            /* Put API key in environment variable */
            if (model.requires_key) requester.environment[`${root.apiKeyEnvVarName}`] = root.apiKeys ? (root.apiKeys[model.key_id] ?? "") : ""

            /* Build endpoint, request data */
            const endpoint = root.currentApiStrategy.buildEndpoint(model);
            const messageArray = root.activeAgentType
                ? (root.agentMsgIDs[root.activeAgentType] || []).map(id => root.agentMsgByID[id]).filter(Boolean)
                : root.messageIDs.map(id => root.messageByID[id]);
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
                    const toDropTools = toolMsgs.slice(0, toolMsgs.length - TOOL_RESULT_KEEP);
                    const dropToolSet = new Set(toDropTools);
                    const indicesToRemove = new Set();
                    for (let i = 0; i < contextArr.length; i++) {
                        if (dropToolSet.has(contextArr[i])) {
                            indicesToRemove.add(i);
                            if (i > 0) {
                                const prev = contextArr[i - 1];
                                if (prev.role === "assistant" && prev.functionCall && prev.functionCall.name) {
                                    indicesToRemove.add(i - 1);
                                }
                            }
                        }
                    }
                    contextArr = contextArr.filter((_, i) => !indicesToRemove.has(i));
                    console.log(`[AI] Context compacted: dropped ${indicesToRemove.size} messages (tool results + paired assistant tool calls, ${contextArr.length} remaining)`);
                }
            }
            const agentSysPrompt = root.activeAgentType
                ? (root.agentDefs[root.activeAgentType]?.systemPrompt || root.systemPrompt)
                : root.systemPrompt;
            const data = root.currentApiStrategy.buildRequestData(model, contextArr, agentSysPrompt, root.temperature, root.getActiveTools(model.api_format), root.pendingFilePath);
            // After vision pipeline tool results, optionally force the next step to use a tool.
            // Do NOT force after automated follow-up screenshots (execute_js / click / search_app): tool_choice "required"
            // makes the model call execute_js again in a tight loop even when the first run succeeded.
            const fmt = model.api_format || "openai";
            if (data && data.tools && data.tools.length > 0 && fmt === "openai") {
                const last = contextArr.length > 0 ? contextArr[contextArr.length - 1] : null;
                const visionToolNames = ["take_screenshot", "capture_region", "read_clipboard_image"];
                if (last && last.functionName && visionToolNames.includes(last.functionName)) {
                    const vKind = root._pendingVisionFollowUpKind;
                    root._pendingVisionFollowUpKind = "";
                    if (vKind !== "execute_js" && vKind !== "followup") {
                        data.tool_choice = "required";
                    }
                }
            }
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
            if (root.activeAgentType) {
                const ids = root.agentMsgIDs[root.activeAgentType] || [];
                root.agentMsgIDs[root.activeAgentType] = [...ids, id];
                root.agentMsgByID[id] = requester.message;
            } else {
                root.messageIDs = [...root.messageIDs, id];
                root.messageByID[id] = requester.message;
            }

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
                        requester.message.toolCallId = result.functionCall.id || "";
                        root._pendingToolCallId = result.functionCall.id || "";
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
                    // Do NOT leak raw SSE data into message content
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
    property string _pendingToolCallId: ""
    readonly property int maxConsecutiveToolCalls: 25
    property var _toolCallCounts: ({})  // per-tool call count within a turn

    function sendUserMessage(message) {
        if (message.length === 0) return;
        root.consecutiveToolCalls = 0;
        root._turnHadPlan = false;
        root._pendingDesktopAction = false;
        root._pendingVisionFollowUpKind = "";
        root._toolCallCounts = ({});
        root._sendMessageIssuedThisTurn = false;
        root._lastUserMessageText = message; // Store for intent detection
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
        const callId = root._pendingToolCallId || `call_${name}`;
        root._pendingToolCallId = "";
        return aiMessageComponent.createObject(root, {
            "role": "user",
            "content": `[[ Output of ${name} ]]${includeOutputInChat ? ("\n\n<think>\n" + output + "\n</think>") : ""}`,
            "rawContent": `[[ Output of ${name} ]]${includeOutputInChat ? ("\n\n<think>\n" + output + "\n</think>") : ""}`,
            "functionName": name,
            "functionResponse": output,
            "toolCallId": callId,
            "thinking": false,
            "done": true,
            // "visibleToUser": false,
        });
    }

    function triggerAutoScreenshot(delayMs) {
        const delay = delayMs || 500;
        Qt.callLater(() => {
            root._pendingVisionFollowUpKind = "followup";
            const screenshotPath = `${Directories.aiSttTemp}/screenshot.png`;
            const dest = CF.FileUtils.trimFileProtocol(screenshotPath);
            screenshotProc.targetPath = dest;
            const cmd = `
sleep ${delay / 1000}
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys,subprocess
mons=json.loads(os.environ.get("MONITORS","[]"))
try:
    aw=json.loads(subprocess.run(["hyprctl","activewindow","-j"],capture_output=True,text=True).stdout or "{}")
    mid=aw.get("monitor",-1)
    if mid>=0:
        for m in mons:
            if m.get("id")==mid: print(m.get("name","")); sys.exit()
except: pass
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
MON_NAME=$(echo "$MON_NAME" | head -n1 | tr -d '\\r')
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 2>&1 << 'PYEOF'
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
cx_in_bounds = 0 <= cx_img < W and 0 <= cy_img < H
composite = Image.alpha_composite(img, overlay).convert('RGB')
MAX_W = 1920
sf = 1.0
if W > MAX_W:
    sf = W / MAX_W
    new_h = round(H * MAX_W / W)
    composite = composite.resize((MAX_W, new_h), Image.LANCZOS)
    W_out, H_out = MAX_W, new_h
else:
    W_out, H_out = W, H
composite.save(dest)
cx_s = round(cx_img / sf) if cx_in_bounds else -1
cy_s = round(cy_img / sf) if cx_in_bounds else -1
print(f"GRID_META:{W_out}:{H_out}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
print(f"IMG_SCALE:{sf:.6f}")
print(f"CURSOR_S:{cx_s}:{cy_s}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
SCALE=$(echo "\${META}" | grep "^IMG_SCALE:" | cut -d: -f2)
SCALE=\${SCALE:-1.0}
CURSOR_LINE=$(echo "\${META}" | grep "^CURSOR_S:")
CURSOR_SS_X=$(echo "\${CURSOR_LINE}" | cut -d: -f2)
CURSOR_SS_Y=$(echo "\${CURSOR_LINE}" | cut -d: -f3)
CURSOR_SS_X=\${CURSOR_SS_X:--1}
CURSOR_SS_Y=\${CURSOR_SS_Y:--1}
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:\${SCALE}"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
            screenshotProc.command = ["bash", "-c", cmd];
            screenshotProc.running = true;
        });
    }

    function addFunctionOutputMessage(name, output) {
        const aiMessage = createFunctionOutputMessage(name, output);
        const id = idForMessage(aiMessage);
        if (root.activeAgentType) {
            const ids = root.agentMsgIDs[root.activeAgentType] || [];
            root.agentMsgIDs[root.activeAgentType] = [...ids, id];
            root.agentMsgByID[id] = aiMessage;
        } else {
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = aiMessage;
        }
    }

    function rejectCommand(message: AiMessageData) {
        if (!message.functionPending) return;
        message.functionPending = false; // User decided, no more "thinking"
        root._pendingToolCallId = message.toolCallId || "";
        addFunctionOutputMessage(message.functionName, Translation.tr("Command rejected by user"))
    }

    function approveCommand(message: AiMessageData) {
        if (!message.functionPending) return;
        message.functionPending = false; // User decided, no more "thinking"

        root._pendingToolCallId = message.toolCallId || "";
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
        property string currentToolName: ""
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
            const toolName = commandExecutionProc.currentToolName;
            commandExecutionProc.currentToolName = "";
            if (toolName === "send_message" || toolName === "run_task") {
                commandExecutionProc.message.functionResponse += `[[ Task delegated and complete. Report the above result to the user. Do not call any more tools. ]]\n`;
            } else if (toolName === "open_app" || toolName === "launch_app") {
                commandExecutionProc.message.functionResponse += `[[ App launch finished. Answer only about the user's request (e.g. media/app control). Do not pivot to messaging, WhatsApp, or send_message unless the user asked for that. Do not call more tools unless still needed. ]]\n`;
            } else if (toolName === "web_search") {
                commandExecutionProc.message.functionResponse += `[[ Search complete. Use the results above to answer the user's question. Do NOT search again — analyze these results and respond. If the user asked to buy/add to cart, open the product URL from the results. IMPORTANT: Only cite information and URLs that appear in the search results above. Do NOT make up product names, prices, URLs, or details that are not in these results. If the results don't have enough detail, say so honestly. ]]\n`;
            }
            root._pendingDesktopAction = false;
            requester.makeRequest();
        }
    }



    function handleFunctionCall(name, args: var, message: AiMessageData) {
        message.functionName = name; // Needed so approveCommand can label function output correctly
        // Per-tool repeat limit: block tools that are called too many times in one turn
        const toolLimits = { "web_search": 3, "read_url": 4, "execute_js": 5 };
        if (name in toolLimits) {
            root._toolCallCounts[name] = (root._toolCallCounts[name] || 0) + 1;
            if (root._toolCallCounts[name] > toolLimits[name]) {
                addFunctionOutputMessage(name, `[Blocked] You already called ${name} ${toolLimits[name]} times this turn. STOP calling ${name}. Use the results you already have and respond to the user in text.`);
                requester.makeRequest();
                return;
            }
        }
        // show_plan gate: disabled — small local models loop on show_plan instead of executing
        // The system prompt still encourages planning, but it's not enforced
        // const actionTools = ["click_at","click_cell","type_text","press_key","launch_app","scroll","drag_to","hover","manage_tabs"];
        // if (!root._turnHadPlan && root.consecutiveToolCalls >= 2 && actionTools.includes(name) && !root.activeAgentType) {
        //     addFunctionOutputMessage(name, `[Gate] You attempted '${name}' without calling show_plan first.`);
        //     requester.makeRequest();
        //     return;
        // }
        if (name === "call_agent") {
            const agentType = (args.agent || "").toLowerCase().trim();
            const task = args.task || "";
            if (!root.agentDefs[agentType]) {
                addFunctionOutputMessage(name, `Unknown agent: '${agentType}'. Available: desktop (Vector), research (Scout), system (Forge), personal (Sage).`);
                requester.makeRequest();
                return;
            }
            const def = root.agentDefs[agentType];
            // Push coordinator state onto stack
            root.agentCallStack = [...root.agentCallStack, {
                parentAgentType: root.activeAgentType,
                toolCallId: root._pendingToolCallId,
                savedCalls: root.consecutiveToolCalls
            }];
            root._pendingToolCallId = "";
            root.consecutiveToolCalls = 0;
            // Init agent context: one user message = the task
            const taskMsg = aiMessageComponent.createObject(root, {
                "role": "user", "content": task, "rawContent": task,
                "thinking": false, "done": true
            });
            const taskId = idForMessage(taskMsg);
            root.agentMsgIDs[agentType] = [taskId];
            root.agentMsgByID[taskId] = taskMsg;
            root.activeAgentType = agentType;
            // Show brief indicator in main chat
            root.addMessage(`◆ ${def.displayName} (${def.emoji}) — ${task.substring(0, 100)}${task.length > 100 ? "…" : ""}`, root.interfaceRole);
            requester.makeRequest();
            return;
        } else if (name === "return_result") {
            root._pendingAgentResult = args.result || "Task completed.";
            // Don't call makeRequest — markDone will pick up _pendingAgentResult and finalize
            return;
        } else if (name === "switch_to_search_mode") {
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
            let changes = [];
            if (args.changes && Array.isArray(args.changes)) {
                changes = args.changes;
            } else if (args.key != null && args.value != null) {
                // Legacy OpenAI/Mistral schema (single key/value) — still accepted from old chats or manual calls
                changes = [{ key: args.key, value: String(args.value) }];
            } else {
                addFunctionOutputMessage(name, Translation.tr("Invalid arguments. Must provide `changes` array (or legacy `key` and `value`)."));
                requester.makeRequest();
                return;
            }
            let results = [];
            for (const change of changes) {
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
        } else if (name === "get_news") {
            const topic = args.topic || "top news";
            const responseMessage = createFunctionOutputMessage(name, "", false);
            const id = idForMessage(responseMessage);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = responseMessage;
            commandExecutionProc.message = responseMessage;
            commandExecutionProc.baseMessageContent = responseMessage.content;
            const escapedTopic = topic.replace(/'/g, "'\\''");
            commandExecutionProc.shellCommand = `ii-news '${escapedTopic}'`;
            commandExecutionProc.running = true;
        } else if (name === "play_music") {
            const action = (args.action || "play").toLowerCase();
            const query = args.query || "";
            const service = (args.service || "spotify").toLowerCase();
            const responseMessage = createFunctionOutputMessage(name, "", false);
            const id = idForMessage(responseMessage);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = responseMessage;
            commandExecutionProc.message = responseMessage;
            commandExecutionProc.baseMessageContent = responseMessage.content;
            if (action === "shuffle") {
                commandExecutionProc.shellCommand = `playerctl --player=${service} shuffle toggle && echo "Shuffle toggled." && playerctl --player=${service} shuffle`;
            } else if (action === "like" || action === "unlike" || action === "save" || action === "unsave") {
                // Sidebar closes before this runs (requestHideSidebars above), so wtype can reach Spotify
                const verb = (action === "unlike" || action === "unsave") ? "Unliked" : "Liked";
                commandExecutionProc.shellCommand = `SONG=$(playerctl --player=spotify metadata --format "{{artist}} - {{title}}" 2>/dev/null); hyprctl dispatch focuswindow "class:spotify" && sleep 0.5 && wtype -M alt -M shift b -m shift -m alt && echo "${verb}: $SONG"`;
            } else {
                if (!query) { addFunctionOutputMessage(name, "Invalid: query is required for play"); requester.makeRequest(); return; }
                const encodedQuery = query.replace(/ /g, "+").replace(/'/g, "'\\''");
                const escapedQuery = query.replace(/'/g, "'\\''");
                commandExecutionProc.shellCommand = `oi-task 'Play music on ${service}. Run: playerctl --player=${service} open "${service}:search:${encodedQuery}" — if ${service} is not running, launch it first with: hyprctl dispatch exec ${service} && sleep 3. The search query is: ${escapedQuery}'`;
            }
            root._pendingDesktopAction = true;
            root.requestHideSidebars();
            commandExecutionProc.running = true;
        } else if (name === "open_app") {
            const appName = args.name || "";
            if (!appName) { addFunctionOutputMessage(name, "Invalid: name is required"); requester.makeRequest(); return; }
            const responseMessage = createFunctionOutputMessage(name, "", false);
            const id = idForMessage(responseMessage);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = responseMessage;
            commandExecutionProc.message = responseMessage;
            commandExecutionProc.baseMessageContent = responseMessage.content;
            const escapedName = appName.replace(/'/g, "'\\''");
            commandExecutionProc.shellCommand = `oi-task 'Launch the application: ${escapedName}'`;
            commandExecutionProc.currentToolName = name;
            root._pendingDesktopAction = true;
            root.requestHideSidebars();
            commandExecutionProc.running = true;
        } else if (name === "run_task") {
            const task = args.task || "";
            if (!task) {
                addFunctionOutputMessage(name, "Invalid: task is required");
                requester.makeRequest();
                return;
            }
            const responseMessage = createFunctionOutputMessage(name, "", false);
            const id = idForMessage(responseMessage);
            root.messageIDs = [...root.messageIDs, id];
            root.messageByID[id] = responseMessage;
            commandExecutionProc.message = responseMessage;
            commandExecutionProc.baseMessageContent = responseMessage.content;
            // Escape single quotes in task for shell argument
            const escapedTask = task.replace(/'/g, "'\\''");
            commandExecutionProc.shellCommand = `oi-task '${escapedTask}'`;
            commandExecutionProc.currentToolName = "run_task";
            root._pendingDesktopAction = true;
            root.requestHideSidebars();
            commandExecutionProc.running = true;
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
            commandExecutionProc.currentToolName = "web_search";
            const escapedQuery = args.query.replace(/'/g, "'\\''");
            commandExecutionProc.shellCommand = `bash ~/.config/quickshell/scripts/ai-search.sh '${escapedQuery}'`;
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
import json,os,sys,subprocess
mons=json.loads(os.environ.get("MONITORS","[]"))
try:
    aw=json.loads(subprocess.run(["hyprctl","activewindow","-j"],capture_output=True,text=True).stdout or "{}")
    mid=aw.get("monitor",-1)
    if mid>=0:
        for m in mons:
            if m.get("id")==mid: print(m.get("name","")); sys.exit()
except: pass
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
MON_NAME=$(echo "$MON_NAME" | head -n1 | tr -d '\r')
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 2>&1 << 'PYEOF'
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
cx_in_bounds = 0 <= cx_img < W and 0 <= cy_img < H
composite = Image.alpha_composite(img, overlay).convert('RGB')
MAX_W = 1920
sf = 1.0
if W > MAX_W:
    sf = W / MAX_W
    new_h = round(H * MAX_W / W)
    composite = composite.resize((MAX_W, new_h), Image.LANCZOS)
    W_out, H_out = MAX_W, new_h
else:
    W_out, H_out = W, H
composite.save(dest)
cx_s = round(cx_img / sf) if cx_in_bounds else -1
cy_s = round(cy_img / sf) if cx_in_bounds else -1
print(f"GRID_META:{W_out}:{H_out}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
print(f"IMG_SCALE:{sf:.6f}")
print(f"CURSOR_S:{cx_s}:{cy_s}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
SCALE=$(echo "\${META}" | grep "^IMG_SCALE:" | cut -d: -f2)
SCALE=\${SCALE:-1.0}
CURSOR_LINE=$(echo "\${META}" | grep "^CURSOR_S:")
CURSOR_SS_X=$(echo "\${CURSOR_LINE}" | cut -d: -f2)
CURSOR_SS_Y=$(echo "\${CURSOR_LINE}" | cut -d: -f3)
CURSOR_SS_X=\${CURSOR_SS_X:--1}
CURSOR_SS_Y=\${CURSOR_SS_Y:--1}
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:\${SCALE}"
echo "SCREENSHOT_OFFSET:\${SS_OFFSET_X}:\${SS_OFFSET_Y}"
`;
            root.requestHideSidebars();
            const _cmd = cmd;
            sidebarHideTimer.pendingAction = () => {
                root._pendingVisionFollowUpKind = "explicit";
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
            const escapedApp = app.replace(/'/g, "'\\''");
            commandExecutionProc.shellCommand = `oi-task 'Launch the application: ${escapedApp}'`;
            commandExecutionProc.currentToolName = name;
            commandExecutionProc.running = true;
        } else if (name === "open_file") {
            const path = args.path || args.url || args.uri || "";
            if (!path) { addFunctionOutputMessage(name, "Invalid: path is required"); requester.makeRequest(); return; }
            Quickshell.execDetached(["xdg-open", path]);
            const isUrl = /^https?:\/\//i.test(path);
            const hint = isUrl ? `\nNote: The page was only opened in the browser. To interact with it (click buttons, add to cart, fill forms), use execute_js or call_agent(desktop).` : "";
            addFunctionOutputMessage(name, `Opened: ${path}${hint}`);
            requester.makeRequest();
        } else if (name === "get_notifications") {
            const notifs = Notifications.list;
            if (!notifs || notifs.length === 0) {
                addFunctionOutputMessage(name, "No notifications.");
            } else {
                const lines = notifs.slice().reverse().map(n => {
                    const age = Math.round((Date.now() - n.time) / 60000);
                    const ageStr = age < 1 ? "just now" : `${age}m ago`;
                    const replyTag = n.hasReply ? " [can_reply]" : "";
                    return `[id:${n.notificationId}] ${n.appName} | ${n.summary}${n.body ? ": " + n.body : ""} (${ageStr})${replyTag}`;
                });
                addFunctionOutputMessage(name, lines.join("\n"));
            }
            requester.makeRequest();
        } else if (name === "reply_notification") {
            const notifId = parseInt(args.notification_id);
            const replyText = args.message || "";
            if (!notifId || !replyText) {
                addFunctionOutputMessage(name, "Error: notification_id and message are required.");
            } else {
                Notifications.sendReply(notifId, replyText);
                addFunctionOutputMessage(name, `Reply sent to notification ${notifId}.`);
            }
            requester.makeRequest();
        } else if (name === "send_message") {
            if (root._sendMessageIssuedThisTurn && !root.activeAgentType) {
                addFunctionOutputMessage(name,
                    "[Gate] send_message was already started this turn. Do NOT call send_message again. Tell the user the browser automation is running or finished and offer to help with something else.");
                requester.makeRequest();
                return;
            }
            const to = args.to || "";
            const msg = args.message || "";
            const platform = (args.platform || "").toLowerCase();
            if (!to || !msg || !platform) {
                addFunctionOutputMessage(name, `Error: missing required args. Got: to="${to}", message="${msg}", platform="${platform}". Retry with all three filled in.`);
                requester.makeRequest();
                return;
            }
            const platformUrls = {
                "facebook messenger": "https://www.messenger.com",
                "messenger": "https://www.messenger.com",
                "telegram": "https://web.telegram.org",
                "discord": "https://discord.com/app",
                "whatsapp": "https://web.whatsapp.com",
                "instagram": "https://www.instagram.com/direct/inbox/",
            };
            const platformEntry = Object.entries(platformUrls).find(([k]) => platform.includes(k));
            const platformUrl = platformEntry ? platformEntry[1] : null;
            if (platformUrl) { try {
                const automationJS =
                    `(function(){` +
                    `function S(ms){return new Promise(r=>setTimeout(r,ms));}` +
                    `function setVal(el,v){const p=Object.getPrototypeOf(el);const d=Object.getOwnPropertyDescriptor(p,"value");` +
                    `if(d&&d.set){d.set.call(el,v);}else{el.value=v;}` +
                    `el.dispatchEvent(new Event("input",{bubbles:true}));el.dispatchEvent(new Event("change",{bubbles:true}));}` +
                    `async function go(){` +
                    `document.title="[AI]start";` +
                    `const search=document.querySelector("input[aria-label*='Search' i],input[placeholder*='Search' i],input[type='search']");` +
                    `if(!search){document.title="[AI]no-search";return;}` +
                    `search.click();search.focus();setVal(search,${JSON.stringify(to)});` +
                    `document.title="[AI]searching";await S(3000);` +
                    `const allResults=[...document.querySelectorAll("[role='option'],[role='listitem'],[data-testid*='row']")];` +
                    `const resultEl=allResults.find(el=>el.querySelector("img"));` +
                    `if(!resultEl){document.title="[AI]no-result:"+allResults.length;return;}` +
                    `const link=resultEl.querySelector("a")||resultEl.closest("a");` +
                    `if(link){link.click();}else{resultEl.click();}` +
                    `await S(4000);` +
                    `const boxes=[...document.querySelectorAll("div[contenteditable='true']")];` +
                    `const msgBox=boxes.filter(e=>!(e.getAttribute("aria-label")||"").toLowerCase().includes("search")).pop();` +
                    `if(!msgBox){document.title="[AI]no-msgbox:"+boxes.length;return;}` +
                    `msgBox.focus();msgBox.click();await S(500);` +
                    `document.execCommand("selectAll",false,null);` +
                    `document.execCommand("insertText",false,${JSON.stringify(msg)});` +
                    `await S(600);` +
                    `const sendBtn=document.querySelector("[aria-label='Send']");` +
                    `if(sendBtn){sendBtn.click();document.title="[AI]sent-btn";}` +
                    `else{msgBox.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",code:"Enter",bubbles:true,cancelable:true}));document.title="[AI]sent-key";}` +
                    `}go();})()`;
                const shellSafeJS = automationJS.replace(/'/g, "'\\''");
                const urlLit = JSON.stringify(platformUrl);
                const clipboardOnly = Config.options.ai.sendMessageClipboardOnly === true;
                const script = clipboardOnly
                    ? `printf '%s' '${shellSafeJS}' | wl-copy\n` +
                      `(firefox ${urlLit} >/dev/null 2>&1 &)\n` +
                      `notify-send -a "Quickshell AI" "send_message" "Script copied. In Firefox: F12 → Console → Ctrl+V → Enter. Tab title shows [AI]… status."`
                    : `printf '%s' '${shellSafeJS}' | wl-copy\n` +
                      `(firefox ${urlLit} >/dev/null 2>&1 &)\n` +
                      `sleep 2\n` +
                      `qs -p ~/.config/quickshell/ii ipc call sidebarLeft close 2>/dev/null\n` +
                      `sleep 0.5\n` +
                      `for _try in 1 2 3; do\n` +
                      `  hyprctl dispatch focuswindow "class:firefox" 2>/dev/null && break\n` +
                      `  sleep 0.25\n` +
                      `done\n` +
                      `sleep 8\n` +
                      `hyprctl dispatch focuswindow "class:firefox" 2>/dev/null\n` +
                      `sleep 0.35\n` +
                      `wtype -k F12\n` +
                      `sleep 1.8\n` +
                      `wtype -M ctrl -k v -m ctrl\n` +
                      `sleep 0.3\n` +
                      `wtype -k Return\n` +
                      `sleep 6\n` +
                      `wtype -k F12` ;
                Quickshell.execDetached(["bash", "-c", script]);
                root._sendMessageIssuedThisTurn = true;
                addFunctionOutputMessage(name,
                    clipboardOnly
                        ? `Script on clipboard; ${platform} opened. User pastes in Firefox console (F12). Do NOT call send_message again.`
                        : `Browser automation started for ${to} on ${platform}. Do NOT call send_message again for this request. Reply briefly that the user should check the tab when automation finishes.`);
                requester.makeRequest();
            } catch(e) { addFunctionOutputMessage(name, "Error in send_message: " + e); requester.makeRequest(); }
            } else {
                addFunctionOutputMessage(name, `Unknown platform: '${platform}'. Supported: facebook messenger, telegram, discord, whatsapp, instagram.`);
                requester.makeRequest();
            }
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
            const isDouble = args.double === true;
            const mods = (args.modifiers || "").toLowerCase().trim();
            // Scale coords from screenshot space back to real display space
            const nativeW = Math.round(imgW * scale);
            const nativeH = Math.round(imgH * scale);
            const sx = Math.max(0, Math.min(Math.round(rawX * scale), nativeW)) + root.lastScreenshotOffsetX;
            const sy = Math.max(0, Math.min(Math.round(rawY * scale), nativeH)) + root.lastScreenshotOffsetY;
            const ydoBtn = button === "right" ? "3" : button === "middle" ? "2" : "1";
            const modLabel = mods ? ` [${mods}]` : "";
            const dblLabel = isDouble ? " double" : "";
            root._lastClickInfo = `click_at${dblLabel}${modLabel} (${rawX}, ${rawY})`;
            addFunctionOutputMessage(name, `${isDouble ? "Double-clicking" : "Clicking"}${modLabel} (${rawX}, ${rawY}) → screen (${sx}, ${sy})`);
            // Build modifier key press/release commands
            const modMap = { "ctrl": "29", "shift": "42", "alt": "56", "super": "125" };
            const modParts = mods ? mods.split("+").filter(m => modMap[m]) : [];
            const modDown = modParts.map(m => `ydotool key ${modMap[m]}:1`).join(" && ");
            const modUp = modParts.reverse().map(m => `ydotool key ${modMap[m]}:0`).join(" && ");
            const clickPart = isDouble
                ? `ydotool click --button-up --button-down ${ydoBtn} && sleep 0.05 && ydotool click --button-up --button-down ${ydoBtn}`
                : `ydotool click --button-up --button-down ${ydoBtn}`;
            // Move mouse and click, with optional modifiers and double-click
            let clickCmd = `sleep 0.15 && ydotool mousemove --absolute -x ${sx} -y ${sy}`;
            if (modDown) clickCmd += ` && ${modDown}`;
            clickCmd += ` && ${clickPart}`;
            if (modUp) clickCmd += ` && ${modUp}`;
            root.requestHideSidebars();
            Quickshell.execDetached(["bash", "-c", clickCmd]);
            // After click, auto-take a fresh screenshot so the model can see the result
            Qt.callLater(() => {
                root._pendingVisionFollowUpKind = "followup";
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
import json,os,sys,subprocess
mons=json.loads(os.environ.get("MONITORS","[]"))
try:
    aw=json.loads(subprocess.run(["hyprctl","activewindow","-j"],capture_output=True,text=True).stdout or "{}")
    mid=aw.get("monitor",-1)
    if mid>=0:
        for m in mons:
            if m.get("id")==mid: print(m.get("name","")); sys.exit()
except: pass
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
MON_NAME=$(echo "$MON_NAME" | head -n1 | tr -d '\r')
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 2>&1 << 'PYEOF'
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
cx_in_bounds = 0 <= cx_img < W and 0 <= cy_img < H
composite = Image.alpha_composite(img, overlay).convert('RGB')
MAX_W = 1920
sf = 1.0
if W > MAX_W:
    sf = W / MAX_W
    new_h = round(H * MAX_W / W)
    composite = composite.resize((MAX_W, new_h), Image.LANCZOS)
    W_out, H_out = MAX_W, new_h
else:
    W_out, H_out = W, H
composite.save(dest)
cx_s = round(cx_img / sf) if cx_in_bounds else -1
cy_s = round(cy_img / sf) if cx_in_bounds else -1
print(f"GRID_META:{W_out}:{H_out}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
print(f"IMG_SCALE:{sf:.6f}")
print(f"CURSOR_S:{cx_s}:{cy_s}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
SCALE=$(echo "\${META}" | grep "^IMG_SCALE:" | cut -d: -f2)
SCALE=\${SCALE:-1.0}
CURSOR_LINE=$(echo "\${META}" | grep "^CURSOR_S:")
CURSOR_SS_X=$(echo "\${CURSOR_LINE}" | cut -d: -f2)
CURSOR_SS_Y=$(echo "\${CURSOR_LINE}" | cut -d: -f3)
CURSOR_SS_X=\${CURSOR_SS_X:--1}
CURSOR_SS_Y=\${CURSOR_SS_Y:--1}
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:\${SCALE}"
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
            const isDouble = args.double === true;
            const mods = (args.modifiers || "").toLowerCase().trim();
            const ydoBtn  = button === "right" ? "3" : button === "middle" ? "2" : "1";
            const scale   = root.lastScreenshotScale  > 0 ? root.lastScreenshotScale  : 1.0;
            const sx = Math.round(rawX * scale) + root.lastScreenshotOffsetX;
            const sy = Math.round(rawY * scale) + root.lastScreenshotOffsetY;
            const modLabel = mods ? ` [${mods}]` : "";
            const dblLabel = isDouble ? " double" : "";
            root._lastClickInfo = `click_cell${dblLabel}${modLabel} ${cellNum}`;
            addFunctionOutputMessage(name, `${isDouble ? "Double-clicking" : "Clicking"}${modLabel} cell ${cellNum} (row ${row+1}, col ${col+1}) → screen (${sx}, ${sy})`);
            // Build modifier key press/release commands
            const modMap = { "ctrl": "29", "shift": "42", "alt": "56", "super": "125" };
            const modParts = mods ? mods.split("+").filter(m => modMap[m]) : [];
            const modDown = modParts.map(m => `ydotool key ${modMap[m]}:1`).join(" && ");
            const modUp = modParts.reverse().map(m => `ydotool key ${modMap[m]}:0`).join(" && ");
            const clickPart = isDouble
                ? `ydotool click --button-up --button-down ${ydoBtn} && sleep 0.05 && ydotool click --button-up --button-down ${ydoBtn}`
                : `ydotool click --button-up --button-down ${ydoBtn}`;
            let clickCmd = `sleep 0.15 && ydotool mousemove --absolute -x ${sx} -y ${sy}`;
            if (modDown) clickCmd += ` && ${modDown}`;
            clickCmd += ` && ${clickPart}`;
            if (modUp) clickCmd += ` && ${modUp}`;
            root.requestHideSidebars();
            Quickshell.execDetached(["bash", "-c", clickCmd]);
            Qt.callLater(() => {
                root._pendingVisionFollowUpKind = "followup";
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
import json,os,sys,subprocess
mons=json.loads(os.environ.get("MONITORS","[]"))
try:
    aw=json.loads(subprocess.run(["hyprctl","activewindow","-j"],capture_output=True,text=True).stdout or "{}")
    mid=aw.get("monitor",-1)
    if mid>=0:
        for m in mons:
            if m.get("id")==mid: print(m.get("name","")); sys.exit()
except: pass
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
MON_NAME=$(echo "$MON_NAME" | head -n1 | tr -d '\r')
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 2>&1 << 'PYEOF'
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
cx_in_bounds = 0 <= cx_img < W and 0 <= cy_img < H
composite = Image.alpha_composite(img, overlay).convert('RGB')
MAX_W = 1920
sf = 1.0
if W > MAX_W:
    sf = W / MAX_W
    new_h = round(H * MAX_W / W)
    composite = composite.resize((MAX_W, new_h), Image.LANCZOS)
    W_out, H_out = MAX_W, new_h
else:
    W_out, H_out = W, H
composite.save(dest)
cx_s = round(cx_img / sf) if cx_in_bounds else -1
cy_s = round(cy_img / sf) if cx_in_bounds else -1
print(f"GRID_META:{W_out}:{H_out}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
print(f"IMG_SCALE:{sf:.6f}")
print(f"CURSOR_S:{cx_s}:{cy_s}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
SCALE=$(echo "\${META}" | grep "^IMG_SCALE:" | cut -d: -f2)
SCALE=\${SCALE:-1.0}
CURSOR_LINE=$(echo "\${META}" | grep "^CURSOR_S:")
CURSOR_SS_X=$(echo "\${CURSOR_LINE}" | cut -d: -f2)
CURSOR_SS_Y=$(echo "\${CURSOR_LINE}" | cut -d: -f3)
CURSOR_SS_X=\${CURSOR_SS_X:--1}
CURSOR_SS_Y=\${CURSOR_SS_Y:--1}
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:\${SCALE}"
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
        } else if (name === "kg_store") {
            const action = (args.action || "").trim();
            const kgScript = `"${Directories.aiMemoryPath.replace('memory.md', 'kg.py')}"`;
            const kgMsg = createFunctionOutputMessage(name, "", false);
            const kgId = idForMessage(kgMsg);
            root.messageIDs = [...root.messageIDs, kgId];
            root.messageByID[kgId] = kgMsg;
            commandExecutionProc.message = kgMsg;
            commandExecutionProc.baseMessageContent = kgMsg.content;
            let kgCmd = "";
            if (action === "entity") {
                const eName = args.name || "";
                const eType = args.entity_type || "thing";
                const obs = JSON.stringify(args.observations || []);
                if (!eName) { addFunctionOutputMessage(name, "Error: name is required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} store ${JSON.stringify(eName)} ${JSON.stringify(eType)} ${JSON.stringify(obs)} 2>&1`;
            } else if (action === "relation") {
                const from = args.from_entity || "";
                const rel = args.relation || "";
                const to = args.to_entity || "";
                if (!from || !rel || !to) { addFunctionOutputMessage(name, "Error: from_entity, relation, and to_entity are required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} relate ${JSON.stringify(from)} ${JSON.stringify(rel)} ${JSON.stringify(to)} 2>&1`;
            } else if (action === "observe") {
                const eName = args.name || "";
                const obs = JSON.stringify(args.observations || []);
                if (!eName) { addFunctionOutputMessage(name, "Error: name is required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} observe ${JSON.stringify(eName)} ${JSON.stringify(obs)} 2>&1`;
            } else {
                addFunctionOutputMessage(name, "Error: action must be 'entity', 'relation', or 'observe'");
                requester.makeRequest();
                return;
            }
            commandExecutionProc.shellCommand = kgCmd;
            commandExecutionProc.running = true;
        } else if (name === "kg_query") {
            const action = (args.action || "").trim();
            const kgScript = `"${Directories.aiMemoryPath.replace('memory.md', 'kg.py')}"`;
            const kgMsg = createFunctionOutputMessage(name, "", false);
            const kgId = idForMessage(kgMsg);
            root.messageIDs = [...root.messageIDs, kgId];
            root.messageByID[kgId] = kgMsg;
            commandExecutionProc.message = kgMsg;
            commandExecutionProc.baseMessageContent = kgMsg.content;
            let kgCmd = "";
            if (action === "search") {
                const query = args.query || "";
                if (!query) { addFunctionOutputMessage(name, "Error: query is required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} search ${JSON.stringify(query)} 2>&1`;
            } else if (action === "read") {
                const eName = args.name || "";
                kgCmd = eName ? `python3 ${kgScript} read ${JSON.stringify(eName)} 2>&1` : `python3 ${kgScript} read 2>&1`;
            } else if (action === "delete_entity") {
                const eName = args.name || "";
                if (!eName) { addFunctionOutputMessage(name, "Error: name is required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} delete_entity ${JSON.stringify(eName)} 2>&1`;
            } else if (action === "delete_relation") {
                const from = args.from_entity || "";
                const rel = args.relation || "";
                const to = args.to_entity || "";
                if (!from || !rel || !to) { addFunctionOutputMessage(name, "Error: from_entity, relation, and to_entity required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} delete_relation ${JSON.stringify(from)} ${JSON.stringify(rel)} ${JSON.stringify(to)} 2>&1`;
            } else if (action === "delete_observation") {
                const eName = args.name || "";
                const obs = args.observation || "";
                if (!eName || !obs) { addFunctionOutputMessage(name, "Error: name and observation required"); requester.makeRequest(); return; }
                kgCmd = `python3 ${kgScript} delete_observation ${JSON.stringify(eName)} ${JSON.stringify(obs)} 2>&1`;
            } else {
                addFunctionOutputMessage(name, "Error: action must be 'search', 'read', 'delete_entity', 'delete_relation', or 'delete_observation'");
                requester.makeRequest();
                return;
            }
            commandExecutionProc.shellCommand = kgCmd;
            commandExecutionProc.running = true;
        } else if (name === "rag_search") {
            const query = args.query || "";
            if (!query) { addFunctionOutputMessage(name, "Error: query is required"); requester.makeRequest(); return; }
            const limit = Math.min(parseInt(args.limit) || 5, 20);
            const ragScript = `"${Directories.aiMemoryPath.replace('memory.md', 'rag.py')}"`;
            const ragMsg = createFunctionOutputMessage(name, "", false);
            const ragId = idForMessage(ragMsg);
            root.messageIDs = [...root.messageIDs, ragId];
            root.messageByID[ragId] = ragMsg;
            commandExecutionProc.message = ragMsg;
            commandExecutionProc.baseMessageContent = ragMsg.content;
            commandExecutionProc.shellCommand = `python3 ${ragScript} search ${JSON.stringify(query)} ${limit} 2>&1`;
            commandExecutionProc.running = true;
        } else if (name === "rag_index") {
            const path = args.path || "";
            if (!path) { addFunctionOutputMessage(name, "Error: path is required"); requester.makeRequest(); return; }
            const ragScript = `"${Directories.aiMemoryPath.replace('memory.md', 'rag.py')}"`;
            const ragMsg = createFunctionOutputMessage(name, "", false);
            const ragId = idForMessage(ragMsg);
            root.messageIDs = [...root.messageIDs, ragId];
            root.messageByID[ragId] = ragMsg;
            commandExecutionProc.message = ragMsg;
            commandExecutionProc.baseMessageContent = ragMsg.content;
            let ragCmd = `python3 ${ragScript} index ${JSON.stringify(path)}`;
            if (args.extensions) ragCmd += ` --ext=${args.extensions}`;
            ragCmd += " 2>&1";
            commandExecutionProc.shellCommand = ragCmd;
            commandExecutionProc.running = true;
        } else if (name === "calendar") {
            const action = (args.action || "today").trim();
            const calScript = Quickshell.env("HOME") + "/.config/quickshell/ii/scripts/ai/calendar.sh";
            const calMsg = createFunctionOutputMessage(name, "", false);
            const calId = idForMessage(calMsg);
            root.messageIDs = [...root.messageIDs, calId];
            root.messageByID[calId] = calMsg;
            commandExecutionProc.message = calMsg;
            commandExecutionProc.baseMessageContent = calMsg.content;
            let calCmd = "";
            if (action === "today") {
                calCmd = `bash "${calScript}" today 2>&1`;
            } else if (action === "list") {
                const days = Math.min(parseInt(args.days) || 3, 30);
                calCmd = `bash "${calScript}" list ${days} 2>&1`;
            } else if (action === "now") {
                calCmd = `bash "${calScript}" now 2>&1`;
            } else if (action === "add") {
                const eventArgs = args.event_args || "";
                if (!eventArgs) { addFunctionOutputMessage(name, "Error: event_args required for add"); requester.makeRequest(); return; }
                calCmd = `bash "${calScript}" add ${eventArgs} 2>&1`;
            } else if (action === "search") {
                const query = args.query || "";
                if (!query) { addFunctionOutputMessage(name, "Error: query required for search"); requester.makeRequest(); return; }
                calCmd = `bash "${calScript}" search ${JSON.stringify(query)} 2>&1`;
            } else if (action === "sync") {
                calCmd = `bash "${calScript}" sync 2>&1`;
            } else {
                addFunctionOutputMessage(name, "Error: action must be 'today', 'list', 'now', 'add', 'search', or 'sync'");
                requester.makeRequest();
                return;
            }
            commandExecutionProc.shellCommand = calCmd;
            commandExecutionProc.running = true;
        } else if (name === "workspace_layout") {
            const action = (args.action || "current").trim();
            const layoutScript = Quickshell.env("HOME") + "/.config/quickshell/ii/scripts/ai/workspace-layout.sh";
            const wlMsg = createFunctionOutputMessage(name, "", false);
            const wlId = idForMessage(wlMsg);
            root.messageIDs = [...root.messageIDs, wlId];
            root.messageByID[wlId] = wlMsg;
            commandExecutionProc.message = wlMsg;
            commandExecutionProc.baseMessageContent = wlMsg.content;
            let wlCmd = "";
            if (action === "current") {
                wlCmd = `bash "${layoutScript}" current 2>&1`;
            } else if (action === "save") {
                const lname = args.name || "";
                if (!lname) { addFunctionOutputMessage(name, "Error: name required for save"); requester.makeRequest(); return; }
                wlCmd = `bash "${layoutScript}" save ${JSON.stringify(lname)} 2>&1`;
            } else if (action === "restore") {
                const lname = args.name || "";
                if (!lname) { addFunctionOutputMessage(name, "Error: name required for restore"); requester.makeRequest(); return; }
                wlCmd = `bash "${layoutScript}" restore ${JSON.stringify(lname)} 2>&1`;
            } else if (action === "list") {
                wlCmd = `bash "${layoutScript}" list 2>&1`;
            } else if (action === "delete") {
                const lname = args.name || "";
                if (!lname) { addFunctionOutputMessage(name, "Error: name required for delete"); requester.makeRequest(); return; }
                wlCmd = `bash "${layoutScript}" delete ${JSON.stringify(lname)} 2>&1`;
            } else {
                addFunctionOutputMessage(name, "Error: action must be 'save', 'restore', 'list', 'delete', or 'current'");
                requester.makeRequest();
                return;
            }
            commandExecutionProc.shellCommand = wlCmd;
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
        } else if (name === "drag_to") {
            const imgW  = root.lastScreenshotWidth  > 0 ? root.lastScreenshotWidth  : 1920;
            const imgH  = root.lastScreenshotHeight > 0 ? root.lastScreenshotHeight : 1080;
            const scale = root.lastScreenshotScale  > 0 ? root.lastScreenshotScale  : 1.0;
            const rawX1 = parseFloat(args.x1) || 0;
            const rawY1 = parseFloat(args.y1) || 0;
            const rawX2 = parseFloat(args.x2) || 0;
            const rawY2 = parseFloat(args.y2) || 0;
            const button = (args.button || "left").toLowerCase();
            const nativeW = Math.round(imgW * scale);
            const nativeH = Math.round(imgH * scale);
            const sx1 = Math.max(0, Math.min(Math.round(rawX1 * scale), nativeW)) + root.lastScreenshotOffsetX;
            const sy1 = Math.max(0, Math.min(Math.round(rawY1 * scale), nativeH)) + root.lastScreenshotOffsetY;
            const sx2 = Math.max(0, Math.min(Math.round(rawX2 * scale), nativeW)) + root.lastScreenshotOffsetX;
            const sy2 = Math.max(0, Math.min(Math.round(rawY2 * scale), nativeH)) + root.lastScreenshotOffsetY;
            const ydoBtn = button === "right" ? "3" : "1";
            root._lastClickInfo = `drag_to (${rawX1},${rawY1}) → (${rawX2},${rawY2})`;
            addFunctionOutputMessage(name, `Dragging (${rawX1},${rawY1}) → (${rawX2},${rawY2}) screen (${sx1},${sy1}) → (${sx2},${sy2})`);
            const dragCmd = `sleep 0.15 && ydotool mousemove --absolute -x ${sx1} -y ${sy1} && sleep 0.1 && ydotool click --button-down ${ydoBtn} && sleep 0.1 && ydotool mousemove --absolute -x ${sx2} -y ${sy2} && sleep 0.1 && ydotool click --button-up ${ydoBtn}`;
            root.requestHideSidebars();
            Quickshell.execDetached(["bash", "-c", dragCmd]);
            triggerAutoScreenshot(1000);
        } else if (name === "hover") {
            const imgW  = root.lastScreenshotWidth  > 0 ? root.lastScreenshotWidth  : 1920;
            const imgH  = root.lastScreenshotHeight > 0 ? root.lastScreenshotHeight : 1080;
            const scale = root.lastScreenshotScale  > 0 ? root.lastScreenshotScale  : 1.0;
            const rawX  = parseFloat(args.x) || 0;
            const rawY  = parseFloat(args.y) || 0;
            const nativeW = Math.round(imgW * scale);
            const nativeH = Math.round(imgH * scale);
            const sx = Math.max(0, Math.min(Math.round(rawX * scale), nativeW)) + root.lastScreenshotOffsetX;
            const sy = Math.max(0, Math.min(Math.round(rawY * scale), nativeH)) + root.lastScreenshotOffsetY;
            root._lastClickInfo = `hover (${rawX}, ${rawY})`;
            addFunctionOutputMessage(name, `Hovering at (${rawX}, ${rawY}) → screen (${sx}, ${sy})`);
            const hoverCmd = `sleep 0.15 && ydotool mousemove --absolute -x ${sx} -y ${sy}`;
            root.requestHideSidebars();
            Quickshell.execDetached(["bash", "-c", hoverCmd]);
            triggerAutoScreenshot(800);
        } else if (name === "read_screen_text") {
            const hasRegion = args.x !== undefined && args.y !== undefined && args.width !== undefined && args.height !== undefined;
            const scale = root.lastScreenshotScale > 0 ? root.lastScreenshotScale : 1.0;
            let grimArgs = "";
            if (hasRegion) {
                const rx = Math.round((parseFloat(args.x) || 0) * scale) + root.lastScreenshotOffsetX;
                const ry = Math.round((parseFloat(args.y) || 0) * scale) + root.lastScreenshotOffsetY;
                const rw = Math.round((parseFloat(args.width) || 200) * scale);
                const rh = Math.round((parseFloat(args.height) || 100) * scale);
                grimArgs = `-g "${rx},${ry} ${rw}x${rh}"`;
            } else {
                // Full active monitor
                grimArgs = "";
            }
            const ocrMsg = createFunctionOutputMessage(name, "", false);
            const ocrId = idForMessage(ocrMsg);
            root.messageIDs = [...root.messageIDs, ocrId];
            root.messageByID[ocrId] = ocrMsg;
            commandExecutionProc.message = ocrMsg;
            commandExecutionProc.baseMessageContent = ocrMsg.content;
            const tmpImg = "/tmp/quickshell/ai/ocr_region.png";
            let ocrCmd = "";
            if (hasRegion) {
                ocrCmd = `grim ${grimArgs} "${tmpImg}" 2>&1 && tesseract "${tmpImg}" - 2>/dev/null || echo "(OCR failed)"`;
            } else {
                // Get active monitor name first
                ocrCmd = `MON=$(hyprctl monitors -j 2>/dev/null | python3 -c "
import json,sys,subprocess
mons=json.loads(sys.stdin.read())
try:
    aw=json.loads(subprocess.run(['hyprctl','activewindow','-j'],capture_output=True,text=True).stdout or '{}')
    mid=aw.get('monitor',-1)
    if mid>=0:
        for m in mons:
            if m.get('id')==mid: print(m.get('name','')); sys.exit()
except: pass
for m in mons:
    if m.get('focused'): print(m.get('name','')); sys.exit()
if mons: print(mons[0].get('name',''))
" 2>/dev/null) && grim -o "$MON" "${tmpImg}" 2>&1 && tesseract "${tmpImg}" - 2>/dev/null || echo "(OCR failed)"`;
            }
            commandExecutionProc.shellCommand = ocrCmd;
            commandExecutionProc.running = true;
        } else if (name === "manage_tabs") {
            const action = (args.action || "").toLowerCase().trim();
            const index = Math.min(Math.max(parseInt(args.index) || 1, 1), 9);
            const keyMap = {
                "next": "29:1 15:1 15:0 29:0",      // ctrl+tab
                "prev": "29:1 42:1 15:1 15:0 42:0 29:0", // ctrl+shift+tab
                "close": "29:1 17:1 17:0 29:0",     // ctrl+w
                "new": "29:1 20:1 20:0 29:0",       // ctrl+t
                "reopen": "29:1 42:1 20:1 20:0 42:0 29:0" // ctrl+shift+t
            };
            if (action === "goto") {
                // ctrl+1 through ctrl+9 — key codes: 1=2, 2=3, ..., 9=10
                const keyCode = index + 1;
                Quickshell.execDetached(["bash", "-c", `ydotool key 29:1 ${keyCode}:1 ${keyCode}:0 29:0`]);
                addFunctionOutputMessage(name, `Switched to tab ${index}`);
            } else if (keyMap[action]) {
                Quickshell.execDetached(["bash", "-c", `ydotool key ${keyMap[action]}`]);
                addFunctionOutputMessage(name, `Tab action: ${action}`);
            } else {
                addFunctionOutputMessage(name, `Unknown action: '${action}'. Use: next, prev, close, goto, new, reopen`);
            }
            requester.makeRequest();
        } else if (name === "wait_and_screenshot") {
            const seconds = Math.min(Math.max(parseFloat(args.seconds) || 3, 1), 15);
            const reason = args.reason || "waiting for UI update";
            addFunctionOutputMessage(name, `Waiting ${seconds}s: ${reason}`);
            root.requestHideSidebars();
            triggerAutoScreenshot(seconds * 1000);
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
            // Route native music apps through oi-task for reliable code-based playback
            const nativeApps = ["spotify", "youtubemusic", "soundcloud"];
            if (nativeApps.includes(app)) {
                const responseMessage = createFunctionOutputMessage(name, "", false);
                const id = idForMessage(responseMessage);
                root.messageIDs = [...root.messageIDs, id];
                root.messageByID[id] = responseMessage;
                commandExecutionProc.message = responseMessage;
                commandExecutionProc.baseMessageContent = responseMessage.content;
                const escapedQuery = query.replace(/'/g, "'\\''");
                const escapedApp = args.app || app;
                commandExecutionProc.shellCommand = `oi-task 'Search for "${escapedQuery}" on ${escapedApp} and play it. Use playerctl or dbus to control the app.'`;
                commandExecutionProc.running = true;
                return;
            }
            const encoded = encodeURIComponent(query);
            let uri;
            switch (app) {
                case "youtube":       uri = `https://youtube.com/search?q=${encoded}`; break;
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
        self.text_parts = []
        self._in_title = False
        self._skip_tags = {"script","style","noscript","svg","head","nav","footer","header"}
        self._skip_depth = 0
        self._interactive = {"input","button","select","textarea","a","form","label"}
        self._content_tags = {"p","h1","h2","h3","h4","h5","h6","li","td","th","span","div","article","section","blockquote","figcaption","strong","em","b","i"}
        self._in_content = 0
        self._cur_tag = ""

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in self._skip_tags:
            self._skip_depth += 1
            return
        if self._skip_depth: return
        if tag == "title":
            self._in_title = True
        if tag in self._content_tags:
            self._in_content += 1
            self._cur_tag = tag
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
        if tag in self._content_tags and self._in_content:
            self._in_content -= 1
            if tag in ("p","h1","h2","h3","h4","h5","h6","li","blockquote"):
                self.text_parts.append("")  # paragraph break

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._in_content and not self._skip_depth:
            text = data.strip()
            if text and len(text) > 1:
                self.text_parts.append(text)

html = sys.stdin.read()
p = ElemParser()
p.feed(html)
print(f"Page: {p.title.strip()}")
print(f"URL: ${url.replace(/'/g, "'\\''")}")

# Page text content (truncated to ~3000 chars for context window)
text = " ".join(t for t in p.text_parts if t).strip()
# Collapse whitespace
text = re.sub(r'\s+', ' ', text)
if text:
    print("")
    print(f"Content ({len(text)} chars):")
    print(text[:3000])
    if len(text) > 3000:
        print(f"... truncated ({len(text)} total chars)")

print("")
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
            const shellSafeJS = js.replace(/'/g, "'\\''");
            addFunctionOutputMessage(name, `Executing JS in browser...`);
            // Copy JS to clipboard, open DevTools console, paste and run, then close console
            const execCmd = `printf '%s' '${shellSafeJS}' | wl-copy
qs -p ~/.config/quickshell/ii ipc call sidebarLeft close 2>/dev/null
sleep 0.5
hyprctl dispatch focuswindow "class:firefox" 2>/dev/null
sleep 0.5
wtype -k F12
sleep 1.5
wtype -M ctrl -k v -m ctrl
sleep 0.3
wtype -k Return
sleep 3
wtype -k F12
`;
            Quickshell.execDetached(["bash", "-c", execCmd]);
            // Auto-screenshot after JS and console automation have time to complete (~7s total)
            Qt.callLater(() => {
                root._pendingVisionFollowUpKind = "execute_js";
                const dest = "/tmp/quickshell/ai/screenshot.png";
                const cmd = `
mkdir -p /tmp/quickshell/ai
sleep 7
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys,subprocess
mons=json.loads(os.environ.get("MONITORS","[]"))
try:
    aw=json.loads(subprocess.run(["hyprctl","activewindow","-j"],capture_output=True,text=True).stdout or "{}")
    mid=aw.get("monitor",-1)
    if mid>=0:
        for m in mons:
            if m.get("id")==mid: print(m.get("name","")); sys.exit()
except: pass
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
MON_NAME=$(echo "$MON_NAME" | head -n1 | tr -d '\r')
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 2>&1 << 'PYEOF'
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
cx_in_bounds = 0 <= cx_img < W and 0 <= cy_img < H
composite = Image.alpha_composite(img, overlay).convert('RGB')
MAX_W = 1920
sf = 1.0
if W > MAX_W:
    sf = W / MAX_W
    new_h = round(H * MAX_W / W)
    composite = composite.resize((MAX_W, new_h), Image.LANCZOS)
    W_out, H_out = MAX_W, new_h
else:
    W_out, H_out = W, H
composite.save(dest)
cx_s = round(cx_img / sf) if cx_in_bounds else -1
cy_s = round(cy_img / sf) if cx_in_bounds else -1
print(f"GRID_META:{W_out}:{H_out}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
print(f"IMG_SCALE:{sf:.6f}")
print(f"CURSOR_S:{cx_s}:{cy_s}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
SCALE=$(echo "\${META}" | grep "^IMG_SCALE:" | cut -d: -f2)
SCALE=\${SCALE:-1.0}
CURSOR_LINE=$(echo "\${META}" | grep "^CURSOR_S:")
CURSOR_SS_X=$(echo "\${CURSOR_LINE}" | cut -d: -f2)
CURSOR_SS_Y=$(echo "\${CURSOR_LINE}" | cut -d: -f3)
CURSOR_SS_X=\${CURSOR_SS_X:--1}
CURSOR_SS_Y=\${CURSOR_SS_Y:--1}
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:\${SCALE}"
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
            const title = args.title || args.plan || args.task || "Task Plan";
            // Normalize steps: handle array, string, or missing
            let steps = args.steps || args.plan_steps || [];
            if (typeof steps === "string") {
                // Model sent steps as a string — split on newlines or numbered lines
                steps = steps.split(/\n|(?=\d+\.\s)/).filter(s => s.trim()).map(s => ({ description: s.replace(/^\d+\.\s*/, "").trim() }));
            }
            if (!Array.isArray(steps)) steps = [];
            // Normalize step objects — model might send strings instead of objects
            steps = steps.map(s => typeof s === "string" ? { description: s } : s);
            const stepsText = steps.length > 0
                ? steps.map((s, i) => `${i + 1}. **${s.description || s.step || JSON.stringify(s)}**${s.tool ? ` *(${s.tool})*` : ""}`).join("\n")
                : `*${title}*`;
            const approveCmd = `echo "Plan approved — proceed with the task"`;
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

                if (imgW <= 0 || imgH <= 0) {
                    const rawPreview = this.text.length > 1200 ? this.text.substring(0, 1200) + "…" : this.text;
                    root._lastClickInfo = "";
                    root.pendingFilePath = "";
                    addFunctionOutputMessage("take_screenshot",
                        `Screenshot failed (invalid size ${imgW}×${imgH}). Usually grim wrote an empty/invalid file, Python could not read it, or GRID_META was missing from script output. Verify \`grim\`, Pillow, and Hyprland monitor names.\n\n--- Script output (debug) ---\n${rawPreview}`);
                    requester.makeRequest();
                    return;
                }

                const cursorInfo = curX >= 0 ? ` Cursor at (${curX}, ${curY}).` : "";
                const gridInfo = ` Grid: ${gridCols}×${gridRows} (cell size ${(imgW/gridCols)|0}×${(imgH/gridRows)|0}px).`;
                const isAutoFollowUp = (root._pendingVisionFollowUpKind === "execute_js" || root._pendingVisionFollowUpKind === "followup");
                const evalHint = isAutoFollowUp
                    ? " This is an automatic follow-up screenshot. Your action is complete — STOP and respond to the user in text. Do NOT call any more tools unless something clearly went wrong."
                    : root._lastClickInfo.length > 0
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
                "toolCallId": message.toolCallId,
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

    Process {
        id: activityContextProc
        running: true
        command: ["bash", Quickshell.env("HOME") + "/.config/quickshell/ii/scripts/ai/activity-context.sh"]
        stdout: StdioCollector {
            onStreamFinished: root.activityContext = this.text.trim()
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
            activityContextProc.running = true;
        }
    }

    // Auto-screenshot after native app search (e.g. Spotify) so AI can click results
    Timer {
        id: nativeAppSearchTimer
        interval: 2500
        repeat: false
        onTriggered: {
            root._pendingVisionFollowUpKind = "followup";
            const dest = CF.FileUtils.trimFileProtocol(`${Directories.aiSttTemp}/screenshot.png`);
            const cmd = `
DEST="${dest}"
MONITORS=$(hyprctl monitors -j 2>/dev/null | tr -d '\n' || echo '[]')
CURSOR=$(hyprctl cursorpos 2>/dev/null || echo "0, 0")
CX=$(echo "\${CURSOR}" | awk '{gsub(/,/,"",$1); print $1}')
CY=$(echo "\${CURSOR}" | awk '{print $2}')
MON_NAME=$(MONITORS="$MONITORS" python3 -c '
import json,os,sys,subprocess
mons=json.loads(os.environ.get("MONITORS","[]"))
try:
    aw=json.loads(subprocess.run(["hyprctl","activewindow","-j"],capture_output=True,text=True).stdout or "{}")
    mid=aw.get("monitor",-1)
    if mid>=0:
        for m in mons:
            if m.get("id")==mid: print(m.get("name","")); sys.exit()
except: pass
for m in mons:
    if m.get("focused"): print(m.get("name","")); sys.exit()
if mons: print(mons[0].get("name",""))
' 2>/dev/null || echo "")
MON_NAME=$(echo "$MON_NAME" | head -n1 | tr -d '\r')
if [ -n "$MON_NAME" ]; then
    grim -o "$MON_NAME" "$DEST" 2>&1 || exit 1
else
    grim "$DEST" 2>&1 || exit 1
fi
META=$(DEST=$DEST CX=\${CX} CY=\${CY} MONITORS="$MONITORS" MON_NAME="$MON_NAME" python3 2>&1 << 'PYEOF'
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
cx_in_bounds = 0 <= cx_img < W and 0 <= cy_img < H
composite = Image.alpha_composite(img, overlay).convert('RGB')
MAX_W = 1920
sf = 1.0
if W > MAX_W:
    sf = W / MAX_W
    new_h = round(H * MAX_W / W)
    composite = composite.resize((MAX_W, new_h), Image.LANCZOS)
    W_out, H_out = MAX_W, new_h
else:
    W_out, H_out = W, H
composite.save(dest)
cx_s = round(cx_img / sf) if cx_in_bounds else -1
cy_s = round(cy_img / sf) if cx_in_bounds else -1
print(f"GRID_META:{W_out}:{H_out}:{cols}:{rows}")
print(f"SCREENSHOT_OFFSET:{off_x}:{off_y}")
print(f"IMG_SCALE:{sf:.6f}")
print(f"CURSOR_S:{cx_s}:{cy_s}")
PYEOF
)
SS_OFFSET_X=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f2)
SS_OFFSET_Y=$(echo "\${META}" | grep "^SCREENSHOT_OFFSET:" | cut -d: -f3)
SS_OFFSET_X=\${SS_OFFSET_X:-0}
SS_OFFSET_Y=\${SS_OFFSET_Y:-0}
GRID_LINE=$(echo "\${META}" | grep "^GRID_META:")
IMG_W=$(echo "\${GRID_LINE}" | cut -d: -f2)
IMG_H=$(echo "\${GRID_LINE}" | cut -d: -f3)
GRID_COLS=$(echo "\${GRID_LINE}" | cut -d: -f4)
GRID_ROWS=$(echo "\${GRID_LINE}" | cut -d: -f5)
SCALE=$(echo "\${META}" | grep "^IMG_SCALE:" | cut -d: -f2)
SCALE=\${SCALE:-1.0}
CURSOR_LINE=$(echo "\${META}" | grep "^CURSOR_S:")
CURSOR_SS_X=$(echo "\${CURSOR_LINE}" | cut -d: -f2)
CURSOR_SS_Y=$(echo "\${CURSOR_LINE}" | cut -d: -f3)
CURSOR_SS_X=\${CURSOR_SS_X:--1}
CURSOR_SS_Y=\${CURSOR_SS_Y:--1}
echo "CURSOR_POS:\${CURSOR_SS_X}:\${CURSOR_SS_Y}"
echo "GRID:\${GRID_COLS}:\${GRID_ROWS}"
echo "IMAGE_SIZE:\${IMG_W}:\${IMG_H}"
echo "IMAGE_SCALE:\${SCALE}"
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
                    "toolCallId": message.toolCallId,
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
