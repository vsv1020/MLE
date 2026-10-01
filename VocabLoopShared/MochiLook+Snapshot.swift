import Foundation

public extension MochiLook {
    /// Mochi from raw values, as the widget snapshot and the Live Activity carry it.
    ///
    /// Forgiving on purpose: a colour this build does not know draws vanilla, an unknown
    /// accessory is dropped, and a second item for a slot that is already taken is ignored —
    /// a widget that draws a slightly plainer Mochi is fine, one that draws nothing is not.
    init(level: Int, bodyColor: String, accessories: [String]) {
        var taken = Set<MochiAccessory.Slot>()
        let worn = accessories
            .compactMap(MochiAccessory.init(rawValue:))
            .filter { taken.insert($0.slot).inserted }
        self.init(
            stage: MochiStage(level: level),
            color: MochiBodyColor(rawValue: bodyColor) ?? .vanilla,
            accessories: worn
        )
    }

    /// Mochi as the snapshot file describes it.
    init(snapshot: WidgetSnapshot) {
        self.init(level: snapshot.mochiLevel, bodyColor: snapshot.bodyColor, accessories: snapshot.accessories)
    }
}
