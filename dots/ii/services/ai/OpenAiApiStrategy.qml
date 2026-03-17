import QtQuick

ApiStrategy {
    property bool isReasoning: false
    property var pendingToolCall: null

    function buildEndpoint(model: AiModel): string {
        // console.log("[AI] Endpoint: " + model.endpoint);
        return model.endpoint;
    }

    function buildRequestData(model: AiModel, messages, systemPrompt: string, temperature: real, tools: list<var>, filePath: string) {
        let baseData = {
            "model": model.model,
            "messages": [
                {role: "system", content: systemPrompt},
                ...messages.map(message => {
                    return {
                        "role": message.role,
                        "content": message.rawContent,
                    }
                }),
            ],
            "stream": true,
            "tools": tools,
            "tool_choice": (tools && tools.length > 0) ? "auto" : "none",
            "temperature": temperature,
            "max_tokens": 8192,
        };
        return model.extraParams ? Object.assign({}, baseData, model.extraParams) : baseData;
    }

    function buildAuthorizationHeader(apiKeyEnvVarName: string): string {
        return `-H "Authorization: Bearer \$\{${apiKeyEnvVarName}\}"`;
    }

    function parseResponseLine(line, message) {
        let cleanData = line.trim();
        if (cleanData.startsWith("data:")) {
            cleanData = cleanData.slice(5).trim();
        }

        if (!cleanData || cleanData.startsWith(":")) return {};
        if (cleanData === "[DONE]") {
            return { finished: true };
        }

        try {
            const dataJson = JSON.parse(cleanData);

            if (dataJson.error) {
                const errorMsg = `**Error**: ${dataJson.error.message || JSON.stringify(dataJson.error)}`;
                message.rawContent += errorMsg;
                message.content += errorMsg;
                return { finished: true };
            }

            let newContent = "";

            const responseContent = dataJson.choices[0]?.delta?.content || dataJson.message?.content;
            const responseReasoning = dataJson.choices[0]?.delta?.reasoning || dataJson.choices[0]?.delta?.reasoning_content;

            if (responseContent && responseContent.length > 0) {
                if (isReasoning) {
                    isReasoning = false;
                    const endBlock = "\n\n</think>\n\n";
                    message.content += endBlock;
                    message.rawContent += endBlock;
                }
                newContent = responseContent;
            } else if (responseReasoning && responseReasoning.length > 0) {
                if (!isReasoning) {
                    isReasoning = true;
                    const startBlock = "\n\n<think>\n\n";
                    message.rawContent += startBlock;
                    message.content += startBlock;
                }
                newContent = responseReasoning;
            }

            message.content += newContent;
            message.rawContent += newContent;

            // Tool call handling (accumulate across streaming chunks)
            // NOTE: always reassign the whole object (not just mutate properties)
            // because QML property var may return a copy on read, causing mutations to be lost.
            const toolCallDelta = dataJson.choices?.[0]?.delta?.tool_calls?.[0];
            if (toolCallDelta) {
                const cur = pendingToolCall || { name: "", arguments: "" };
                pendingToolCall = {
                    name: (cur.name || toolCallDelta.function?.name || ""),
                    arguments: cur.arguments + (toolCallDelta.function?.arguments || ""),
                };
            }

            const finishReason = dataJson.choices?.[0]?.finish_reason;
            if (finishReason === "tool_calls") {
                // Ollama sometimes puts the full tool call in message.tool_calls on the
                // final chunk instead of streaming it via delta.tool_calls. Fall back to that.
                if (!pendingToolCall?.name) {
                    const msgToolCall = dataJson.choices?.[0]?.message?.tool_calls?.[0];
                    if (msgToolCall?.function?.name) {
                        pendingToolCall = {
                            name: msgToolCall.function.name,
                            arguments: msgToolCall.function.arguments || "",
                        };
                    }
                }
                if (pendingToolCall?.name) {
                    let parsedArgs = {};
                    try { parsedArgs = JSON.parse(pendingToolCall.arguments); } catch(e) {
                        console.log("[AI] Failed to parse tool args:", e, "raw:", pendingToolCall.arguments);
                    }
                    const call = { name: pendingToolCall.name, args: parsedArgs };
                    pendingToolCall = null;
                    return { functionCall: call };
                }
            }

            if (dataJson.usage) {
                return {
                    tokenUsage: {
                        input: dataJson.usage.prompt_tokens ?? -1,
                        output: dataJson.usage.completion_tokens ?? -1,
                        total: dataJson.usage.total_tokens ?? -1
                    }
                };
            }

            if (dataJson.done) {
                return { finished: true };
            }

        } catch (e) {
            console.log("[AI] OpenAI: Could not parse line: ", e);
        }

        return {};
    }

    function onRequestFinished(message) {
        return {};
    }

    function reset() {
        isReasoning = false;
        pendingToolCall = null;
    }

}
