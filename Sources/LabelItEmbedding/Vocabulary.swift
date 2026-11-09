/// Things a phone photo can show, in three groups. A photo is compared with every phrase; the best match in
/// each group becomes a word of its name when it stands out from the rest of its group.
///
/// Add phrases freely: their vectors are computed once and cached (`GemmaPhotoDescriber`).
public enum Vocabulary {
    public struct Concept: Sendable, Hashable {
        /// The words that go into the file name.
        public let slug: String
        /// What the model reads.
        public let text: String
    }

    public enum Group: String, Sendable, CaseIterable {
        case subject, setting, light
    }

    static func subject(_ slug: String, _ phrase: String? = nil) -> Concept {
        Concept(slug: slug, text: "a photo of \(phrase ?? slug)")
    }

    static func setting(_ slug: String, _ phrase: String) -> Concept {
        Concept(slug: slug, text: "a photo taken \(phrase)")
    }

    public static let groups: [Group: [Concept]] = [
        .subject: subjects,
        .setting: settings,
        .light: light,
    ]

    static let subjects: [Concept] = [
        // People
        subject("selfie", "a selfie"), subject("portrait", "a portrait of a person"), subject("baby", "a baby"),
        subject("kids", "children playing"), subject("family", "a family together"), subject("friends", "a group of friends"),
        subject("couple", "a couple"), subject("crowd", "a crowd of people"), subject("team", "a team photo"),
        subject("graduation", "a graduation"), subject("wedding", "a wedding"), subject("birthday", "a birthday party"),
        // Animals
        subject("dog", "a dog"), subject("puppy", "a puppy"), subject("cat", "a cat"), subject("kitten", "a kitten"),
        subject("bird", "a bird"), subject("horse", "a horse"), subject("cow", "a cow"), subject("sheep", "sheep"),
        subject("fish", "fish in an aquarium"), subject("duck", "ducks"), subject("butterfly", "a butterfly"),
        // Food and drink
        subject("food", "a plate of food"), subject("breakfast", "breakfast"), subject("pizza", "a pizza"),
        subject("burger", "a burger"), subject("sushi", "sushi"), subject("pasta", "pasta"), subject("salad", "a salad"),
        subject("biryani", "biryani"), subject("curry", "curry and rice"), subject("bbq", "barbecue grilled meat"),
        subject("dessert", "a dessert"), subject("cake", "a cake"), subject("ice-cream", "ice cream"),
        subject("fruit", "fresh fruit"), subject("bread", "bread and pastries"), subject("coffee", "a cup of coffee"),
        subject("tea", "a cup of tea"), subject("cocktail", "a cocktail"), subject("wine", "a glass of wine"),
        subject("beer", "a glass of beer"), subject("groceries", "groceries"),
        // Places and nature
        subject("mountains", "mountains"), subject("lake", "a lake"), subject("river", "a river"),
        subject("waterfall", "a waterfall"), subject("ocean", "the ocean"), subject("forest", "a forest"),
        subject("flowers", "flowers"), subject("tree", "a tree"), subject("garden", "a garden"), subject("sky", "the sky and clouds"),
        subject("rainbow", "a rainbow"), subject("skyline", "a city skyline"), subject("street", "a city street"),
        subject("building", "a building"), subject("house", "a house"), subject("church", "a church"),
        subject("mosque", "a mosque"), subject("temple", "a temple"), subject("castle", "a castle"),
        subject("bridge", "a bridge"), subject("tower", "a tower"), subject("monument", "a monument"),
        subject("statue", "a statue"), subject("fountain", "a fountain"), subject("harbor", "boats in a harbor"),
        subject("window-view", "the view from a window"), subject("doorway", "a doorway or portal"),
        // Things
        subject("car", "a car"), subject("car-wheel", "a car wheel and tire"), subject("car-interior", "the inside of a car"),
        subject("car-damage", "a damaged car"), subject("dashboard", "a car dashboard"), subject("bicycle", "a bicycle"),
        subject("motorcycle", "a motorcycle"), subject("bus", "a bus"), subject("train", "a train"),
        subject("airplane", "an airplane"), subject("boat", "a boat"), subject("laptop", "a laptop"),
        subject("phone", "a phone"), subject("computer-screen", "a computer screen"), subject("tv", "a television"),
        subject("keyboard", "a keyboard"), subject("camera", "a camera"), subject("headphones", "headphones"),
        subject("watch", "a watch"), subject("shoes", "shoes"), subject("clothes", "clothes"),
        subject("outfit", "a person's outfit in a mirror"), subject("bag", "a bag"), subject("jewelry", "jewelry"),
        subject("glasses", "glasses"), subject("furniture", "furniture"), subject("sofa", "a sofa"),
        subject("bed", "a bed"), subject("desk", "a desk"), subject("chair", "a chair"), subject("lamp", "a lamp"),
        subject("plant", "a potted plant"), subject("kitchen", "a kitchen"), subject("bathroom", "a bathroom"),
        subject("living-room", "a living room"), subject("bedroom", "a bedroom"), subject("room", "an empty room"),
        subject("appliance", "a home appliance"), subject("tools", "tools"), subject("toys", "toys"),
        subject("package", "a delivery package"), subject("gift", "a gift"), subject("christmas-tree", "a Christmas tree"),
        subject("fireworks", "fireworks"), subject("candles", "candles"), subject("balloons", "balloons"),
        subject("book", "a book"), subject("art", "a painting"), subject("drawing", "a child's drawing"),
        subject("instrument", "a musical instrument"), subject("ball", "a ball"), subject("medicine", "medicine and pills"),
        // Documents and screens photographed with a camera
        subject("document", "a printed document"), subject("receipt", "a receipt"), subject("handwritten-note", "a handwritten note"),
        subject("whiteboard", "a whiteboard"), subject("slides", "a presentation on a screen"),
        subject("sign", "a sign"), subject("menu", "a restaurant menu"), subject("ticket", "a ticket"),
        subject("id-card", "an ID card"), subject("map", "a map"), subject("label", "a product label"),
        subject("barcode", "a barcode or QR code"), subject("meter", "a utility meter"),
        subject("parking", "a parking lot"), subject("construction", "a construction site"),
        // Activities and events
        subject("concert", "a concert"), subject("sports", "a sports game"), subject("stadium", "a stadium"),
        subject("running", "people running"), subject("swimming", "people swimming"), subject("hiking", "people hiking"),
        subject("skiing", "people skiing"), subject("cycling", "people cycling"), subject("gym", "a gym workout"),
        subject("cooking", "someone cooking"), subject("eating", "people eating together"), subject("meeting", "a meeting"),
        subject("classroom", "a classroom"), subject("market", "a market"), subject("shopping", "a shop"),
        subject("museum", "a museum exhibit"), subject("airport", "an airport"), subject("hotel-room", "a hotel room"),
        subject("camping", "a tent at a campsite"), subject("picnic", "a picnic"), subject("pool", "a swimming pool"),
        subject("playground", "a playground"), subject("snowman", "a snowman"),
    ]

    static let settings: [Concept] = [
        setting("beach", "on a beach"), setting("mountains", "in the mountains"), setting("forest", "in a forest"),
        setting("park", "in a park"), setting("garden", "in a garden"), setting("lake", "by a lake"),
        setting("river", "by a river"), setting("sea", "at sea"), setting("countryside", "in the countryside"),
        setting("desert", "in a desert"), setting("snow", "in the snow"), setting("city", "in a city"),
        setting("street", "on a street"), setting("old-town", "in an old town"), setting("home", "at home"),
        setting("kitchen", "in a kitchen"), setting("office", "in an office"), setting("restaurant", "in a restaurant"),
        setting("cafe", "in a cafe"), setting("bar", "in a bar"), setting("shop", "in a shop"),
        setting("supermarket", "in a supermarket"), setting("mall", "in a shopping mall"), setting("school", "at school"),
        setting("hospital", "in a hospital"), setting("gym", "in a gym"), setting("car", "in a car"),
        setting("train", "on a train"), setting("plane", "on a plane"), setting("airport", "at an airport"),
        setting("station", "at a station"), setting("hotel", "in a hotel"), setting("church", "in a church"),
        setting("mosque", "in a mosque"), setting("museum", "in a museum"), setting("stadium", "in a stadium"),
        setting("garage", "in a garage"), setting("parking-lot", "in a parking lot"), setting("road", "on a road"),
        setting("boat", "on a boat"), setting("pool", "by a pool"), setting("balcony", "on a balcony"),
        setting("rooftop", "on a rooftop"), setting("stage", "on a stage"),
    ]

    static let light: [Concept] = [
        setting("sunset", "at sunset"), setting("sunrise", "at sunrise"), setting("night", "at night"),
        setting("sunny", "on a sunny day"), setting("rainy", "on a rainy day"), setting("foggy", "on a foggy day"),
        setting("snowy", "while it snows"), setting("cloudy", "on a cloudy day"),
    ]
}
