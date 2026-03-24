import Quickshell

ScriptModel {
    required property int count
    values: Array.from({length: count}, (_, i) => i)
}
