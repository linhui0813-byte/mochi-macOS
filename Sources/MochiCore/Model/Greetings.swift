import Foundation
import MochiKernel

/// What a companion says to open a voice conversation, in every language a conversation can be held in.
///
/// Each line names the companion once, as `{name}`, and must read correctly whatever that name is and whoever is
/// listening. So no line uses grammar that changes with the sound of the name (Korean 이에요/예요, Turkish case
/// endings), and none uses gendered forms for the companion or the listener (Spanish "encantada", Russian "рада",
/// Hindi "रही हूँ", Thai ค่ะ/ครับ, Arabic gendered "you").
public enum Greetings {
    /// How Chinese is written; the language a conversation is held in does not say.
    public enum ChineseScript: Sendable { case simplified, traditional }

    /// Six lines for `language`. `match` has no language of its own; resolve it with `spoken(_:interface:)` first.
    public static func patterns(_ language: ConversationLanguage, script: ChineseScript = .simplified) -> [String] {
        switch language {
        case .match, .english: return english
        case .chinese: return script == .traditional ? traditionalChinese : simplifiedChinese
        case .japanese: return japanese
        case .korean: return korean
        case .spanish: return spanish
        case .french: return french
        case .german: return german
        case .italian: return italian
        case .portuguese: return portuguese
        case .dutch: return dutch
        case .russian: return russian
        case .polish: return polish
        case .turkish: return turkish
        case .arabic: return arabic
        case .hindi: return hindi
        case .vietnamese: return vietnamese
        case .thai: return thai
        case .indonesian: return indonesian
        }
    }

    /// The language and script a greeting is spoken in. A conversation that follows the user's language has not
    /// heard the user yet, so it greets in the language of Mochi's interface, which the user chose for their Mac.
    /// `interface` is a localization such as "en", "zh-Hans" or "zh-Hant".
    public static func spoken(_ language: ConversationLanguage, interface: String) -> (
        language: ConversationLanguage, script: ChineseScript
    ) {
        let script: ChineseScript = interface.hasPrefix("zh-Hant") ? .traditional : .simplified
        guard language == .match else { return (language, script) }
        let code = String(interface.prefix { $0 != "-" && $0 != "_" })
        let interfaceLanguage = ConversationLanguage(rawValue: code) ?? .english
        return (interfaceLanguage == .match ? .english : interfaceLanguage, script)
    }

    static let english = [
        "Hi, {name} here. What's on your mind?",
        "Hey, it's {name}. How's your day going?",
        "Hi, I'm {name}. What shall we talk about?",
        "{name} here. Take your time. I'm listening.",
        "Hey there, {name} here. Where shall we start?",
        "Hi, it's {name}. What would you like to talk about?",
    ]
    static let simplifiedChinese = [
        "嗨，我是{name}。你在想什么呢？",
        "你好，我是{name}。今天过得怎么样？",
        "嗨，我是{name}。我们聊点什么？",
        "我是{name}。慢慢来，我在听。",
        "你好呀，我是{name}。从哪儿开始聊？",
        "嗨，我是{name}。你想聊些什么？",
    ]
    static let traditionalChinese = [
        "嗨，我是{name}。你在想什麼呢？",
        "你好，我是{name}。今天過得怎麼樣？",
        "嗨，我是{name}。我們聊點什麼？",
        "我是{name}。慢慢來，我在聽。",
        "你好呀，我是{name}。從哪裡開始聊？",
        "嗨，我是{name}。你想聊些什麼？",
    ]
    static let japanese = [
        "こんにちは、{name}です。何を考えていますか？",
        "やあ、{name}です。今日はどんな一日でしたか？",
        "こんにちは、{name}です。何について話しましょうか？",
        "{name}です。ゆっくりでいいですよ。聞いています。",
        "こんにちは、{name}です。どこから始めましょうか？",
        "やあ、{name}です。何を話したいですか？",
    ]
    static let korean = [
        "안녕하세요, {name}입니다. 무슨 생각을 하고 계세요?",
        "안녕하세요, {name}입니다. 오늘 하루 어떠셨어요?",
        "안녕하세요, {name}입니다. 무슨 이야기를 할까요?",
        "{name}입니다. 천천히 하세요. 듣고 있어요.",
        "반가워요, {name}입니다. 어디서부터 시작할까요?",
        "안녕하세요, {name}입니다. 어떤 이야기를 하고 싶으세요?",
    ]
    static let spanish = [
        "Hola, soy {name}. ¿Qué tienes en mente?",
        "Hola, aquí {name}. ¿Qué tal tu día?",
        "Hola, soy {name}. ¿De qué hablamos?",
        "Aquí {name}. Tómate tu tiempo, te escucho.",
        "¡Hola! Soy {name}. ¿Por dónde empezamos?",
        "Hola, soy {name}. ¿De qué te gustaría hablar?",
    ]
    static let french = [
        "Salut, c'est {name}. À quoi penses-tu ?",
        "Bonjour, ici {name}. Comment se passe ta journée ?",
        "Salut, c'est {name}. De quoi parlons-nous ?",
        "Ici {name}. Prends ton temps, je t'écoute.",
        "Bonjour, c'est {name}. Par où commençons-nous ?",
        "Salut, c'est {name}. De quoi aimerais-tu parler ?",
    ]
    static let german = [
        "Hallo, hier ist {name}. Was beschäftigt dich?",
        "Hey, hier ist {name}. Wie läuft dein Tag?",
        "Hallo, ich bin {name}. Worüber wollen wir reden?",
        "Hier ist {name}. Lass dir Zeit, ich höre zu.",
        "Hey, hier ist {name}. Womit fangen wir an?",
        "Hallo, hier ist {name}. Worüber möchtest du sprechen?",
    ]
    static let italian = [
        "Ciao, sono {name}. A cosa stai pensando?",
        "Ciao, qui {name}. Come va la giornata?",
        "Ciao, sono {name}. Di cosa parliamo?",
        "Qui {name}. Prenditi il tuo tempo, ti ascolto.",
        "Ehi, sono {name}. Da dove cominciamo?",
        "Ciao, sono {name}. Di cosa ti va di parlare?",
    ]
    static let portuguese = [
        "Oi, aqui é {name}. No que você está pensando?",
        "Olá, aqui é {name}. Como está o seu dia?",
        "Oi, eu sou {name}. Sobre o que vamos conversar?",
        "Aqui é {name}. Sem pressa, estou ouvindo.",
        "Olá, aqui é {name}. Por onde começamos?",
        "Oi, aqui é {name}. Sobre o que você quer conversar?",
    ]
    static let dutch = [
        "Hoi, met {name}. Waar denk je aan?",
        "Hallo, met {name}. Hoe gaat je dag?",
        "Hoi, ik ben {name}. Waar zullen we over praten?",
        "Met {name}. Neem je tijd, ik luister.",
        "Hallo, met {name}. Waar beginnen we?",
        "Hoi, met {name}. Waar wil je het over hebben?",
    ]
    static let russian = [
        "Привет, это {name}. О чём думаешь?",
        "Здравствуй, это {name}. Как проходит твой день?",
        "Привет, я {name}. О чём поговорим?",
        "Это {name}. Не торопись, я слушаю.",
        "Привет, это {name}. С чего начнём?",
        "Привет, это {name}. О чём хочешь поговорить?",
    ]
    static let polish = [
        "Cześć, tu {name}. O czym myślisz?",
        "Hej, tu {name}. Jak mija ci dzień?",
        "Cześć, tu {name}. O czym porozmawiamy?",
        "Tu {name}. Nie spiesz się, słucham.",
        "Hej, tu {name}. Od czego zaczniemy?",
        "Cześć, tu {name}. O czym chcesz porozmawiać?",
    ]
    static let turkish = [
        "Merhaba, ben {name}. Aklında ne var?",
        "Selam, ben {name}. Günün nasıl geçiyor?",
        "Merhaba, ben {name}. Ne hakkında konuşalım?",
        "Ben {name}. Acele etme, dinliyorum.",
        "Selam, ben {name}. Nereden başlayalım?",
        "Merhaba, ben {name}. Ne konuşmak istersin?",
    ]
    static let arabic = [
        "مرحبًا، أنا {name}. عمّ نتحدث اليوم؟",
        "أهلًا، أنا {name}. من أين نبدأ؟",
        "مرحبًا، معكم {name}. بماذا نبدأ حديثنا؟",
        "أنا {name}. لا داعي للعجلة، أنا أستمع.",
        "أهلًا، أنا {name}. ما الذي نتحدث عنه؟",
        "مرحبًا، أنا {name}. يسعدني أن نتحدث. بماذا نبدأ؟",
    ]
    static let hindi = [
        "नमस्ते, मैं {name} हूँ। आपके मन में क्या है?",
        "हैलो, मैं {name} हूँ। आपका दिन कैसा जा रहा है?",
        "नमस्ते, मैं {name} हूँ। हम किस बारे में बात करें?",
        "मैं {name} हूँ। आराम से बोलिए, कोई जल्दी नहीं।",
        "हैलो, मैं {name} हूँ। कहाँ से शुरू करें?",
        "नमस्ते, मैं {name} हूँ। आज किस विषय पर बात करें?",
    ]
    static let vietnamese = [
        "Chào bạn, mình là {name}. Bạn đang nghĩ gì vậy?",
        "Xin chào, mình là {name}. Hôm nay của bạn thế nào?",
        "Chào bạn, mình là {name}. Mình nói chuyện gì nhé?",
        "Mình là {name} đây. Cứ từ từ, mình đang nghe.",
        "Xin chào, mình là {name}. Bắt đầu từ đâu nhỉ?",
        "Chào bạn, mình là {name}. Bạn muốn nói về chuyện gì?",
    ]
    static let thai = [
        "สวัสดี {name} เองนะ กำลังคิดอะไรอยู่",
        "สวัสดี นี่ {name} นะ วันนี้เป็นยังไงบ้าง",
        "สวัสดี {name} เองนะ เราคุยเรื่องอะไรกันดี",
        "{name} อยู่ตรงนี้นะ ค่อยๆ คิดได้เลย กำลังฟังอยู่",
        "สวัสดี นี่ {name} นะ เริ่มจากตรงไหนดี",
        "สวัสดี {name} เองนะ อยากคุยเรื่องอะไร",
    ]
    static let indonesian = [
        "Hai, aku {name}. Lagi mikirin apa?",
        "Halo, ini {name}. Bagaimana harimu?",
        "Hai, aku {name}. Mau ngobrol tentang apa?",
        "Ini {name}. Pelan-pelan saja, aku mendengarkan.",
        "Halo, aku {name}. Kita mulai dari mana?",
        "Hai, ini {name}. Kamu ingin membicarakan apa?",
    ]
}
