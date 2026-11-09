import LabelItCore

/// When LabelIt offers to download EmbeddingGemma 2. It's never downloaded unasked: setup offers it, ticked unless the
/// network costs money, and someone who said no is reminded once, by the first phone photo named without it.
public enum ModelOffer {
    /// Whether setup's "download the photo model" box starts ticked. Not on a phone hotspot or with Low Data Mode on:
    /// 865 MB there is the user's call.
    public static func preselected(networkIsExpensive: Bool, networkIsConstrained: Bool) -> Bool {
        !networkIsExpensive && !networkIsConstrained
    }

    /// Whether this rename is the moment to remind: a phone file, named without the model, by someone who finished
    /// setup, wants photos described, and hasn't been reminded (or started a download) before.
    public static func shouldRemind(after source: Source, modelAvailable: Bool, downloading: Bool,
                                    describePhotos: Bool, onboarded: Bool, alreadyReminded: Bool) -> Bool {
        source == .phone && !modelAvailable && !downloading && describePhotos && onboarded && !alreadyReminded
    }
}
