#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Собирает docx с вопросами пользователя и ответами из чата по проекту Y-Node."""

from docx import Document
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

OUT = r"Z:\BACKUP\Y-Node\Y-Node-вопросы-и-ответы.docx"

INK = RGBColor(0x1B, 0x1F, 0x24)
ACCENT = RGBColor(0x0F, 0x6E, 0x62)
MUTED = RGBColor(0x5A, 0x63, 0x6B)
CODE_BG = "F1F3F4"


def _set_font(style, name, size, bold=None, color=None):
    style.font.name = name
    style.font.size = Pt(size)
    if bold is not None:
        style.font.bold = bold
    if color is not None:
        style.font.color.rgb = color
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    for attr in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        rfonts.set(qn(attr), name)


def _shade(paragraph, fill):
    ppr = paragraph._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    ppr.append(shd)


def _border(paragraph, color="D5DADF"):
    ppr = paragraph._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    for side in ("top", "left", "bottom", "right"):
        edge = OxmlElement(f"w:{side}")
        edge.set(qn("w:val"), "single")
        edge.set(qn("w:sz"), "4")
        edge.set(qn("w:space"), "4")
        edge.set(qn("w:color"), color)
        borders.append(edge)
    ppr.append(borders)


def _page_number(paragraph):
    run = paragraph.add_run()
    fld = OxmlElement("w:fldSimple")
    fld.set(qn("w:instr"), "PAGE")
    run._r.addnext(fld)


def build_document():
    doc = Document()

    section = doc.sections[0]
    section.page_width = Cm(21.0)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.0)
    section.bottom_margin = Cm(2.0)
    section.left_margin = Cm(2.2)
    section.right_margin = Cm(2.2)

    normal = doc.styles["Normal"]
    _set_font(normal, "Calibri", 10.5, color=INK)
    normal.paragraph_format.space_after = Pt(6)
    normal.paragraph_format.line_spacing = 1.15

    for name, size, before, after in (
        ("Heading 1", 18, 20, 8),
        ("Heading 2", 13, 14, 4),
    ):
        style = doc.styles[name]
        _set_font(style, "Calibri", size, bold=True, color=ACCENT)
        style.paragraph_format.space_before = Pt(before)
        style.paragraph_format.space_after = Pt(after)
        style.paragraph_format.keep_with_next = True

    question = doc.styles.add_style("Question", WD_STYLE_TYPE.PARAGRAPH)
    question.base_style = doc.styles["Normal"]
    _set_font(question, "Calibri", 11, bold=True, color=INK)
    question.paragraph_format.space_before = Pt(12)
    question.paragraph_format.space_after = Pt(3)
    question.paragraph_format.keep_with_next = True

    answer = doc.styles.add_style("Answer", WD_STYLE_TYPE.PARAGRAPH)
    answer.base_style = doc.styles["Normal"]
    answer.paragraph_format.space_after = Pt(6)
    answer.paragraph_format.left_indent = Cm(0.5)

    code = doc.styles.add_style("CodeBlock", WD_STYLE_TYPE.PARAGRAPH)
    code.base_style = doc.styles["Normal"]
    _set_font(code, "Consolas", 9, color=RGBColor(0x24, 0x29, 0x2E))
    code.paragraph_format.left_indent = Cm(0.5)
    code.paragraph_format.space_before = Pt(3)
    code.paragraph_format.space_after = Pt(8)
    code.paragraph_format.line_spacing = 1.0

    footer = section.footer.paragraphs[0]
    footer.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = footer.add_run("Y-Node · вопросы и ответы · стр. ")
    run.font.size = Pt(8)
    run.font.color.rgb = MUTED
    _page_number(footer)

    props = doc.core_properties
    props.title = "Y-Node — вопросы и ответы"
    props.subject = "Сводка переписки по проекту Y-Node"
    props.author = "Koda"
    return doc


def h1(doc, text):
    doc.add_heading(text, level=1)


def h2(doc, text):
    doc.add_heading(text, level=2)


_question_no = 0


def q(doc, number, text):
    """Adds a question. The printed number is sequential; `number` is kept in
    the source only as a reading aid and is not used."""
    global _question_no
    _question_no += 1
    p = doc.add_paragraph(style="Question")
    p.add_run(f"{_question_no}. ").font.color.rgb = ACCENT
    p.add_run(text)
    return p


def a(doc, text):
    p = doc.add_paragraph(style="Answer")
    p.add_run(text)
    return p


def bullets(doc, items, numbered=False):
    style = "List Number" if numbered else "List Bullet"
    for item in items:
        p = doc.add_paragraph(item, style=style)
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.left_indent = Cm(0.9)


def code(doc, text):
    text = text.replace(chr(92) + "n", chr(10))
    # A literal "\n" typed in the source is a line break in the document.
    text = text.replace("\n", "\n")
    for line in text.strip("\n").split("\n"):
        p = doc.add_paragraph(style="CodeBlock")
        p.add_run(line if line else " ")
        _shade(p, CODE_BG)
        _border(p)


def note(doc, text):
    p = doc.add_paragraph(style="Answer")
    p.paragraph_format.right_indent = Cm(0.3)
    run = p.add_run(text)
    run.italic = True
    run.font.color.rgb = MUTED
    _shade(p, "F7F9FA")
    _border(p)
    return p


def title_block(doc):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(70)
    p.paragraph_format.space_after = Pt(0)
    run = p.add_run("Y-Node")
    run.font.size = Pt(42)
    run.font.bold = True
    run.font.color.rgb = ACCENT

    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(18)
    run = p.add_run("Вопросы и ответы по проекту")
    run.font.size = Pt(20)
    run.font.color.rgb = INK

    table = doc.add_table(rows=4, cols=2)
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.LEFT
    table.columns[0].width = Cm(4.2)
    table.columns[1].width = Cm(12.0)
    rows = [
        ("Проект", "Y-Node — Android-клиент сети Yggdrasil"),
        ("Каталог", r"d:\VCS\Y-Node"),
        ("Сборки", r"Z:\BACKUP\Y-Node"),
        ("Дата сводки", "29 октября 2026 г."),
    ]
    for index, (key, value) in enumerate(rows):
        cells = table.rows[index].cells
        cells[0].width = Cm(4.2)
        cells[1].width = Cm(12.0)
        first = cells[0].paragraphs[0]
        run = first.add_run(key)
        run.font.bold = True
        run.font.size = Pt(9.5)
        run.font.color.rgb = MUTED
        second = cells[1].paragraphs[0]
        run = second.add_run(value)
        run.font.size = Pt(9.5)
        _shade(first, "F7F9FA")

    doc.add_paragraph()
    note(
        doc,
        "Документ собран из переписки по проекту: вопросы и запросы "
        "пользователя приведены в исходной формулировке или близко к ней, "
        "ответы описывают принятое решение и то, что реально сделано в коде "
        "и на сервере. Порядок — тематический, внутри темы — хронологический.",
    )

    h2(doc, "Содержание")
    bullets(
        doc,
        [
            "Постановка задачи и архитектура",
            "Интерфейс, измерения и настройки",
            "Оформление, тексты и предустановки",
            "Exit-node: профили, пиры и прямая связь",
            "Серверная часть и эксплуатация",
            "Дальнейшие этапы и артефакты",
        ],
    )
    doc.add_page_break()


def section_1(doc):
    h1(doc, "1. Постановка задачи и архитектура")

    q(
        doc,
        1,
        "Возможно ли сделать мобильный клиент Yggdrasil под Android: VPN, "
        "split tunneling, публичные пиры, DNS, адресная книга? Сначала изучи "
        "и составь план, код пока не пиши.",
    )
    a(
        doc,
        "Да, всё перечисленное реализуемо без root. Клиент собран из трёх "
        "слоёв: Flutter отвечает за интерфейс и состояние, Kotlin — за "
        "VpnService, удержание туннеля, супервизор пиров и журнал, Go-мост "
        "(yggdrasil-go 0.5.15, собранный gomobile в AAR) — за сам узел, "
        "замеры задержки и userspace-форвардер tun2socks.",
    )
    a(
        doc,
        "Ключевое ограничение: системное TUN-устройство не используется. "
        "VpnService отдаёт файловый дескриптор, пакеты разбирает стек gVisor, "
        "а наружу они уходят через защищённые сокеты. Поэтому трафик "
        "приложений из allow list идёт через userspace-форвардер и медленнее "
        "прямого, а трафик к адресам Yggdrasil попадает в Go-ядро напрямую.",
    )
    a(
        doc,
        "План был разбит на этапы: сначала рабочий туннель, публичные пиры с "
        "замером задержки, split tunneling, DNS и адресная книга; затем "
        "доводка интерфейса по замечаниям; затем exit-node — выход в обычный "
        "интернет через выбранный узел сети.",
    )

    q(doc, 2, "Почему MTU по умолчанию 1280?")
    a(
        doc,
        "1280 байт — минимальный MTU, который обязан поддерживать IPv6. "
        "Yggdrasil работает поверх IPv6, а путь до пира может проходить через "
        "туннели с меньшим MTU, поэтому большее значение грозит тихой потерей "
        "пакетов: соединение устанавливается, но часть данных пропадает. "
        "В настройках значение можно поднять до 1500, если путь заведомо чистый.",
    )

    q(doc, 3, "В блоке Latency / Received / Sent — как измеряется задержка, между чем и чем?")
    a(
        doc,
        "Это round-trip между узлом на телефоне и каждым подключённым пиром, "
        "усреднённый по живым линкам. Yggdrasil отправляет по каждому линку "
        "подписанный запрос и ждёт корректный подписанный ответ; на экране — "
        "экспоненциальное среднее этих round-trip. Это протокольное измерение "
        "самого Yggdrasil, а не ICMP-пинг и не время TCP-соединения.",
    )

    q(doc, 4, "Как часто обновляется задержка в Active Peers и что делает кнопка Refresh?")
    a(
        doc,
        "Список и задержки перечитываются с интервалом проверки из "
        "Settings → Connection, по умолчанию каждые 15 секунд. Кнопка "
        "Refresh («Re-check now») просит сервис прочитать живое состояние "
        "линков немедленно, не дожидаясь очередного тика; pull-to-refresh на "
        "главном экране делает то же самое и дополнительно опрашивает "
        "состояние дважды с паузой 300 мс, чтобы поймать свежие цифры после "
        "пробуждения телефона.",
    )

    q(doc, 5, "Почему в найденных и проверенных пирах только tcp и tls? А где ws, quic и т. п.?")
    a(
        doc,
        "Поддерживаются все пять схем: tls, tcp, wss, ws и quic — в каталоге "
        "публичных пиров есть фильтр по протоколу, и такие узлы там видны. "
        "В быстром наборе преобладают tls и tcp по двум причинам: полный "
        "список прогоняется сначала дешёвым TCP-подключением, чтобы "
        "отсортировать хосты по сетевой близости, а quic-пиры TCP вообще не "
        "слушают и на этом проходе отсеиваются; кроме того, операторы чаще "
        "режут UDP, чем TCP.",
    )

    q(
        doc,
        6,
        "Сколько пиров тестирует Test latency, по какому принципу выбирает и "
        "по какому принципу сортируется список?",
    )
    a(
        doc,
        "В каталоге кнопка тестирует первые 25 пиров текущей отфильтрованной "
        "выборки, партиями по пять по умолчанию. Полный поиск на вкладке "
        "Peers идёт иначе: "
        "сначала TCP-подключение ко всем хостам, затем Yggdrasil-handshake "
        "партиями по пять, от самых близких, с остановкой, когда набралось "
        "достаточно живых — поэтому список готов за секунды, а не за минуты.",
    )
    a(
        doc,
        "Сортировка — по расстоянию от текущего местоположения, пиры своей "
        "страны идут первыми; порядок сохраняется при фильтрации. Строка, "
        "которая тестируется, подсвечивается фоном, показывает спиннер и "
        "надпись «Testing…», а кнопка на время теста не меняет размер, а "
        "становится неактивной.",
    )

    q(doc, 7, "Зачем кнопка Custom DNS? Разве она не дублирует «+ Add a server»?")
    a(
        doc,
        "Дублировала, поэтому её убрали. Сейчас в блоке DNS два режима — "
        "Yggdrasil и System — плюс «+ Add a server» для своего адреса и "
        "список доступных серверов из вики с кнопкой «+» у каждого. "
        "Используемые серверы показаны списком, нерабочие вынесены в "
        "отдельный блок с пометкой и кнопкой возврата.",
    )


def section_2(doc):
    h1(doc, "2. Интерфейс, измерения и настройки")

    q(doc, 8, "Почему во время подключения форма меняет размеры и всё смещается?")
    a(
        doc,
        "Анимация меняла высоту блока с кнопкой, и нижние карточки уезжали. "
        "Теперь под кнопкой зарезервирован фиксированный блок высотой 70 "
        "пикселей: в нём живут статус, прогресс-бар, счётчик пиров и время "
        "подключения, поэтому при старте и остановке ничего не прыгает.",
    )

    q(doc, 9, "Время подключения должно выводиться после подключения и в том же блоке, что кнопка.")
    a(
        doc,
        "Так и сделано: таймер появляется только в состоянии «подключено», "
        "рядом с кнопкой, и тикает раз в секунду. В отключённом состоянии "
        "строки времени нет.",
    )

    q(doc, 10, "Показывать количество подключённых пиров (например, 4/4) в блоке Active Peers.")
    a(
        doc,
        "Счётчик подключённых пиров выводится строкой «N of M connected» под "
        "кнопкой, пока идёт установка связи, и обновляется по мере поднятия "
        "линков. В карточке Active Peers подзаголовком показано общее число "
        "пиров в наборе, а состояние каждого пира — в его строке.",
    )

    q(doc, 11, "По нажатию на пира должна выводиться подробная информация, как в yggdrasilctl getpeers.")
    a(
        doc,
        "Нажатие на строку пира открывает диалог: URI, схема, порт, "
        "направление (In/Out), задержка, cost, адрес Yggdrasil, ключ, uptime, "
        "принято/отправлено и последняя ошибка с временем, когда она была "
        "зафиксирована. URI копируется нажатием на строку.",
    )

    q(doc, 12, "В блоке Your address нужен ещё subnet, как в yggdrasilctl getself.")
    a(
        doc,
        "Subnet добавлен отдельной строкой под адресом. Обе строки — "
        "горизонтально прокручиваемые: длинный IPv6-адрес не переносится на "
        "вторую строку, его можно прокрутить пальцем, а нажатие копирует "
        "значение в буфер обмена.",
    )

    q(doc, 13, "В блоке Latency/Received/Sent информация о peers online дублирует Active Peers — убери.")
    a(
        doc,
        "Убрана: в статистике остались только принято, задержка и отправлено, "
        "а также пояснение, что это средний round-trip до подключённых пиров "
        "и как часто он обновляется. Счётчик подключённых пиров остался под "
        "кнопкой подключения, а в карточке Active Peers — общее число пиров "
        "и состояние каждого из них.",
    )

    q(
        doc,
        14,
        "На вкладке Peers в Results нужно показывать задержку, если она уже "
        "измерялась; и объяснять, что происходит при Test latency.",
    )
    a(
        doc,
        "Результаты показывают и протокольную задержку Yggdrasil, и TCP-RTT "
        "отдельной мелкой строкой — вторая нужна только для сортировки и "
        "помечена как TCP. Если пир ещё не тестировался, стоит «not tested», "
        "если не прошёл handshake — «no handshake».",
    )

    q(doc, 15, "В разделе Apps: Chrome выделяется, Samsung Browser — нет; строка Selected вылезает за экран; Reconnect мигает.")
    a(
        doc,
        "Список приложений строится по установленным пакетам, поэтому "
        "Samsung Browser определяется как отдельный пакет "
        "com.sec.android.app.sbrowser и отмечается наравне с Chrome; "
        "пресет браузеров включает оба. Строку «Selected: …» заменили "
        "компактным чипом с количеством выбранных приложений.",
    )
    a(
        doc,
        "Кнопка Reconnect теперь активна только когда список действительно "
        "изменился и переподключение ещё не идёт. На время работы она "
        "показывает спиннер и надпись «Reconnecting…», под ней появляется "
        "линейный прогресс, а по завершении — сообщение об успехе или ошибке.",
    )

    q(doc, 16, "Выбранные приложения должны идти первыми, из строки убрать «Messangers».")
    a(
        doc,
        "Список сортируется: выбранные приложения сверху, внутри группы — по "
        "имени; системные скрыты за фильтром. Упоминание мессенджеров из "
        "строки убрано, остались только пресеты «Browsers», «Messengers» и "
        "«Clear» отдельными кнопками.",
    )

    q(doc, 17, "В адресной книге нужно перетаскивание записей и групповое удаление.")
    a(
        doc,
        "Оба режима есть: список можно перетаскивать за ручку справа, порядок "
        "сохраняется; кнопка выбора в шапке включает режим выделения с "
        "чекбоксами, «выбрать все» и групповым удалением с подтверждением. "
        "Встроенные записи — это значения по умолчанию: их можно удалить, но "
        "при следующем запуске приложения они возвращаются сами.",
    )

    q(
        doc,
        18,
        "Кнопка с облачком должна показывать список ресурсов из веб-каталога "
        "без дубликатов и требовать включённого клиента.",
    )
    a(
        doc,
        "Кнопка открывает каталог Yggdrasil Web directory, парсит его в "
        "список с названием и адресом, показывает предпросмотр и позволяет "
        "добавить выбранные записи. Если туннель не поднят, вместо списка "
        "выводится сообщение, что сначала нужно подключиться; уже добавленные "
        "адреса в списке не показываются.",
    )


def section_2b(doc):
    h1(doc, "3. Оформление, тексты и предустановки")

    q(doc, 40, "В иконке убери шестиугольник, символ Y сделай больше и толще, а из центральной линии убери тёмную полосу.")
    a(
        doc,
        "Иконка перерисована: шестиугольник убран, Y стал крупнее и жирнее, "
        "тёмная полоса в центральной линии удалена. В assets/icon лежат "
        "foreground, background, round и monochrome — последний используется "
        "для themed icons в Android 13 и новее, поэтому иконка корректно "
        "выглядит и в системной теме.",
    )

    q(doc, 41, "Убери русский язык и переключение языков — оставь только английский.")
    a(
        doc,
        "Интерфейс одноязычный. Все строки собраны в lib/l10n/strings.dart, "
        "переключатель языка и русский словарь удалены, поэтому настройки "
        "больше не предлагают выбор языка.",
    )

    q(doc, 42, "Перед блоком About добавь блок Donate, как в SoftSSTP.")
    a(
        doc,
        "Блок Donate стоит перед About: несколько адресов для пожертвований, "
        "нажатие на адрес копирует его в буфер обмена и показывает "
        "подтверждение. Никаких переходов во внешние приложения не "
        "требуется.",
    )

    q(doc, 43, "Из About убери Node address и добавь ссылку на yggdrasil-go.")
    a(
        doc,
        "Строка с адресом узла убрана. Вместо неё — ссылка на "
        "github.com/yggdrasil-network/yggdrasil-go, которая открывается в "
        "браузере; рядом остались версия приложения и версия ядра.",
    )

    q(doc, 44, "В блоке Power добавь иконку перед Save battery, а Battery optimization exemption сделай как в SoftSSTP.")
    a(
        doc,
        "У пункта Save battery появилась иконка battery_saver. Исключение из "
        "оптимизации батареи сделано переключателем: включение запрашивает у "
        "Android исключение, выключение открывает системный список, где "
        "исключение снимается вручную; состояние переключателя обновляется "
        "после возврата в приложение.",
    )

    q(doc, 45, "Замени предустановленные ресурсы адресной книги на заданный список из восьми адресов.")
    a(
        doc,
        "Встроенный список содержит ровно эти восемь записей: Yggdrasil Web "
        "directory, HowTo Ygg, Forum in Yggdrasil, LibreSpeed instance, "
        "Public peers, Search engine for Yggdrasil, IP and Port Checker и "
        "Show my IP address. Остальные ресурсы добавляются кнопкой с облачком "
        "из веб-каталога, дубликаты не показываются.",
    )

    q(doc, 46, "В форме DNS надписи в кнопках Yggdrasil internal DNS, System DNS и Custom servers выровняй по центру.")
    a(
        doc,
        "Кнопки режимов собраны в SegmentedButton с выравниванием по центру и "
        "textAlign.center у подписей, поэтому текст стоит по центру в обоих "
        "состояниях и не прижимается к краю на узких экранах. Кнопки "
        "«Custom servers» больше нет — остались два режима и добавление "
        "сервера через «+ Add a server».",
    )


def section_3(doc):
    h1(doc, "4. Exit-node: профили, пиры и прямая связь")

    q(doc, 35, "Форма Edit профиля exit-node работает неправильно: теряет поля и не проверяет ввод.")
    a(
        doc,
        "Диалог переписан на Form с валидацией каждого поля: адрес должен "
        "быть адресом Yggdrasil, порт SOCKS5 — в допустимом диапазоне, порт "
        "API тоже, причём 0 означает «общий порт с SOCKS5», а peer "
        "проверяется на формат. Invite сохраняется как есть: его проверяет "
        "сервер при регистрации. Сохранение обновляет профиль по id, а не "
        "добавляет второй, поэтому поля не теряются, а ошибки подсвечиваются "
        "под соответствующим полем.",
    )

    q(doc, 36, "После переименования exit-node старое имя остаётся в интерфейсе.")
    a(
        doc,
        "Мост сообщает имена, которые получил в последней конфигурации, "
        "поэтому переименованный профиль до переподключения возвращал старое "
        "имя. Теперь интерфейс считает источником истины сохранённый список "
        "профилей: статус пропускается через сопоставление по id, и новое имя "
        "появляется сразу и в списке, и в карточке exit.",
    )

    q(doc, 37, "Нужен индикатор exit-node у кнопки подключения.")
    a(
        doc,
        "В hero-блоке при включённом exit и поднятом туннеле показывается "
        "бейдж «Exit node: <имя>»; длинное имя сокращается, а если имени "
        "нет — выводится просто «Exit node». Так видно, через какой узел "
        "пойдёт публичный трафик, не открывая вкладку exit.",
    )

    q(doc, 38, "Нужны отдельные DNS для split-DNS: для публичных имён через exit и для локальных имён.")
    a(
        doc,
        "В профиле exit два независимых списка. Первый — exitDnsServers — "
        "resolvers для обычных публичных имён, по умолчанию 1.1.1.1 и "
        "9.9.9.9; запросы к ним идут через exit по TCP. Второй — "
        "exitLocalDnsServers — для имён внутри сети Yggdrasil; пустой список "
        "означает встроенный DNS сети. Оба списка редактируются диалогом и "
        "применяются к DNS-роутеру при переподключении.",
    )

    q(doc, 39, "Задержка exit-node должна обновляться в фоне, а после реконнекта не должно быть долгого Connecting.")
    a(
        doc,
        "В сервисе работает отдельный цикл ygg-exit: первый опрос идёт через "
        "1,2 секунды после старта, дальше — каждые healthCheckSec (5–120 "
        "секунд, по умолчанию 15), а requestExitCheck будит цикл немедленно. "
        "Карточка получает свежую задержку, даже если экран был закрыт, и "
        "после переподключения статус не ждёт первого публичного запроса "
        "через exit.",
    )

    q(doc, 19, "Почему сервер и телефон не стали пирами друг друга, хотя exit-node работал?")
    a(
        doc,
        "Причин было три, и они складывались. На сервере в конфиге Yggdrasil "
        "стояло пустое «Listen», поэтому он не принимал входящие подключения, "
        "а в профиле exit не было peerURI — в QR-код не попадала peer-ссылка. "
        "Телефон создавал профиль без пира и подключался к SOCKS5 по сети "
        "Yggdrasil, но отдельного линка к серверу не устанавливал. Третий "
        "слой — ошибка сопоставления: живой статус линка приходил без "
        "query-строки, и pinned-пир не находился в списке статусов.",
    )
    a(
        doc,
        "После настройки сервер слушает tls://[::]:13338 и публикует "
        "peerURI вида:",
    )
    code(
        doc,
        "tls://160.20.158.195:13338?key=50a94406fdb4f5ecd10ca92b0571159d96ce42c9bead755a0f04ec4daa994425",
    )
    a(
        doc,
        "Инвайт теперь содержит параметр peer=, профиль на телефоне получает "
        "pinned-пир, и обе стороны видят прямой линк: в журнале телефона — "
        "«Connected outbound: 201:bd5a:…:ea3b@160.20.158.195:13338», в "
        "yggdrasilctl getpeers — входящий пир Up с RTT около 22 мс.",
    )

    q(doc, 20, "Как сделать прямую приоритетную связь телефона и сервера через Yggdrasil?")
    a(
        doc,
        "Прямой линк задаётся явно: peer-ссылка из QR добавляется в профиль "
        "exit и становится pinned-пиром, который стоит первым в списке и "
        "диалится напрямую. Сервер со своей стороны слушает порт и видит "
        "телефон как входящего пира, поэтому трафик до exit идёт одним хопом, "
        "а не через случайные публичные узлы.",
    )
    a(
        doc,
        "Отдельного флага «приоритет» в Yggdrasil нет: в ironwood путь "
        "выбирается по tree-distance и cost, а priority работает только как "
        "тай-брейк между несколькими линками к одному и тому же узлу. "
        "Приоритетность здесь достигается тем, что нужный линк прописан "
        "явно и поддерживается супервизором как отдельный пир.",
    )

    q(doc, 21, "Почему pinned-пир показывался как «waiting» и с прочерком, хотя линк был Up?")
    a(
        doc,
        "Yggdrasil в live-статусе отдаёт URI без query-строки: функция "
        "urlForLinkInfo вычищает RawQuery, оставляя только схему, хост и порт. "
        "Приложение искало статус по точному URI из профиля, то есть вместе с "
        "?key=…, и не находило совпадения — отсюда «waiting» и пустая "
        "задержка при реально работающем линке.",
    )
    a(
        doc,
        "Исправлено на обеих сторонах. В Dart появилась функция peerKeyOf: "
        "ключ собирается как scheme://host:port с сохранением пути, IPv6 "
        "берётся в скобки, query отбрасывается. statusByUri теперь хранит и "
        "точный URI, и ключ, и алиасы настроенных peer.uri; поиск ошибок идёт "
        "по тому же ключу. В Kotlin PeerSupervisor строит byUri по точному URI "
        "и по ключу и ищет deadSince по обоим вариантам.",
    )
    a(
        doc,
        "Дополнительно карточка exit вычисляет признак direct: если у "
        "активного профиля есть peer и его статус Up, к строке online "
        "добавляется «· direct». Добавлены тесты на peerKeyOf, включая случай "
        "«настроенный URI с ключом против живого статуса без ключа».",
    )

    q(doc, 22, "Почему кнопка Clear не удаляет пир exit-node?")
    a(
        doc,
        "Это сделано намеренно. Pinned-пир принадлежит профилю exit: "
        "супервизор не заменяет его при отвале и не показывает кнопку "
        "удаления, вместо неё стоит замок с подсказкой. Удаляется он только "
        "вместе с профилем exit-node, иначе прямая связь терялась бы при "
        "первой же чистке списка.",
    )

    q(doc, 23, "QR-код слишком большой, а что вообще в него попадает?")
    a(
        doc,
        "Размер QR уменьшен, при этом в него по-прежнему упаковывается вся "
        "ссылка инвайта: адрес exit-node в сети Yggdrasil, порт SOCKS5, токен "
        "и peer-ссылка. Сканирование создаёт профиль и сразу добавляет "
        "pinned-пир, поэтому отдельно вводить адрес и ключ не нужно.",
    )

    q(doc, 24, "Что осталось проверить, когда телефон вернётся?")
    a(
        doc,
        "Три вещи: pinned-пир должен показывать connected и реальную "
        "задержку вместо «waiting»; в карточке exit должна появиться пометка "
        "«· direct»; в списке пиров exit-node должен стоять первым. Код и "
        "сборки к этому готовы, проверка не выполнена только потому, что "
        "телефон был отключён.",
    )

    q(doc, 25, "Дальше всё делай без телефона — можно продолжать?")
    a(
        doc,
        "Да, и это было сделано. Без телефона обновлены README и бэкап, "
        "пересчитаны SHA-256 новых APK, проверено, что фиксы действительно "
        "попали в сборку, и проведена полная проверка сервера: doctor, "
        "status, порты, пиры, allowlist. Остались только пункты, которые "
        "физически требуют устройства.",
    )


def section_4(doc):
    h1(doc, "5. Серверная часть и эксплуатация")

    q(doc, 26, "Можно ли отдать SOCKS5 и API на одном порту?")
    a(
        doc,
        "Да. Если apiPort равен 0, API делит порт с SOCKS5: обработчики /v1/… "
        "живут на том же слушателе, что и прокси. В status это так и "
        "отображается — «shared with SOCKS5 (same port, /v1/...)», а doctor "
        "отдельно проверяет /v1/health. Один порт проще держать открытым в "
        "файрволе и меньше заметен снаружи.",
    )

    q(doc, 27, "Поддерживается ли UDP и QUIC через exit-node?")
    a(
        doc,
        "Пока нет: через exit идёт только TCP. Публичный UDP при активном "
        "exit намеренно отбрасывается, чтобы QUIC не уходил мимо exit, а "
        "падал обратно на TCP; DNS через exit тоже сразу кадрируется в TCP. "
        "UDP ASSOCIATE и relay — первый пункт следующего этапа.",
    )

    q(doc, 28, "Маршрутизируется ли IPv6 через exit-node?")
    a(
        doc,
        "Нет. Через exit уходят публичные IPv4-адреса: они попадают в "
        "userspace-стек, а оттуда в SOCKS5. На глобальные IPv6-адреса "
        "tun2socks отвечает мгновенным отказом, и браузер сразу переходит на "
        "IPv4 по Happy Eyeballs. Полноценная IPv6-маршрутизация — отдельный "
        "пункт этапа 2.",
    )

    q(doc, 29, "Насколько защищён API exit-node?")
    a(
        doc,
        "API работает по HTTP без TLS и без токена, но слушает только адрес "
        "Yggdrasil, а не публичный интерфейс, поэтому снаружи сети он "
        "недоступен. Эндпоинт /v1/status отдаёт имя узла, источник клиента и "
        "факт наличия allowlist. Для публичного использования нужны TLS, "
        "авторизация и ограничение выдачи статуса — это заложено в этап 3.",
    )

    q(doc, 30, "Как быстро проверить, что сервер здоров?")
    a(
        doc,
        "Командой ygg-exit doctor: она проверяет конфиг, попадание "
        "listenAddress в 200::/7, назначенный адрес Yggdrasil, доступность "
        "state-каталога, читаемость allowlist, прослушивание SOCKS5 и "
        "пир-порта, ответ /v1/health и число живых пиров. Дальше — "
        "ygg-exit status, ygg-exit allow list, ygg-exit clients, "
        "yggdrasilctl getpeers и ss -lntup.",
    )
    a(
        doc,
        "Последняя проверка на VPS: «No problems found», оба сервиса active, "
        "порт 13338 доступен извне, Listen — tls://[::]:13338, в allowlist "
        "один клиент ALT-L29, в момент проверки — idle, потому что телефон "
        "отключён.",
    )

    q(doc, 31, "Можно ли ставить сервер без интерактивных вопросов и с рабочими правами на bin?")
    a(
        doc,
        "Да. install.sh понимает --yes и флаги --name, --socks-port, "
        "--api-port, --ygg-port, --public-host, --skip-peers, --no-invite, "
        "поэтому установка воспроизводится одной командой (ниже она разбита "
        "на строки только для читаемости). Бинарники в bin/ "
        "получают chmod 0755, uninstall.sh удаляет сервис, правила и "
        "каталог состояния.",
    )
    code(
        doc,
        "./install.sh --yes --name 'Ubuntu' --socks-port 1080 --api-port 0 \\n"
        "  --ygg-port 13338 --public-host 160.20.158.195 \\n"
        "  --skip-peers --no-invite",
    )


def section_5(doc):
    h1(doc, "6. Дальнейшие этапы и артефакты")

    q(doc, 32, "Что предлагается делать в этапах 2 и 3 и в каком порядке?")
    a(doc, "Предложения по развитию, в рекомендуемом порядке:")
    bullets(
        doc,
        [
            "UDP и QUIC через exit: SOCKS5 UDP ASSOCIATE и relay, чтобы "
            "работали DNS, QUIC и видеозвонки.",
            "IPv6-маршрутизация через exit для сетей, где IPv6 есть.",
            "TLS и авторизация API, ограничение выдачи /v1/status.",
            "Квоты и учёт трафика по клиентам.",
            "Мульти-exit: несколько выходных узлов с выбором по правилам.",
        ],
        numbered=True,
    )
    a(
        doc,
        "Порядок выбран по соотношению пользы и риска: UDP/QUIC закрывает "
        "самый заметный пробел, IPv6 нужен меньшему числу сетей, TLS и "
        "ограничения — перед публичным использованием, квоты и мульти-exit — "
        "когда появится несколько клиентов.",
    )

    q(doc, 33, "Где лежат готовые сборки и как проверить их целостность?")
    a(
        doc,
        r"Сборки и бэкап — в Z:\BACKUP\Y-Node. Там лежат два APK, README с "
        "таблицей размеров и хешей и SHA256SUMS.txt со всеми файлами, "
        "включая серверные. Текущая сборка: arm64-v8a — 42.0 МБ, "
        "versionCode 22; armeabi-v7a — 37.5 МБ, versionCode 21.",
    )
    code(
        doc,
        "4116735d766b12d801ce8e1f8fe6daa6d3947a8083871df49ef665ec881af1e9  Y-Node-1.0.0-arm64-v8a.apk\n"
        "e4b5774054992de025769625fc47e27dbe067ce6df490d5bdb2fe6f195f9fa7d  Y-Node-1.0.0-armeabi-v7a.apk",
    )
    a(
        doc,
        "Проверка на Windows: Get-FileHash <файл> -Algorithm SHA256 и "
        "сравнение с SHA256SUMS.txt; целостность APK дополнительно "
        "подтверждается тем, что в классах и libapp.so присутствуют новые "
        "символы peerKey и exitCardDirect.",
    )

    q(doc, 34, r"Собери все мои вопросы и ответы в docx в каталог Z:\BACKUP\Y-Node.")
    a(
        doc,
        "Сделано: этот документ. Вопросы сгруппированы по темам — от "
        "постановки задачи и интерфейса до exit-node, сервера и планов; "
        "внутри темы идут в хронологическом порядке. Ответы описывают "
        "принятое решение, а где полезно — точные значения, команды и "
        "проверенные результаты.",
    )


def main():
    doc = build_document()
    title_block(doc)
    section_1(doc)
    section_2(doc)
    section_2b(doc)
    section_3(doc)
    section_4(doc)
    section_5(doc)
    doc.save(OUT)
    print("saved:", OUT)
    print("paragraphs:", len(doc.paragraphs))


if __name__ == "__main__":
    main()
