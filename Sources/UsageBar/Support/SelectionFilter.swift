enum SelectionFilter {
    static func apply<Item, ID: Hashable>(
        to items: [Item],
        enabled: Set<ID>,
        selected: ID?,
        id: (Item) -> ID
    ) -> [Item] {
        items.filter { item in
            let itemID = id(item)
            return enabled.contains(itemID) && (selected == nil || itemID == selected)
        }
    }
}
