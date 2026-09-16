struct Session: Equatable {
    let provider: String
}

@main
enum ProviderSelectionRegression {
    static func main() {
        let sessions = [Session(provider: "claude"), Session(provider: "codex")]

        let claudeOnly = SelectionFilter.apply(
            to: sessions,
            enabled: ["claude", "codex"],
            selected: "claude",
            id: \.provider
        )
        precondition(claudeOnly == [Session(provider: "claude")])

        let enabledOnly = SelectionFilter.apply(
            to: sessions,
            enabled: ["claude"],
            selected: nil,
            id: \.provider
        )
        precondition(enabledOnly == [Session(provider: "claude")])

        print("Provider selection regression passed")
    }
}
