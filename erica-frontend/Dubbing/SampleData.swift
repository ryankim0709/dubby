import SwiftUI

/// Demo content. Line timings match the synthetic stems in Dubbing/Media, which stand in for
/// licensed clips; replace a scene's media files with prepared ones of the same names.
enum SampleData {
    // MARK: Scenes

    static let anakin = SceneCharacter(
        id: "anakin",
        name: "Anakin",
        tagline: "The Chosen One, turned",
        artwork: Artwork(imageName: "character-anakin", placeholder: [Color(hex: 0x8A2A12), Color(hex: 0x1C0705)])
    )

    static let obiWan = SceneCharacter(
        id: "obiwan",
        name: "Obi-Wan",
        tagline: "His master, heartbroken",
        artwork: Artwork(imageName: "character-obiwan", placeholder: [Color(hex: 0x9A7B55), Color(hex: 0x2A1E12)])
    )

    static let underestimate = SceneClip(
        id: "underestimate",
        title: "You underestimate my power",
        source: SceneSource(title: "Star Wars: Revenge of the Sith", year: 2005, format: "Film"),
        synopsis: "On the burning planet Mustafar, Anakin turns on his old master. Obi-Wan pleads with him one last time before their duel ends on the riverbank.",
        language: "English",
        languageCode: "en",
        duration: 18,
        difficulty: .medium,
        artwork: Artwork(imageName: "scene-underestimate", placeholder: [Color(hex: 0x2A0806), Color(hex: 0xB8401C), Color(hex: 0xE07A2E)]),
        characters: [anakin, obiWan],
        lines: [
            ScriptLine(id: "u1", characterID: "anakin", text: "You turned her against me!", translations: ["zh-Hans": "你让她背叛了我！"], start: 0.8, end: 2.6),
            ScriptLine(id: "u2", characterID: "obiwan", text: "You have done that yourself.", translations: ["zh-Hans": "那是你自己造成的。"], start: 3.2, end: 5.0),
            ScriptLine(id: "u3", characterID: "anakin", text: "You will not take her from me!", translations: ["zh-Hans": "你休想把她从我身边夺走！"], start: 5.6, end: 7.6),
            ScriptLine(id: "u4", characterID: "obiwan", text: "Your anger and your lust for power have already done that.", translations: ["zh-Hans": "你的愤怒和对权力的贪欲早已做到了这一点。"], start: 8.2, end: 11.2),
            ScriptLine(id: "u5", characterID: "obiwan", text: "It's over, Anakin. I have the high ground.", translations: ["zh-Hans": "结束了，安纳金。我占据了高地。"], start: 12.4, end: 14.4),
            ScriptLine(id: "u6", characterID: "anakin", text: "You underestimate my power!", translations: ["zh-Hans": "你低估了我的力量！"], start: 15.0, end: 16.9),
        ],
        media: SceneMediaFiles(
            video: "underestimate-video.mp4",
            bed: "underestimate-bed.m4a",
            stems: ["anakin": "underestimate-anakin.m4a", "obiwan": "underestimate-obiwan.m4a"]
        ),
        dubCount: 12_400,
        glossary: [
            "you": ["zh-Hans": "你"],
            "turned": ["zh-Hans": "使转变；turned … against：使…反对"],
            "her": ["zh-Hans": "她"],
            "against": ["zh-Hans": "反对；对抗"],
            "me": ["zh-Hans": "我（宾格）"],
            "have": ["zh-Hans": "已经（与过去分词连用）"],
            "done": ["zh-Hans": "做了；完成了"],
            "that": ["zh-Hans": "那；那件事"],
            "yourself": ["zh-Hans": "你自己"],
            "will": ["zh-Hans": "将会"],
            "not": ["zh-Hans": "不"],
            "take": ["zh-Hans": "带走；夺走"],
            "from": ["zh-Hans": "从…那里"],
            "your": ["zh-Hans": "你的"],
            "anger": ["zh-Hans": "愤怒"],
            "and": ["zh-Hans": "和"],
            "lust": ["zh-Hans": "贪欲；强烈的渴望"],
            "for": ["zh-Hans": "对…；为了"],
            "power": ["zh-Hans": "力量；权力"],
            "already": ["zh-Hans": "已经"],
            "it's": ["zh-Hans": "它是（it is 的缩写）"],
            "over": ["zh-Hans": "结束了"],
            "anakin": ["zh-Hans": "安纳金（人名）"],
            "i": ["zh-Hans": "我"],
            "the": ["zh-Hans": "这；那（定冠词）"],
            "high": ["zh-Hans": "高的；high ground：高地、有利位置"],
            "ground": ["zh-Hans": "地面；场地"],
            "underestimate": ["zh-Hans": "低估"],
            "my": ["zh-Hans": "我的"],
        ]
    )

    static let bree = SceneCharacter(
        id: "regina",
        name: "Bree",
        tagline: "Runs the lunch table",
        artwork: Artwork(imageName: "character-bree", placeholder: [Color(hex: 0xF2A7C3), Color(hex: 0x5A1E3A)])
    )

    static let nia = SceneCharacter(
        id: "cady",
        name: "Nia",
        tagline: "First day, no plan",
        artwork: Artwork(imageName: "character-nia", placeholder: [Color(hex: 0xE8C9A8), Color(hex: 0x4A3324)])
    )

    static let lunchTable = SceneClip(
        id: "get-in-loser",
        title: "Get in, we're going",
        source: SceneSource(title: "The Lunch Table", year: 2026, format: "Dubby Original"),
        synopsis: "It's the new girl's first day. The most feared girl in school pulls up to the curb and makes her an offer she can't refuse.",
        language: "English",
        languageCode: "en",
        duration: 10,
        difficulty: .easy,
        artwork: Artwork(imageName: "scene-lunch-table", placeholder: [Color(hex: 0x3D1A2A), Color(hex: 0xE58FB4)]),
        characters: [bree, nia],
        lines: [
            ScriptLine(id: "g1", characterID: "regina", text: "Get in. We're going to the mall.", translations: ["zh-Hans": "上车。我们去商场。"], start: 0.6, end: 2.6),
            ScriptLine(id: "g2", characterID: "cady", text: "Wait, right now?", translations: ["zh-Hans": "等等，现在就去？"], start: 3.2, end: 4.4),
            ScriptLine(id: "g3", characterID: "regina", text: "On Wednesdays, we never say no.", translations: ["zh-Hans": "每逢星期三，我们从不说不。"], start: 5.0, end: 7.4),
            ScriptLine(id: "g4", characterID: "cady", text: "Okay. I'm in.", translations: ["zh-Hans": "好吧。算我一个。"], start: 8.0, end: 9.4),
        ],
        media: SceneMediaFiles(
            video: "get-in-loser-video.mp4",
            bed: "get-in-loser-bed.m4a",
            stems: ["regina": "get-in-loser-regina.m4a", "cady": "get-in-loser-cady.m4a"]
        ),
        dubCount: 8_100,
        glossary: [
            "get": ["zh-Hans": "得到；get in：上车、进来"],
            "in": ["zh-Hans": "在…里；I'm in：算我一个"],
            "we're": ["zh-Hans": "我们正在（we are 的缩写）"],
            "going": ["zh-Hans": "去（go 的进行时）"],
            "to": ["zh-Hans": "到；去"],
            "the": ["zh-Hans": "这；那（定冠词）"],
            "mall": ["zh-Hans": "商场；购物中心"],
            "wait": ["zh-Hans": "等等"],
            "right": ["zh-Hans": "正好；right now：现在就"],
            "now": ["zh-Hans": "现在"],
            "on": ["zh-Hans": "在（某天）"],
            "wednesdays": ["zh-Hans": "每个星期三"],
            "we": ["zh-Hans": "我们"],
            "never": ["zh-Hans": "从不"],
            "say": ["zh-Hans": "说"],
            "no": ["zh-Hans": "不"],
            "okay": ["zh-Hans": "好的"],
            "i'm": ["zh-Hans": "我是（I am 的缩写）"],
        ]
    )

    static let seojun = SceneCharacter(
        id: "seojun",
        name: "Seo-jun",
        tagline: "Always late, always sorry",
        artwork: Artwork(imageName: "character-seojun", placeholder: [Color(hex: 0x5C8A5A), Color(hex: 0x0D1A12)])
    )

    static let jiwoo = SceneCharacter(
        id: "jiwoo",
        name: "Ji-woo",
        tagline: "Waited in the rain",
        artwork: Artwork(imageName: "character-jiwoo", placeholder: [Color(hex: 0xA9C7B0), Color(hex: 0x1E3326)])
    )

    static let lateAgain = SceneClip(
        id: "late-again",
        title: "Late again",
        source: SceneSource(title: "Rain Check", year: 2026, format: "Dubby Original"),
        synopsis: "Ji-woo has waited an hour at the bus stop. Seo-jun finally runs up, soaked, with an apology he's made before.",
        language: "Korean",
        languageCode: "ko",
        duration: 11,
        difficulty: .medium,
        artwork: Artwork(imageName: "scene-late-again", placeholder: [Color(hex: 0x0D1A12), Color(hex: 0x5C8A5A)]),
        characters: [seojun, jiwoo],
        lines: [
            ScriptLine(id: "k1", characterID: "seojun", text: "괜찮아? 다친 데 없어?", translations: ["zh-Hans": "你没事吧？有没有受伤？", "en": "Are you okay? Are you hurt?"], start: 0.7, end: 2.7),
            ScriptLine(id: "k2", characterID: "jiwoo", text: "왜 이렇게 늦었어?", translations: ["zh-Hans": "你怎么这么晚才来？", "en": "Why are you so late?"], start: 3.3, end: 5.4),
            ScriptLine(id: "k3", characterID: "seojun", text: "미안해. 다시는 안 늦을게.", translations: ["zh-Hans": "对不起。我再也不会迟到了。", "en": "I'm sorry. I won't be late again."], start: 6.2, end: 8.6),
            ScriptLine(id: "k4", characterID: "jiwoo", text: "약속해.", translations: ["zh-Hans": "你保证。", "en": "Promise."], start: 9.0, end: 10.4),
        ],
        media: SceneMediaFiles(
            video: "late-again-video.mp4",
            bed: "late-again-bed.m4a",
            stems: ["seojun": "late-again-seojun.m4a", "jiwoo": "late-again-jiwoo.m4a"]
        ),
        dubCount: 5_300,
        glossary: [
            "괜찮아": ["zh-Hans": "没事吧；还好吗", "en": "are you okay"],
            "다친": ["zh-Hans": "受伤的", "en": "hurt, injured"],
            "데": ["zh-Hans": "地方；之处", "en": "place, spot"],
            "없어": ["zh-Hans": "没有", "en": "there isn't, none"],
            "왜": ["zh-Hans": "为什么", "en": "why"],
            "이렇게": ["zh-Hans": "这么；这样", "en": "so, like this"],
            "늦었어": ["zh-Hans": "迟到了", "en": "(you) were late"],
            "미안해": ["zh-Hans": "对不起", "en": "I'm sorry"],
            "다시는": ["zh-Hans": "再也（不）", "en": "(never) again"],
            "안": ["zh-Hans": "不", "en": "not"],
            "늦을게": ["zh-Hans": "会迟到（我保证…）", "en": "(I) will be late"],
            "약속해": ["zh-Hans": "保证；答应我", "en": "promise"],
        ]
    )

    static let sofia = SceneCharacter(
        id: "sofia",
        name: "Sofía",
        tagline: "Knows that handwriting",
        artwork: Artwork(imageName: "character-sofia", placeholder: [Color(hex: 0xC7923A), Color(hex: 0x2E1D0C)])
    )

    static let mateo = SceneCharacter(
        id: "mateo",
        name: "Mateo",
        tagline: "Shouldn't have opened it",
        artwork: Artwork(imageName: "character-mateo", placeholder: [Color(hex: 0x7A5230), Color(hex: 0x1C1208)])
    )

    static let laCarta = SceneClip(
        id: "la-carta",
        title: "La carta",
        source: SceneSource(title: "Corazón de Fuego", year: 2026, format: "Dubby Original"),
        synopsis: "A letter turns up at Sofía's door, written in a hand she hasn't seen in twenty years. Mateo swears he only found it.",
        language: "Spanish",
        languageCode: "es",
        duration: 10,
        difficulty: .easy,
        artwork: Artwork(imageName: "scene-la-carta", placeholder: [Color(hex: 0x1C1208), Color(hex: 0xC7923A)]),
        characters: [sofia, mateo],
        lines: [
            ScriptLine(id: "c1", characterID: "sofia", text: "¿Quién te dio esta carta?", translations: ["zh-Hans": "谁给你这封信的？", "en": "Who gave you this letter?"], start: 0.6, end: 2.6),
            ScriptLine(id: "c2", characterID: "mateo", text: "Nadie. La encontré en tu puerta.", translations: ["zh-Hans": "没有人。我在你家门口发现的。", "en": "No one. I found it at your door."], start: 3.2, end: 5.2),
            ScriptLine(id: "c3", characterID: "sofia", text: "¡No puede ser!", translations: ["zh-Hans": "不可能！", "en": "It can't be!"], start: 6.0, end: 7.6),
        ],
        media: SceneMediaFiles(
            video: "la-carta-video.mp4",
            bed: "la-carta-bed.m4a",
            stems: ["sofia": "la-carta-sofia.m4a", "mateo": "la-carta-mateo.m4a"]
        ),
        dubCount: 3_900,
        glossary: [
            "quién": ["zh-Hans": "谁", "en": "who"],
            "te": ["zh-Hans": "你（宾格）", "en": "(to) you"],
            "dio": ["zh-Hans": "给了", "en": "gave"],
            "esta": ["zh-Hans": "这个", "en": "this"],
            "carta": ["zh-Hans": "信", "en": "letter"],
            "nadie": ["zh-Hans": "没有人", "en": "no one"],
            "la": ["zh-Hans": "它（宾格）", "en": "it (her)"],
            "encontré": ["zh-Hans": "我找到了", "en": "I found"],
            "en": ["zh-Hans": "在", "en": "at, in"],
            "tu": ["zh-Hans": "你的", "en": "your"],
            "puerta": ["zh-Hans": "门", "en": "door"],
            "no": ["zh-Hans": "不", "en": "not"],
            "puede": ["zh-Hans": "可以；可能", "en": "can"],
            "ser": ["zh-Hans": "是", "en": "be"],
        ]
    )

    static let featured = underestimate
    static let scenes: [SceneClip] = [underestimate, lunchTable, lateAgain, laCarta]

    // MARK: People

    static let me = Friend(id: "me", name: "Erica", handle: "erica", avatar: [Color(hex: 0xFFB547), Color(hex: 0xB0541F)])
    static let maya = Friend(id: "maya", name: "Maya", handle: "maya.dubs", avatar: [Color(hex: 0xA78BFA), Color(hex: 0x5B3FC4)])
    static let jordan = Friend(id: "jordan", name: "Jordan", handle: "jordz", avatar: [Color(hex: 0xFF8A5C), Color(hex: 0xC2311F)])
    static let sam = Friend(id: "sam", name: "Sam", handle: "samspeaks", avatar: [Color(hex: 0x5EC8D8), Color(hex: 0x2A5F86)])
    static let priya = Friend(id: "priya", name: "Priya", handle: "priya.k", avatar: [Color(hex: 0xF27BA8), Color(hex: 0x8E2C5C)])
    static let leo = Friend(id: "leo", name: "Leo", handle: "leo_on_mic", avatar: [Color(hex: 0x7FD49B), Color(hex: 0x2F6B45)])

    // MARK: Social

    static let invites: [CoDubInvite] = [
        CoDubInvite(id: "invite-maya", from: maya, scene: underestimate, theirCharacterID: "obiwan", yourCharacterID: "anakin", sentText: "2m"),
        CoDubInvite(id: "invite-jordan", from: jordan, scene: lateAgain, theirCharacterID: "seojun", yourCharacterID: "jiwoo", sentText: "1h"),
    ]

    static let feed: [FeedPost] = [
        FeedPost(
            id: "post-1",
            scene: underestimate,
            credits: [FeedCredit(author: maya, characterID: "obiwan"), FeedCredit(author: jordan, characterID: "anakin")],
            caption: "the high ground was ours",
            reactions: 2_431,
            comments: 88,
            postedText: "3h"
        ),
        FeedPost(
            id: "post-2",
            scene: lateAgain,
            credits: [FeedCredit(author: priya, characterID: "jiwoo")],
            caption: "first Korean dub!! 약속해",
            reactions: 912,
            comments: 41,
            postedText: "5h"
        ),
        FeedPost(
            id: "post-3",
            scene: laCarta,
            credits: [FeedCredit(author: sam, characterID: "mateo"), FeedCredit(author: leo, characterID: "sofia")],
            caption: "telenovela energy only",
            reactions: 1_207,
            comments: 63,
            postedText: "Yesterday"
        ),
        FeedPost(
            id: "post-4",
            scene: lunchTable,
            credits: [FeedCredit(author: leo, characterID: "regina")],
            caption: "nobody says no to Bree",
            reactions: 640,
            comments: 19,
            postedText: "2d"
        ),
    ]

    static let shelf: [ShelfDub] = [
        ShelfDub(id: "shelf-1", scene: underestimate, characterID: "anakin", collaborator: maya, visibility: .publicFeed, progress: .finished(timingScore: 88), dateText: "Today", videoURL: nil),
        ShelfDub(id: "shelf-2", scene: lateAgain, characterID: "seojun", collaborator: nil, visibility: .privateShelf, progress: .finished(timingScore: 81), dateText: "Yesterday", videoURL: nil),
        ShelfDub(id: "shelf-3", scene: laCarta, characterID: "sofia", collaborator: nil, visibility: .privateShelf, progress: .draft(completedLines: 1, totalLines: 2), dateText: "Mon", videoURL: nil),
        ShelfDub(id: "shelf-4", scene: lunchTable, characterID: "cady", collaborator: leo, visibility: .publicFeed, progress: .finished(timingScore: 92), dateText: "Last week", videoURL: nil),
        ShelfDub(id: "shelf-5", scene: underestimate, characterID: "obiwan", collaborator: nil, visibility: .publicFeed, progress: .finished(timingScore: 76), dateText: "Last week", videoURL: nil),
    ]

    static let conversations: [Conversation] = [
        Conversation(
            id: "maya",
            friend: maya,
            messages: [
                ChatMessage(id: 1, sender: .friend, content: .text("Just finished Obi-Wan's lines")),
                ChatMessage(id: 2, sender: .friend, content: .invite(invites[0])),
                ChatMessage(id: 3, sender: .me, content: .text("ok give me 5 min")),
                ChatMessage(id: 4, sender: .friend, content: .text("Timing score or it didn't happen")),
            ],
            lastActivity: "2m",
            unreadCount: 2
        ),
        Conversation(
            id: "jordan",
            friend: jordan,
            messages: [
                ChatMessage(id: 1, sender: .friend, content: .invite(invites[1])),
            ],
            lastActivity: "1h",
            unreadCount: 1
        ),
        Conversation(
            id: "sam",
            friend: sam,
            messages: [
                ChatMessage(id: 1, sender: .me, content: .text("that timing on line 3 was rough lol")),
                ChatMessage(id: 2, sender: .friend, content: .text("the hologram roasted me too")),
            ],
            lastActivity: "Yesterday",
            unreadCount: 0
        ),
    ]

    static let streakDays = 3
}
