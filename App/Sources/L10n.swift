import Foundation

/// Texto localizado. A chave é o próprio texto em inglês; traduções em `*.lproj/Localizable.strings`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let s = NSLocalizedString(key, comment: "")
    return args.isEmpty ? s : String(format: s, arguments: args)
}
