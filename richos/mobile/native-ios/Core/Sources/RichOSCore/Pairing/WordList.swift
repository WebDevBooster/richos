// The 256-word list for the six-word fingerprint check, one word per byte.
//
// A byte-for-byte copy of `richos/web/web-app/lib/wordlist.js` (`WORDS`), which the Mac mirrors in
// `richos/app/src-tauri/src/phone/ca.rs`. The core tests read the JavaScript file and fail if the two
// ever differ, so the phone and the Mac can never show different words for the same certificate.
public enum WordList {
    public static let words: [String] = [
        "anchor", "apple", "april", "arrow", "artist", "aspen", "autumn", "avenue",
        "bacon", "badge", "basket", "beard", "beetle", "bench", "berry", "bishop",
        "blanket", "blossom", "bonus", "border", "bottle", "boulder", "branch", "bridge",
        "bronze", "brush", "bucket", "buffalo", "bundle", "butler", "cabin", "cactus",
        "camera", "candle", "canyon", "carbon", "cargo", "carpet", "castle", "cavern",
        "cedar", "cement", "census", "chapel", "cherry", "chimney", "circus", "clover",
        "cobalt", "cobra", "coffee", "collar", "column", "comet", "compass", "copper",
        "coral", "cotton", "cousin", "cowboy", "crayon", "cricket", "crystal", "cushion",
        "dagger", "dairy", "dancer", "decade", "denim", "desert", "diamond", "diesel",
        "dinner", "doctor", "dolphin", "domain", "donkey", "dragon", "drawer", "drummer",
        "eagle", "elbow", "elder", "ember", "engine", "estate", "expert", "fabric",
        "falcon", "farmer", "feather", "fiber", "fiddle", "figure", "filter", "finger",
        "flame", "flute", "forest", "fortune", "fossil", "freezer", "friend", "frozen",
        "gadget", "galaxy", "gallon", "garden", "garlic", "gazelle", "giant", "glacier",
        "glass", "glove", "granite", "grape", "gravel", "guitar", "gutter", "hammer",
        "harbor", "harvest", "helmet", "hermit", "hockey", "honey", "horizon", "hornet",
        "hotel", "hunter", "iceberg", "igloo", "indigo", "island", "ivory", "jacket",
        "jaguar", "jasmine", "jelly", "journal", "jungle", "junior", "kayak", "kernel",
        "kettle", "kitchen", "kitten", "koala", "ladder", "lagoon", "lantern", "laptop",
        "laser", "lawyer", "leader", "legend", "lemon", "leopard", "letter", "lettuce",
        "lily", "lizard", "lobster", "locker", "lotus", "lumber", "lunar", "magnet",
        "mammal", "mango", "manor", "maple", "marble", "margin", "marine", "market",
        "mason", "meadow", "medal", "melody", "mentor", "mermaid", "meteor", "mirror",
        "mixer", "model", "monarch", "monsoon", "moose", "morning", "mosaic", "motor",
        "muffin", "mural", "museum", "music", "mustang", "mustard", "napkin", "nectar",
        "needle", "neon", "nephew", "nickel", "noodle", "nugget", "nurse", "nutmeg",
        "oasis", "ocean", "octopus", "office", "olive", "onion", "orange", "orbit",
        "orchid", "organ", "otter", "outlaw", "oxygen", "oyster", "pajama", "palace",
        "pancake", "panda", "panther", "papaya", "parade", "parcel", "parlor", "parrot",
        "pasta", "pastry", "patio", "peanut", "pebble", "pelican", "pencil", "penguin",
        "pepper", "petal", "phantom", "pianist", "picnic", "pigeon", "pillow", "pilot",
        "pirate", "pistol", "planet", "plaza", "pocket", "poet", "polar", "pony",
    ]
}
