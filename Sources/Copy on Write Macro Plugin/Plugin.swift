import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
fileprivate struct CopyOnWritePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        CoWMacro.self,
        CoWPropertyMacro.self,
    ]
}
