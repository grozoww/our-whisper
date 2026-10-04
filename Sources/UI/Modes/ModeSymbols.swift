import AppKit
import Foundation

/// One symbol the mode editor offers: its SF Symbols name, where it sits in the grid, and the words
/// a person might type to find it.
struct ModeSymbol: Identifiable, Equatable, Sendable {
    let name: String
    let category: Category
    /// English, Russian and Ukrainian mixed in one list. A search does not ask which language it
    /// is in — the owner and most of this app's users type Cyrillic, and a symbol that can only be
    /// found by its English name is a symbol they will never find.
    let keywords: [String]
    /// What a search compares against: the keywords plus the pieces of the name, folded the same
    /// way the query is. Built once here, because the picker filters on every keystroke.
    fileprivate let searchWords: [String]

    var id: String { name }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case writing
        case messaging
        case code
        case work
        case everyday
        case fun

        var id: String { rawValue }

        var title: String {
            switch self {
            case .writing: "Writing"
            case .messaging: "Messaging"
            case .code: "Code"
            case .work: "Work"
            case .everyday: "Everyday"
            case .fun: "Fun"
            }
        }
    }

    /// `keywords` is one string of words separated by spaces, which keeps a hundred and thirty
    /// entries readable as a table instead of a wall of brackets.
    fileprivate init(_ name: String, _ category: Category, _ keywords: String) {
        self.name = name
        self.category = category
        let words = keywords.split(separator: " ").map(String.init)
        self.keywords = words
        self.searchWords = (words + name.split(separator: ".").map(String.init)).map(ModeSymbols.folded)
    }
}

/// The symbols a mode can wear, written out by hand.
///
/// There is no public API that lists SF Symbols. Apple's own search data sits in
/// `CoreGlyphs.bundle` on every Mac — 3,189 entries — but it is a private file whose location and
/// format may change in any OS update, and a picker built on it would quietly come up empty. This
/// list was picked from that file *once*, at development time, and then lives here where it can be
/// reviewed and cannot change under us.
///
/// Every name must exist on the oldest macOS the app runs on (15, SF Symbols 6). A symbol the OS
/// does not have draws as an empty square, so `ModeSymbolsTests` asks the running system to
/// resolve each one — and a name added in SF Symbols 7 passes on a Mac 26 and fails on a Mac 15,
/// which is why the names below were also checked against the symbol availability table for the
/// year they first shipped.
///
/// The stored value stays the plain name string in `Mode.symbol`. Nothing about a mode's file
/// changes, and a name that is not in this list — a hand-edited file, an older version — still
/// works; the picker shows it as the current choice.
enum ModeSymbols {
    /// What the picker draws for a name the system has no symbol for, so a typo in a hand-edited
    /// file shows as a visible "something is wrong here" and not as an empty tile.
    static let placeholder = "questionmark.square.dashed"

    static func symbols(in category: ModeSymbol.Category) -> [ModeSymbol] {
        all.filter { $0.category == category }
    }

    static func symbol(named name: String) -> ModeSymbol? {
        all.first { $0.name == name }
    }

    static func resolves(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The symbols a query finds, best first. Every word typed has to match the *start* of some
    /// word the symbol carries, so "поч" finds "почта" and "env" finds the envelope. A whole-word
    /// match outranks a prefix, and ties keep the catalogue's own order, which is the order of the
    /// grid — the result list does not reshuffle as someone types.
    ///
    /// An empty query finds everything.
    static func search(_ query: String) -> [ModeSymbol] {
        let tokens = folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return all }

        var scored: [(symbol: ModeSymbol, score: Int, order: Int)] = []
        for (order, symbol) in all.enumerated() {
            var score = 0
            var matchedAll = true
            for token in tokens {
                var best = 0
                for word in symbol.searchWords {
                    if word == token {
                        best = 2
                        break
                    }
                    if word.hasPrefix(token) { best = 1 }
                }
                if best == 0 {
                    matchedAll = false
                    break
                }
                score += best
            }
            if matchedAll { scored.append((symbol, score, order)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .map(\.symbol)
    }

    /// Lowercased and stripped of accents, on both sides of the comparison. `й` and `ё` fold to
    /// `и` and `е` and `ї` to `і`, which loses a distinction nobody searching for an icon is
    /// making, and it means a query typed without them still finds the word.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - The catalogue

    static let all: [ModeSymbol] = [
        // Writing
        ModeSymbol("sparkles", .writing, "magic new ai shine default sparkle магия блеск искра ии магія іскра"),
        ModeSymbol("pencil", .writing, "pencil write edit draw карандаш писать править олівець писати"),
        ModeSymbol("square.and.pencil", .writing, "compose write edit new note написать заметка править нотатка"),
        ModeSymbol("doc.text", .writing, "document text file page документ текст файл сторінка"),
        ModeSymbol("note.text", .writing, "note memo text записка заметка нотатка"),
        ModeSymbol("textformat", .writing, "font type text format шрифт текст формат"),
        ModeSymbol("character.book.closed", .writing, "dictionary language words glossary словарь язык слова глосарій мова"),
        ModeSymbol("book", .writing, "book read story книга читать история читати"),
        ModeSymbol("books.vertical", .writing, "books library study shelf книги библиотека полка бібліотека"),
        ModeSymbol("bookmark", .writing, "bookmark save saved закладка сохранить збережене"),
        ModeSymbol("text.quote", .writing, "quote quotation citation цитата кавычки лапки"),
        ModeSymbol("list.bullet", .writing, "list bullets points items список пункты перелік"),
        ModeSymbol("list.number", .writing, "numbered list steps order нумерованный шаги порядок кроки"),
        ModeSymbol("checklist", .writing, "checklist tasks todo done задачи дела чеклист справи"),
        ModeSymbol("signature", .writing, "signature sign autograph подпись автограф підпис"),
        ModeSymbol("highlighter", .writing, "highlight marker emphasis маркер выделить виділити"),
        ModeSymbol("newspaper", .writing, "news article press newspaper новости статья газета новини стаття"),
        ModeSymbol("text.badge.checkmark", .writing, "proofread grammar correct spelling проверка грамматика исправить перевірка"),
        ModeSymbol("translate", .writing, "translate translation language перевод переводчик язык переклад"),

        // Messaging
        ModeSymbol("text.bubble", .messaging, "chat message talk speech general чат сообщение разговор повідомлення"),
        ModeSymbol("bubble.left", .messaging, "message comment bubble сообщение комментарий коментар"),
        ModeSymbol("bubble.left.and.bubble.right", .messaging, "conversation dialog chat discussion разговор диалог обсуждение діалог"),
        ModeSymbol("ellipsis.bubble", .messaging, "typing chat pending more печатает ожидание друкує"),
        ModeSymbol("envelope", .messaging, "mail email letter message inbox почта письмо пошта лист"),
        ModeSymbol("paperplane", .messaging, "send plane deliver submit отправить самолётик надіслати"),
        ModeSymbol("tray", .messaging, "inbox tray incoming входящие ящик вхідні"),
        ModeSymbol("arrowshape.turn.up.left", .messaging, "reply respond answer ответ ответить відповідь"),
        ModeSymbol("arrowshape.turn.up.right", .messaging, "forward share send переслать поделиться переслати"),
        ModeSymbol("at", .messaging, "at mention handle address упоминание собака адрес згадка"),
        ModeSymbol("phone", .messaging, "phone call telephone mobile телефон звонок трубка дзвінок"),
        ModeSymbol("video", .messaging, "video call camera meeting видео звонок камера встреча відео"),
        ModeSymbol("megaphone", .messaging, "announce announcement broadcast shout объявление рупор оголошення"),
        ModeSymbol("bell", .messaging, "bell notification alert reminder уведомление колокольчик напоминание сповіщення"),
        ModeSymbol("hand.wave", .messaging, "hello hi greeting wave привет приветствие махать привіт"),
        ModeSymbol("heart", .messaging, "heart love like favourite сердце любовь нравится серце любов"),
        ModeSymbol("face.smiling", .messaging, "smile emoji happy friendly смайл эмодзи улыбка весёлый усмішка"),
        ModeSymbol("person.2", .messaging, "people friends contacts two люди друзья контакты двое друзі"),
        ModeSymbol("mic", .messaging, "microphone voice speak record микрофон голос запись мікрофон"),
        ModeSymbol("waveform", .messaging, "sound audio wave voice звук аудио волна голос"),

        // Code
        ModeSymbol("chevron.left.forwardslash.chevron.right", .code, "code programming html developer код программирование разработка програмування"),
        ModeSymbol("terminal", .code, "terminal console shell command line терминал консоль командная строка"),
        ModeSymbol("curlybraces", .code, "braces json code object скобки фигурные"),
        ModeSymbol("ladybug", .code, "bug debug error issue баг ошибка отладка помилка"),
        ModeSymbol("hammer", .code, "build tool compile make сборка молоток собрать збірка"),
        ModeSymbol("wrench.and.screwdriver", .code, "tools repair fix settings инструменты ремонт настройка інструменти"),
        ModeSymbol("gearshape", .code, "settings gear preferences config настройки шестерёнка конфиг налаштування"),
        ModeSymbol("cpu", .code, "cpu processor chip hardware процессор чип железо процесор"),
        ModeSymbol("server.rack", .code, "server rack hosting infrastructure сервер стойка хостинг инфраструктура"),
        ModeSymbol("network", .code, "network connection graph сеть соединение мережа"),
        ModeSymbol("cloud", .code, "cloud storage online облако хранилище хмара"),
        ModeSymbol("arrow.triangle.branch", .code, "branch git version fork ветка гит версия розгалуження"),
        ModeSymbol("arrow.triangle.merge", .code, "merge git pull request слияние гит мерж злиття"),
        ModeSymbol("number", .code, "number hash count digits число решётка хеш цифры"),
        ModeSymbol("function", .code, "function math formula функция формула математика"),
        ModeSymbol("lock", .code, "lock secure private password security замок безопасность приватный пароль безпека"),
        ModeSymbol("key", .code, "key password access ключ пароль доступ"),
        ModeSymbol("shield", .code, "shield protect security safe защита щит безопасность захист"),
        ModeSymbol("checkmark.seal", .code, "verified approved seal certified проверено одобрено печать перевірено"),
        ModeSymbol("shippingbox", .code, "package box deploy release shipping пакет коробка релиз посылка пакунок"),
        ModeSymbol("square.stack.3d.up", .code, "layers stack levels слои стек уровни шари"),
        ModeSymbol("testtube.2", .code, "test lab experiment тест лаборатория эксперимент лабораторія"),

        // Work
        ModeSymbol("briefcase", .work, "work job business portfolio работа бизнес портфель робота"),
        ModeSymbol("building.2", .work, "office company building city офис компания здание город будівля"),
        ModeSymbol("calendar", .work, "calendar date schedule event календарь дата расписание событие розклад подія"),
        ModeSymbol("clock", .work, "clock time hour часы время годинник час"),
        ModeSymbol("timer", .work, "timer stopwatch countdown таймер секундомер отсчёт"),
        ModeSymbol("chart.bar", .work, "chart bars statistics report график статистика отчёт діаграма звіт"),
        ModeSymbol("chart.line.uptrend.xyaxis", .work, "growth trend analytics sales рост тренд аналитика продажи зростання"),
        ModeSymbol("tablecells", .work, "table spreadsheet grid cells таблица электронная сетка ячейки"),
        ModeSymbol("folder", .work, "folder files directory папка файлы каталог тека"),
        ModeSymbol("archivebox", .work, "archive box storage архив коробка архів"),
        ModeSymbol("paperclip", .work, "attachment attach clip file вложение скрепка прикрепить вкладення"),
        ModeSymbol("doc.on.clipboard", .work, "clipboard paste copy буфер обмена вставить копировать"),
        ModeSymbol("doc.on.doc", .work, "copy duplicate documents копия дубликат копіювати"),
        ModeSymbol("person", .work, "person user profile contact человек пользователь профиль людина"),
        ModeSymbol("person.3", .work, "team group people crowd команда группа люди колектив"),
        ModeSymbol("target", .work, "target goal aim focus цель мишень фокус ціль"),
        ModeSymbol("flag", .work, "flag mark goal priority флаг метка приоритет прапор"),
        ModeSymbol("star", .work, "star favourite rating important звезда избранное рейтинг важное зірка"),
        ModeSymbol("pin", .work, "pin pinned attach important закрепить булавка важное закріпити"),
        ModeSymbol("tag", .work, "tag label price category тег метка ярлык ценник мітка"),
        ModeSymbol("creditcard", .work, "card payment bank pay карта оплата банк платёж картка"),
        ModeSymbol("banknote", .work, "money cash bills finance деньги наличные финансы гроші готівка"),
        ModeSymbol("cart", .work, "cart shop buy shopping store корзина магазин покупки кошик"),
        ModeSymbol("lightbulb", .work, "idea light bulb tip brainstorm идея лампочка совет мысль ідея"),
        ModeSymbol("graduationcap", .work, "education learning school student study университет учёба обучение школа навчання"),
        ModeSymbol("magnifyingglass", .work, "search find look zoom поиск найти лупа пошук"),
        ModeSymbol("doc.text.magnifyingglass", .work, "review inspect research audit проверка обзор исследование аудит перевірка"),

        // Everyday
        ModeSymbol("house", .everyday, "home house family дом семья будинок"),
        ModeSymbol("building.columns", .everyday, "bank museum government institution банк музей государство установа"),
        ModeSymbol("map", .everyday, "map plan route карта маршрут"),
        ModeSymbol("mappin.and.ellipse", .everyday, "location place address pin место адрес локация місце"),
        ModeSymbol("globe", .everyday, "globe world internet web language мир интернет сайт глобус світ"),
        ModeSymbol("airplane", .everyday, "airplane flight travel trip plane самолёт перелёт путешествие поездка літак подорож"),
        ModeSymbol("car", .everyday, "car drive auto transport машина авто водить автомобіль"),
        ModeSymbol("bicycle", .everyday, "bike bicycle cycling велосипед спорт"),
        ModeSymbol("figure.walk", .everyday, "walk walking hike pedestrian ходьба прогулка пешком прогулянка"),
        ModeSymbol("leaf", .everyday, "leaf plant nature eco green лист растение природа эко рослина"),
        ModeSymbol("tree", .everyday, "tree forest nature дерево лес природа ліс"),
        ModeSymbol("sun.max", .everyday, "sun day bright light солнце день яркий сонце"),
        ModeSymbol("moon", .everyday, "moon night sleep dark луна ночь сон месяц місяць ніч"),
        ModeSymbol("cloud.rain", .everyday, "rain weather cloud дождь погода тучи дощ"),
        ModeSymbol("flame", .everyday, "fire hot flame trending огонь пламя горячее вогонь"),
        ModeSymbol("drop", .everyday, "water drop liquid rain вода капля жидкость крапля"),
        ModeSymbol("bolt", .everyday, "lightning power energy fast electric молния энергия быстро электричество блискавка"),
        ModeSymbol("pawprint", .everyday, "paw pet animal dog cat лапа питомец животное собака кошка тварина"),
        ModeSymbol("fork.knife", .everyday, "food eat restaurant meal еда ресторан обед вилка їжа"),
        ModeSymbol("cup.and.saucer", .everyday, "coffee tea cup drink кофе чай чашка напиток кава"),
        ModeSymbol("gift", .everyday, "gift present birthday подарок праздник подарунок"),
        ModeSymbol("stethoscope", .everyday, "doctor health medical врач здоровье медицина лікар"),
        ModeSymbol("pills", .everyday, "pills medicine health drugs таблетки лекарства здоровье ліки"),
        ModeSymbol("dumbbell", .everyday, "gym fitness workout sport спорт зал тренировка фитнес тренування"),
        ModeSymbol("bed.double", .everyday, "bed sleep rest hotel кровать сон отдых отель ліжко"),

        // Fun
        ModeSymbol("gamecontroller", .fun, "game controller gaming play игра геймпад игры гра"),
        ModeSymbol("music.note", .fun, "music note song audio музыка нота песня музика пісня"),
        ModeSymbol("headphones", .fun, "headphones listen audio podcast наушники слушать подкаст навушники"),
        ModeSymbol("theatermasks", .fun, "theatre masks drama comedy театр маски драма комедия"),
        ModeSymbol("film", .fun, "film movie cinema video кино фильм видео кіно"),
        ModeSymbol("camera", .fun, "camera photo picture снимок камера фото фотоаппарат"),
        ModeSymbol("photo", .fun, "photo picture image gallery картинка фото изображение галерея зображення"),
        ModeSymbol("paintbrush", .fun, "brush paint art draw кисть рисовать искусство малювати"),
        ModeSymbol("paintpalette", .fun, "palette colors art design палитра цвета дизайн палітра"),
        ModeSymbol("party.popper", .fun, "party celebrate confetti congratulations праздник вечеринка поздравление хлопушка свято"),
        ModeSymbol("trophy", .fun, "trophy win award champion кубок победа награда чемпион перемога"),
        ModeSymbol("crown", .fun, "crown king queen royal корона король королева"),
        ModeSymbol("wand.and.stars", .fun, "wand magic wizard fantasy палочка волшебство магия фея чарівна"),
        ModeSymbol("brain", .fun, "brain think mind smart мозг мышление ум розум"),
        ModeSymbol("eye", .fun, "eye look view watch глаз смотреть видеть наблюдать око"),
        ModeSymbol("hand.thumbsup", .fun, "like thumbs up approve good класс лайк одобрить хорошо"),
        ModeSymbol("hands.clap", .fun, "applause clap bravo congrats аплодисменты хлопать браво оплески"),
        ModeSymbol("dice", .fun, "dice random luck game кубики случайность удача игра кубик"),
        ModeSymbol("puzzlepiece", .fun, "puzzle piece plugin extension пазл деталь плагин расширение"),
        ModeSymbol("tv", .fun, "tv television screen show телевизор экран шоу телевізор"),
        ModeSymbol("sunglasses", .fun, "sunglasses cool summer очки крутой лето окуляри"),
        ModeSymbol("moon.stars", .fun, "night stars sleep dream ночь звезды сон зірки"),
    ]
}
