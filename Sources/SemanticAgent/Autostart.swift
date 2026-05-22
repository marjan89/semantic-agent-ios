#if DEBUG
import Foundation

@_cdecl("_semantic_agent_autostart")
func _semanticAgentAutostart() {
    SemanticAgent.shared.start()
}
#endif
