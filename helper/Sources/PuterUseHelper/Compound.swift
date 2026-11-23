import AppKit
import ApplicationServices

/// Actions that do in one step what a person does in several: type into a field, fill a form, go to a
/// web address, open a file or app, pick from a pop-up, wait for something to appear.
extension Handlers {
    static let textInputs: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Windows the agent opened this session (by navigate or open, or followed into): its own, so
    /// navigating one doesn't replace a page the user was reading.
    static var agentWindows: Set<CGWindowID> {
        get { Session.current.agentWindows }
        set { Session.current.agentWindows = newValue }
    }

    /// The element an action names (`elementNode`: element or target), or the control it's the label of: a text
    /// (or label element) titling just one control that `fits` (`AXServesAsTitleForUIElements`: a form's "Email"
    /// beside its field) names that control. Anything else comes back as it is, for the caller's own check.
    static func controlNode(_ a: [String: Any], _ t: Target, _ fits: (AXUIElement) -> Bool) throws -> AX.Node? {
        guard let n = try elementNode(a, t) else { return nil }
        guard n.role == "AXStaticText" || n.role == "AXGroup", !fits(n.element), let c = AX.titled(by: n.element, fits) else {
            return n
        }
        let role = AX.value(c, kAXRoleAttribute) as? String ?? ""
        return AX.Node(element: c, frame: AX.frame(c), role: role, label: AX.label(c),
                       name: AX.roleNames[role] ?? String(role.dropFirst(2)).lowercased(), parent: AX.parent(c))
    }

    /// type {text, element|x,y, clear, submit}: click into the field first if one is given, optionally
    /// empty it, type, and optionally press Return.
    static func typeInto(_ a: [String: Any], _ text: String, _ run: Run) async throws {
        var node: AX.Node?
        if a["element"] != nil || a["target"] != nil {
            node = try controlNode(a, run.target, AX.isTextInput)
            // The keys go wherever the focus ends up: not into a button that was named by mistake.
            if let n = node, !AX.isTextInput(n.element) {
                throw HelperError("that's a \(AX.describe(n.element)), not a text field to type into")
            }
        }
        // A Return outside a text area presses the window's default button: if that needs the user's OK,
        // stop before anything is clicked, emptied or typed.
        if a["submit"] as? Bool == true || text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let r = try route(run.target, at: nil, foreground: run.foreground)
            try Policy.checkFocusKeys(Policy.running ?? a, [["return"]], r, textArea: node.map { $0.role == "AXTextArea" })
        }
        if a["element"] != nil || a["target"] != nil || a["x"] != nil || a["coordinate"] != nil {
            // A suggestions or saved-data list earlier typing opened may lie over this field: closed first, so the
            // click lands in the field rather than on one of its entries (a saved card, an address) that fills it in.
            // (Not right after a fill's pop-up or checkbox, `_picked`: a pop-up's menu still fading out is no such list.)
            if !run.foreground, a["_picked"] as? Bool != true, let pid = pid(run.target) {
                await closeSuggestions(pid, before: "clicking into the field", route: try? route(run.target, at: nil, foreground: false))
            }
            var click: [String: Any] = ["type": "click", "_pointer": true]  // a real click: it puts the caret there
            for k in ["element", "target", "x", "y", "coordinate", "units"] { if let v = a[k] { click[k] = v } }
            if let node { click["_node"] = node }  // the field checked above, not found again
            try await perform(click, run)
            await Input.sleep(typist.between())
        }
        let r = try route(run.target, at: nil, foreground: run.foreground)
        if run.foreground { prepareForeground(r) }
        var field: AX.Node?  // the text input typed into: its text can be selected exactly
        if let n = node, AX.isTextInput(n.element) {
            // The click should have put the caret in it; if the app didn't take it (a click spent on
            // activating it), focus it directly rather than type into whatever had the focus.
            func focused() -> Bool { AX.focusedElement(pid: r.pid).map { AX.isInside($0, n.element) } ?? false }
            if !focused() {
                _ = AX.focus(n)
                await Input.ms(60)
                guard focused() else { throw HelperError("couldn't put the caret in the \(AX.describe(n.element)); nothing was typed") }
            }
            field = n
        }
        if field == nil, let f = AX.focusedElement(pid: r.pid), AX.isInWindow(f, r.wid), AX.isTextInput(f) {
            let role = AX.value(f, kAXRoleAttribute) as? String ?? ""
            field = AX.Node(element: f, frame: AX.frame(f), role: role, label: AX.label(f), name: AX.roleNames[role] ?? "field")
        }
        let held = field.flatMap { AX.value($0.element, kAXValueAttribute) as? String }  // its text before
        let length = held.map { ($0 as NSString).length }
        // A browser's address bar holds one address: a new one replaces it. (A click selects the old one
        // there, and moving the caret to its end made two URLs run together.)
        let addressBar = field.map { AX.isBrowserAddressBar($0.element, pid: r.pid) } ?? false
        let replace = a["clear"] as? Bool ?? addressBar
        var into: CFRange?  // what of its text the typing replaces (empty: where it goes in)
        if replace {
            guard field != nil else {
                // Select-all and delete on whatever has the focus could empty a list of mail, not a field.
                let focus = AX.focusedElement(pid: r.pid).map(AX.describe) ?? "nothing"
                throw HelperError("clear needs a text field, and the focus is on \(focus)")
            }
            if let field, let length, length > 0, AX.select(field.element, CFRange(location: 0, length: length)) {
                try await press(["BackSpace"], r)
            } else if (length ?? 1) > 0 {
                try await press(["cmd", "a"], r)
                await Input.sleep(typist.between())
                try await press(["BackSpace"], r)
            }
            if Connection.current?.work.fields == nil { Connection.current?.work.did.append("emptied the field") }
            await Input.sleep(typist.between())
        } else if let field, let length {
            // Keep a selection the app made itself (a click in one selects all): typing replaces it, as
            // it would for a person. Otherwise the click landed mid-text: type after what's there.
            let selected = AX.selectedRange(field.element)
            if (selected?.length ?? 0) == 0 {
                AX.select(field.element, CFRange(location: length, length: 0))
            }
            into = (selected?.length ?? 0) > 0 ? selected : CFRange(location: length, length: 0)
        }
        // What the field should hold once typed, when the act checks its edits (`VerifyEdit`). Not an address bar's:
        // its suggestions complete what's typed there.
        let expected: String? = VerifyEdit.collecting && !addressBar
            ? (replace ? text : VerifyEdit.expectedText(old: held, range: into, typed: text)) : nil
        // An address sent from the address bar is checked as navigate checks it: a Return that went nowhere
        // (or a page that didn't load) gets a note, not a quiet success.
        let newline: (Character) -> Bool = { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        let submits = a["submit"] as? Bool == true || text.contains(where: newline)
        let goes = addressBar && submits
        let shown = goes ? shownPage(run) : nil
        // A form sent from a page's one-line field: the batch waits for the page it goes to (`awaitPage(after:)`).
        if submits, !addressBar, let field, AX.value(field.element, kAXRoleAttribute) as? String != "AXTextArea",
           let mark = pageMark(at: field.element, run, watch: submitWatch) {
            run.pageMark = mark
        }
        try await typeText(text, r)
        if let field, !text.contains(where: { newline($0) || $0 == "\t" }) {
            if AX.value(field.element, kAXSubroleAttribute) as? String != "AXSecureTextField" {
                let shows = try await readBack(field, text, whole: replace, r)
                VerifyEdit.typed(field, expected: expected, shows: shows)
            } else {
                VerifyEdit.typed(field, expected: nil, shows: nil, secure: true)  // never read, so never confirmed
            }
        }
        if a["submit"] as? Bool == true {
            await Input.sleep(typist.between())
            await closeSuggestions(r.pid, before: "pressing Return", route: r)
            try await press(["Return"], r)
            Connection.current?.work.did.append("pressed Return")
        }
        if goes {
            let address = text.split(whereSeparator: newline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            try await awaitPage(address, before: shown, run, timeout: pageTimeout(a))
        }
    }

    /// Typed text that didn't land as typed (an autocomplete took over, a mask reformatted it, a key was
    /// lost) gets a note; only letters and digits are compared, as fields format the rest. Typing that
    /// went to another window or a pop-up instead is an error: the batch stops before a Return. Returns what the
    /// field showed when it was last read (nil: it wasn't, there being no letters or digits to compare).
    @discardableResult
    static func readBack(_ field: AX.Node, _ text: String, whole: Bool, _ r: Route) async throws -> String? {
        func plain(_ s: String) -> String {
            String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        }
        let want = plain(text)
        guard !want.isEmpty else { return nil }
        var shows = ""
        for i in 0..<7 {  // a web page updates its fields a moment later
            if i > 0 { try await Run.pause(0.05) }
            shows = AX.value(field.element, kAXValueAttribute) as? String ?? ""
            if whole ? plain(shows) == want : plain(shows).contains(want) { return shows }
        }
        let typed = "\"\(AX.clip(text, 60))\""
        if let f = AX.focusedElement(pid: r.pid), !AX.isInside(f, field.element) {
            if !AX.isInWindow(f, r.wid) {
                throw HelperError("the typing went to \(AX.describe(f)), which took the focus from the field: look before going on")
            }
            if AX.isTextInput(f) {  // the page moves it on (a code box per digit)
                notes.append("the focus moved on to \(AX.describe(f)) while typing \(typed): look before typing more")
                return shows
            }
        }
        notes.append(plain(shows).isEmpty
            ? "the field shows nothing after typing \(typed); some editors keep their text elsewhere, so look before typing it again"
            : "the field shows \"\(AX.clip(shows, 60))\" after typing \(typed): look before typing it again")
        return shows
    }

    /// Whether typed `text` can be read back from its field: not with a Return or Tab in it, which submit or
    /// move on (the field may rightly show something else then).
    nonisolated static func readsBack(_ text: String) -> Bool {
        !text.contains { $0 == "\n" || $0 == "\r" || $0 == "\r\n" || $0 == "\t" }
    }

    /// The field a type that names none goes into, to read back once it's typed (`readBack`): the app's focused
    /// element, when that's a text input in the batch's window and not a password field (whose text is never
    /// read). Nil otherwise, or when `text` can't be read back (`readsBack`).
    static func focusedField(_ r: Route, for text: String) -> AX.Node? {
        guard readsBack(text), let f = AX.focusedElement(pid: r.pid), AX.isTextInput(f), AX.isInWindow(f, r.wid),
              !Policy.isSecure(f) else { return nil }
        return AX.Node(element: f, frame: nil, role: AX.value(f, kAXRoleAttribute) as? String ?? "")
    }

    /// fill {fields: [{element|x,y, text} | {element, option} | {element, checked}], submit}, or fields as an object of
    /// labels and values: {"Email": "ada@example.com", "Country": "NZ", "Agree": true} (`fillByLabel`).
    static func fill(_ a: [String: Any], _ run: Run) async throws {
        if let byLabel = a["fields"] as? [String: Any], !byLabel.isEmpty { return try await fillByLabel(a, byLabel, run) }
        guard let fields = a["fields"] as? [[String: Any]], !fields.isEmpty else {
            throw HelperError("fill needs fields: {\"Email\": \"ada@example.com\", \"Agree\": true}, or [{element: 3, text: \"Ada\"}, "
                + "{element: 5, option: \"Blue\"}, …]")
        }
        let submitClick = fillSubmitClick(a)
        // What needs the user's OK is found before anything is filled in, so a stop leaves the form as it was.
        let app = pid(run.target) ?? run.pidAtStart
        for (i, f) in fields.enumerated() {
            do {
                if let option = f["option"] ?? f["select"] {
                    if let n = try controlNode(f, run.target, AX.isChoosable), let match = AX.optionTitle(n.element, "\(option)") {
                        try Policy.checkItem(a, match)
                    }
                } else if let want = f["checked"] as? Bool, let n = try controlNode(f, run.target, AX.isCheckable),
                          let v = AX.value(n.element, kAXValueAttribute) as? NSNumber, (v.intValue != 0) != want {
                    try Policy.checkPress(a, node: n, at: nil, pid: app)
                }
            } catch let stop as Policy.NeedsOK {
                throw stop
            } catch {
                throw HelperError("field \(i + 1): \(error)")
            }
        }
        try checkFillSubmit(a, submitClick, run, app: app) { fields.last.flatMap { try? controlNode($0, run.target, AX.isTextInput) } }
        try await fillIn(a, fields, submit: submitClick, run, app: app)
    }

    /// fill with fields as an object: each key names a control as target does (label-aware: a form's "Email" beside its
    /// field names the field), and its value says what's done to it, by the control's kind (`fieldFill`). Every key is
    /// looked up and every value checked against what it names before anything is filled (`planFill`); then each
    /// field runs as the list form's {target, text | option | checked} would, with the same checks (the policy's, the
    /// user's OK, a stop partway that says what was filled), from the top of the form down.
    static func fillByLabel(_ a: [String: Any], _ byLabel: [String: Any], _ run: Run) async throws {
        let app = pid(run.target) ?? run.pidAtStart
        let plan = try planFill(byLabel, secureAllowed: Policy.config.allowSecureFields) { key in
            guard let n = try controlNode(["target": key], run.target, AX.isFillable) else { throw HelperError("it names nothing") }
            return FieldControl(node: n, role: AX.value(n.element, kAXRoleAttribute) as? String ?? n.role,
                                textInput: AX.isTextInput(n.element), inPage: AX.webArea(of: n.element) != nil,
                                secure: Policy.isSecure(n.element), what: AX.describe(n.element))
        }
        let fields = plan.map { $0.fill.field($0.key) }
        var listed = a
        listed["fields"] = fields
        // Typing where the policy lets the agent only click is refused before anything is filled, as the list form's
        // text fields are before the batch runs.
        try Policy.checkAction(listed, pid: app)
        // What needs the user's OK, on the controls just found (not looked up again), before anything is filled in.
        for step in plan {
            do {
                switch step.fill {
                case .option(let option):
                    if let match = AX.optionTitle(step.node.element, option) { try Policy.checkItem(a, match) }
                case .checked(let want):
                    if let v = AX.value(step.node.element, kAXValueAttribute) as? NSNumber, (v.intValue != 0) != want {
                        try Policy.checkPress(a, node: step.node, at: nil, pid: app)
                    }
                case .text:
                    break
                }
            } catch let stop as Policy.NeedsOK {
                throw stop
            } catch {
                throw HelperError("\(fieldName(step.key)): \(error)")
            }
        }
        let submitClick = fillSubmitClick(a)
        try checkFillSubmit(a, submitClick, run, app: app) { plan.last?.node }
        // Its fields' routes see what it types (the list form's fields), not the object.
        try await Policy.$running.withValue(listed) {
            try await fillIn(listed, fields, submit: submitClick, run, app: app, labels: plan.map { $0.key })
        }
    }

    /// The click a fill's submit makes: on an element by its number, on a button by its text, or as a saved macro
    /// step gives it ({target, x, y, units}). Nil for `submit: true` (Return) or none.
    nonisolated static func fillSubmitClick(_ a: [String: Any]) -> [String: Any]? {
        guard let submit = a["submit"] else { return nil }
        if CFGetTypeID(submit as CFTypeRef) != CFBooleanGetTypeID(), let idx = num(submit) {  // an element (JSON 1 isn't true)
            return ["type": "click", "element": idx]
        } else if submit is String {  // the button's text
            return ["type": "click", "target": submit]
        } else if let spec = submit as? [String: Any] {  // {target, …} or a macro's {target, x, y, units}
            return spec.merging(["type": "click"]) { _, new in new }
        }
        return nil
    }

    /// A fill's submit, checked before anything is filled in: the press of its button (`click`), or its Return after
    /// the field filled last (`last`: in a text area, Return is a new line). A stop for the user's OK comes here.
    static func checkFillSubmit(_ a: [String: Any], _ click: [String: Any]?, _ run: Run, app: pid_t,
                                last: () -> AX.Node?) throws {
        if let click, click["element"] != nil || click["target"] != nil, let n = try? elementNode(click, run.target) {
            try Policy.checkPress(a, node: n, at: nil, pid: app)
        } else if a["submit"] as? Bool == true {
            let last = last()
            try Policy.checkFocusKeys(a, [["return"]], try route(run.target, at: nil, foreground: run.foreground),
                                      textArea: last.map { $0.role == "AXTextArea" })
        }
    }

    /// The fill itself, its checks made: each field in turn (as type, select or a checkbox's click do it), then the
    /// submit. `labels`: the fields' labels (the object form), which its messages name them by; else by number.
    static func fillIn(_ a: [String: Any], _ fields: [[String: Any]], submit submitClick: [String: Any]?, _ run: Run,
                       app: pid_t, labels: [String]? = nil) async throws {
        // The fill's own clicks carry its confirm (the user OK'd the form as a whole).
        let ok = a["confirm"] as? Bool == true
        func confirmed(_ d: [String: Any]) -> [String: Any] {
            var d = d
            if ok { d["confirm"] = true }
            return d
        }
        func name(_ i: Int) -> String { labels.map { fieldName($0[i]) } ?? "field \(i + 1)" }
        // A stop found only as it goes (an option's real title, a label read at the click) comes after
        // some fields were filled: it says so.
        func partway(_ stop: Policy.NeedsOK, _ what: String, filled: Int) -> Error {
            filled == 0 ? stop : HelperError("\(what): \(stop); \(filledSoFar(filled, labels: labels)) filled in already. "
                + "Ask the user; if they agree, repeat the fill with \"confirm\": true")
        }
        Connection.current?.work.fields = (0, fields.count)
        for (i, f) in fields.enumerated() {
            if i > 0 {
                await Input.sleep(typist.between())
                // A suggestions list the typing into the field before opened (not a pop-up's menu, a checkbox's tick).
                if typesText(fields[i - 1]) {
                    await closeSuggestions(app, before: name(i), route: try? route(run.target, at: nil, foreground: run.foreground))
                }
            }
            Connection.current?.work.typed = 0
            do {
                if let option = f["option"] ?? f["select"] {
                    var s = confirmed(f)
                    s["type"] = "select"
                    s["option"] = option
                    try await perform(s, run)
                } else if let checked = f["checked"] as? Bool {
                    try await setChecked(confirmed(f), checked, run)
                } else if let text = f["text"] as? String ?? f["value"] as? String {
                    var t = f
                    t["clear"] = f["clear"] as? Bool ?? true
                    if i > 0, !typesText(fields[i - 1]) { t["_picked"] = true }  // no typing of the fill's to have opened a list
                    try await typeInto(t, text, run)
                } else {
                    throw HelperError("give text, option or checked")
                }
            } catch let stop as Policy.NeedsOK {
                throw partway(stop, name(i), filled: i)
            } catch is Cancelled {
                throw Cancelled()
            } catch {
                throw HelperError("\(name(i)): \(error)")
            }
            Connection.current?.work.fields = (i + 1, fields.count)
            Connection.current?.work.typed = 0
        }
        guard a["submit"] != nil else { return }
        await Input.sleep(typist.between())
        if fields.last.map(typesText) == true {
            await closeSuggestions(app, before: "submitting", route: try? route(run.target, at: nil, foreground: run.foreground))
        }
        do {
            // A form sent from a web page: the batch waits for the page it goes to (`awaitPage(after:)`).
            if var click = submitClick {
                click["_submit"] = true
                try await perform(confirmed(click), run)
            } else if a["submit"] as? Bool == true {
                let r = try route(run.target, at: nil, foreground: run.foreground)
                if let mark = pageMark(keys: [["return"]], r, run) { run.pageMark = mark }
                try await press(["Return"], r)
            }
            Connection.current?.work.did.append("submitted")
        } catch let stop as Policy.NeedsOK {
            throw partway(stop, "submit", filled: fields.count)
        }
    }

    /// Whether a fill's field (`fillIn`'s, of the list form) types text into its field, which can open a suggestions
    /// list: not one that picks an option or ticks a box, as `fillIn` tells them apart.
    nonisolated static func typesText(_ f: [String: Any]) -> Bool {
        guard f["option"] == nil, f["select"] == nil, !(f["checked"] is Bool) else { return false }
        return f["text"] is String || f["value"] is String
    }

    // MARK: - fill's fields as an object of labels and values

    /// A value of fill's object form: true or false, or text (a number as its text).
    enum FieldValue: Equatable { case flag(Bool), text(String) }

    /// What fill's object form does to the control a key names: types text into it, picks its option, or ticks or
    /// unticks it.
    enum FieldFill: Equatable {
        case text(String), option(String), checked(Bool)

        /// The list form's field that does it, aimed at `target` (the key): {target, text | option | checked}.
        func field(_ target: String) -> [String: Any] {
            switch self {
            case .text(let s): return ["target": target, "text": s]
            case .option(let s): return ["target": target, "option": s]
            case .checked(let on): return ["target": target, "checked": on]
            }
        }
    }

    /// What a key of the object form names, as `planFill` needs it: the control (`node`), its role, whether text is
    /// typed into it, whether it's in a web page, whether it's a password field, and how messages call it.
    struct FieldControl {
        let node: AX.Node
        let role: String
        var textInput = false
        var inPage = false
        var secure = false
        var what = ""
    }

    /// One field of the object form's plan: its key, what's done to it, and the control the key names.
    typealias FieldStep = (key: String, fill: FieldFill, node: AX.Node)

    /// What true or false sets: a checkbox, radio button or switch.
    nonisolated static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"]
    /// What text picks an option of: a pop-up button (a web page's `<select>` too), a combo box or a menu button.
    nonisolated static let choiceRoles: Set<String> = ["AXPopUpButton", "AXComboBox", "AXMenuButton"]
    /// What a key of the object form may name: those, and what text is typed into.
    nonisolated static let fillableRoles: Set<String> = toggleRoles.union(choiceRoles)
        .union(["AXTextField", "AXTextArea", "AXSearchField"])

    /// `v` as a value of the object form, or nil if it's none: true or false (JSON's, not 1 or 0), text, or a number,
    /// which goes in as its text (`numberText`).
    nonisolated static func fieldValue(_ v: Any) -> FieldValue? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .flag(n.boolValue) }
            return .text(numberText(n))
        }
        if let s = v as? String { return .text(s) }
        return nil
    }

    /// A number as text to type or an option to pick: a whole number as its digits (5, and 5.0 too), any other as
    /// Swift writes it (2.5).
    nonisolated static func numberText(_ n: NSNumber) -> String {
        if n is NSDecimalNumber { return n.stringValue }
        let type = String(cString: n.objCType)
        guard type == "d" || type == "f" else { return n.stringValue }
        let d = n.doubleValue
        if d.isFinite, d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    /// How messages name a field of the object form: by its key.
    nonisolated static func fieldName(_ key: String) -> String { "field \"\(AX.clip(key, 40))\"" }

    /// Which fields a fill stopped partway had filled, the first `n`: "fields 1-3 were" (the list form), or by their
    /// keys (`labels`, the object form's, in the order they were filled).
    nonisolated static func filledSoFar(_ n: Int, labels: [String]?) -> String {
        guard let labels else { return "fields 1-\(n) were" }
        if n == 1 { return "\(fieldName(labels[0])) was" }
        if n >= labels.count { return "all \(labels.count) fields were" }
        return "fields " + labels.prefix(n).map { "\"\(AX.clip($0, 40))\"" }.joined(separator: ", ") + " were"
    }

    /// Why the object form's keys and values can't be filled as given, or nil: a key that's empty, or a value that
    /// isn't text, a number, true or false (null, a list, an object). Checked before anything is looked up. The value
    /// is never repeated.
    nonisolated static func fieldValuesProblem(_ byLabel: [String: Any]) -> String? {
        for key in byLabel.keys.sorted() {
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "has a field with no label: each key is the text that names a field"
            }
            if byLabel[key].flatMap({ fieldValue($0) }) == nil {
                return "\(fieldName(key)) takes text, a number, or true/false (to say more of a field, such as clear or its "
                    + "element number, give fields as a list: [{\"target\": …, \"text\": …}])"
            }
        }
        return nil
    }

    /// What the object form does with `value` for the control a key names (`role`; `textInput`: text is typed into it;
    /// `inPage`: it's in a web page; `what`: how messages call it). True or false ticks or unticks a checkbox, switch or
    /// radio button; text picks an option of a pop-up, menu button or combo box, or is typed into a field. A combo box
    /// in a web page is typed into: there it's a field with suggestions (an address, a search), whose list isn't its
    /// own to pick from, and typing is what the page answers to. Anything else is an error that says what the control
    /// takes, never repeating the value (it may be a password).
    nonisolated static func fieldFill(_ value: FieldValue, role: String, textInput: Bool, inPage: Bool,
                                      what: String) throws -> FieldFill {
        let toggle = toggleRoles.contains(role)
        let choice = choiceRoles.contains(role) && !(inPage && role == "AXComboBox")
        switch value {
        case .flag(let on):
            if toggle { return .checked(on) }
            if choice { throw HelperError("that's a \(what): give the option to pick, not true or false") }
            if textInput { throw HelperError("that's a \(what): give the text to type, not true or false") }
        case .text(let text):
            if choice { return .option(text) }
            if textInput { return .text(text) }
            if toggle { throw HelperError("that's a \(what): give true or false to tick or untick it") }
        }
        let label = role == "AXStaticText" || role == "AXGroup"
        throw HelperError("that's a \(what), not a field, pop-up or checkbox to fill" + (label
            ? " (nor the label of just one): name the control by its own label, or give fields as a list with its element number"
            : ""))
    }

    /// The order the object form fills its fields in, as a person fills a form: rows from the top down, each left to
    /// right (a control whose middle is within half the shorter one's height of the row's first, 4 pt at least, is on
    /// its row); then those whose place isn't known, by key. Ties go by key too, so the order never depends on how
    /// the object was read.
    nonisolated static func fillOrder(_ items: [(key: String, frame: CGRect?)]) -> [String] {
        let placed = items.compactMap { i in i.frame.map { (key: i.key, frame: $0) } }
            .sorted { ($0.frame.midY, $0.frame.minX, $0.key) < ($1.frame.midY, $1.frame.minX, $1.key) }
        var rows: [[(key: String, frame: CGRect)]] = []
        for p in placed {
            if let first = rows.last?.first,
               p.frame.midY - first.frame.midY <= max(4, min(p.frame.height, first.frame.height) / 2) {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        let unplaced = items.filter { $0.frame == nil }.map { $0.key }.sorted()
        return rows.flatMap { row in row.sorted { ($0.frame.minX, $0.key) < ($1.frame.minX, $1.key) }.map { $0.key } } + unplaced
    }

    /// The object form's plan, made before anything is filled: every key and value checked (`fieldValuesProblem`),
    /// every key looked up (`resolve`: the control it names, label-aware, or the error the lookup ends in: nothing
    /// shows it, or several things do), what's done to each decided by its kind (`fieldFill`), text for a password
    /// field refused unless the policy allows typing in them (`secureAllowed`), and two keys naming one control
    /// refused. The first problem stops it, named by its key, so nothing is filled.
    ///
    /// It comes in the order the fields are filled in (`fillOrder`): from the top of the form down, not the order the
    /// keys were written in. A request's JSON object reaches the helper as a dictionary, which keeps no order (and a
    /// saved macro writes its keys sorted), so the form's own order is the one that's always the same; it's also the
    /// order a form's fields depend on each other in (a state after its country).
    static func planFill(_ byLabel: [String: Any], secureAllowed: Bool,
                         resolve: (String) throws -> FieldControl) throws -> [FieldStep] {
        if let why = fieldValuesProblem(byLabel) { throw HelperError(why) }
        var plan: [FieldStep] = []
        for key in byLabel.keys.sorted() {
            guard let value = byLabel[key].flatMap({ fieldValue($0) }) else { continue }  // (each was checked above)
            let c: FieldControl
            do { c = try resolve(key) } catch {
                // An element's number written as a key goes in the list form.
                let number = key.allSatisfy { $0.isASCII && $0.isNumber }
                    ? "; to name element \(key) by its number, give fields as a list: [{\"element\": \(key), …}]" : ""
                throw HelperError("\(fieldName(key)): \(error)\(number)")
            }
            do {
                let fill = try fieldFill(value, role: c.role, textInput: c.textInput, inPage: c.inPage, what: c.what)
                if case .text = fill, c.secure, !secureAllowed { throw Policy.secureRefusal() }
                if let same = plan.first(where: { CFEqual($0.node.element, c.node.element) }) {
                    throw HelperError("it names the same \(c.what) as \(fieldName(same.key)): give it once")
                }
                plan.append((key: key, fill: fill, node: c.node))
            } catch {
                throw HelperError("\(fieldName(key)): \(error)")
            }
        }
        let order = fillOrder(plan.map { (key: $0.key, frame: $0.node.frame) })
        return order.compactMap { k in plan.first { $0.key == k } }
    }

    static func setChecked(_ f: [String: Any], _ want: Bool, _ run: Run) async throws {
        guard let n = try controlNode(f, run.target, AX.isCheckable) else { throw HelperError("checked needs element or target") }
        guard let v = AX.value(n.element, kAXValueAttribute) as? NSNumber else { throw HelperError("the \(n.name) isn't a checkbox or switch") }
        VerifyEdit.checked(n, want: want, was: VerifyEdit.state(v))  // when the act checks its edits
        if (v.intValue != 0) == want { return }
        var click: [String: Any] = ["type": "click", "_node": n]  // the one just read, not found again
        for k in ["element", "target", "x", "y", "units", "confirm"] { if let v = f[k] { click[k] = v } }
        try await perform(click, run)
    }

    /// select {element, option}: pick an item of a pop-up button, combo box or menu button by its title.
    static func select(_ a: [String: Any], _ run: Run) async throws {
        guard let option = (a["option"] ?? a["value"] ?? a["text"]).map({ "\($0)" }), !option.isEmpty else {
            throw HelperError("select needs option (the item's title)")
        }
        guard let n = try controlNode(a, run.target, AX.isChoosable) else { throw HelperError("select needs element or target") }
        let role = AX.value(n.element, kAXRoleAttribute) as? String ?? ""
        guard ["AXPopUpButton", "AXComboBox", "AXMenuButton"].contains(role) else {
            throw HelperError("that's a \(AX.describe(n.element)), not a pop-up or combo box to select from")
        }
        if let match = AX.optionTitle(n.element, option) { try Policy.checkItem(a, match) }
        let shown = try await reveal(n, aimName(a))  // scrolled to first if it's out of view
        if let c = shown.map({ CGPoint(x: $0.midX, y: $0.midY) }) ?? AX.center(n) {
            await pointer.move(to: c, try route(run.target, at: c, foreground: false))
            pointer.click()
        }
        let keys = try? route(run.target, at: nil, foreground: run.foreground)  // for a web page's pop-up, if need be
        let target = run.target
        let click: (() async throws -> Bool)? = run.foreground ? nil : { try await clickToOpen(n.element, target) }
        let chose = try await AX.choose(n.element, option, menuLater: a["_last"] as? Bool == true, typeAhead: keys,
                                        click: click) {
            try Policy.checkItem(a, $0)
        }
        if AX.menuKey(chose) != AX.menuKey(option) { notes.append("selected \"\(chose)\"") }
    }

    /// Whether `AX.choose` looks for its menu only once after the pick, not for 0.4 s: as the batch's last
    /// action (`menuLater`), in a window `act` doesn't wait in full for (`waitsInFull`; nil, not known: it waits).
    nonisolated static func looksOnce(menuLater: Bool, waitsInFull: Bool?) -> Bool { menuLater && waitsInFull == false }

    static let browsers: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", "app.zen-browser.zen", "org.torproject.torbrowser", "com.kagi.kagimacos",
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.brave.browser",
        "com.brave.browser.beta", "com.brave.browser.nightly", "company.thebrowser.browser", "company.thebrowser.dia",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.operasoftware.operagx", "org.chromium.chromium",
        "com.sigmaos.sigmaos.macos", "ai.perplexity.comet", "com.openai.atlas", "net.imput.helium",
    ]

    static func isBrowser(_ pid: pid_t) -> Bool {
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() ?? ""
        return browsers.contains(id)  // not every app embedding Chromium (Spotify, Steam) is a browser
    }

    /// navigate {url, new_window}: go to a web address in a browser window: cmd+l, the address, Return,
    /// then wait for the page to load. In a window the agent didn't open, it opens its own first
    /// (new_window defaults to true there), so the user's tabs are left alone: by cmd+n, or through the
    /// app's menu when keys wouldn't reach the window and the app is in the background (`newWindowBy`);
    /// either way moved off the user's windows of the app (`takeOwnWindow`).
    static func navigate(_ a: [String: Any], _ run: Run) async throws {
        guard let url = (a["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            throw HelperError("navigate needs url")
        }
        guard case .window(let w) = run.target, isBrowser(w.pid) else {
            throw HelperError("navigate works in web browsers (to open a URL from elsewhere, use open)")
        }
        var r = try route(run.target, at: nil, foreground: run.foreground)
        if a["new_window"] as? Bool ?? !agentWindows.contains(w.id) {
            let nw: WinInfo
            if newWindowBy(foreground: run.foreground, keysReach: keysReachTarget(r), front: Hold.isFront(w.pid)) == .menu,
               let byMenu = try await newWindowByMenu(a, run, from: w) {
                nw = byMenu
            } else {  // (in the user's front app, with another window holding its keyboard, guardKeyboard stops the keys)
                let keyBefore = AX.focusedWindow(pid: w.pid), front = Hold.isFront(w.pid)
                try await press(["cmd", "n"], r)
                guard let opened = try await run.newWindow(pid: w.pid, timeout: 4) else { throw HelperError("cmd+n opened no new window") }
                agentWindows.insert(opened.id)
                nw = try await takeOwnWindow(opened, run, from: w, keyBefore: keyBefore, front: front,
                                             note: "opened its own window #\(opened.id)")
            }
            r = try route(run.target, at: nil, foreground: run.foreground)
            // It focuses its address bar: go on once it has (cmd+l needs the keyboard in it, and the address is
            // pasted only into an address bar), or after 0.6 s anyway.
            _ = try await Run.pollUntil(floor: 0.05, every: 0.04, cap: 0.6) { readyForAddress(pid: nw.pid, wid: nw.id) }
        }
        try await press(["cmd", "l"], r)
        await Input.sleep(typist.between())
        try await typeText(url, r)
        await Input.sleep(typist.between())
        let before = shownPage(run)
        try await press(["Return"], r)
        try await awaitPage(url, before: before, run, timeout: pageTimeout(a))
    }

    /// How navigate opens its own window: by the shortcut's keys, or by pressing the app's New Window menu item
    /// through accessibility (`menu`). Keys go to the app's key window, so when that's another window (the user's has
    /// the app's keyboard: `keysReach` false) they'd stop (`guardKeyboard`); the menu needs no keyboard. Only while
    /// the app is in the background (`front` false): the new window takes the app's keyboard, and in the user's front
    /// app that's where their typing goes, so there the keys stop and say so instead. Never in foreground mode.
    enum NewWindowBy: Equatable { case keys, menu }

    nonisolated static func newWindowBy(foreground: Bool, keysReach: Bool, front: Bool) -> NewWindowBy {
        !foreground && !keysReach && !front ? .menu : .keys
    }

    /// What becomes of the window that appears after navigate pressed the New Window menu item: used when it's a fresh
    /// one (`freshWindow`) and the user is still out of the app; kept as the agent's but left where it is when they've
    /// come into the app meanwhile (`userCameIn`: it's in front of them now); else not used (`notFresh`), as a page
    /// of the user's may have opened it.
    enum MenuWindow: Equatable { case use, userCameIn, notFresh }

    nonisolated static func menuWindow(fresh: Bool, front: Bool) -> MenuWindow {
        guard fresh else { return .notFresh }
        return front ? .userCameIn : .use
    }

    /// Whether a new browser window is a fresh one, as New Window opens it, rather than one a page opened: one tab
    /// (`tabs`; nil when the tab strip can't be read or isn't shown) showing a new-tab or blank page, by its page's
    /// address (`url`), else by its address bar (`address`: empty on a new tab). Nothing to go by isn't fresh.
    nonisolated static func freshWindow(tabs: Int?, url: String?, address: String?) -> Bool {
        if let tabs, tabs != 1 { return false }
        if let url { return blankPage(url) }
        if let address { return blankPage(address) }
        return false
    }

    /// Whether an address is a browser's new-tab, start or blank page ("about:home", "chrome://newtab/",
    /// "favorites://"), or empty.
    nonisolated static func blankPage(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let colon = t.firstIndex(of: ":") else { return t.isEmpty }
        let scheme = String(t[..<colon])
        var rest = t[t.index(after: colon)...]
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        if scheme == "favorites" || scheme == "topsites" { return true }
        return ["about", "chrome", "edge", "brave", "vivaldi", "opera", "arc"].contains(scheme)
            && ["blank", "home", "newtab", "new-tab-page", "new-tab-page-third-party", "startpage"].contains(String(rest))
    }

    /// navigate's own window, opened through the app's New Window menu item (the one cmd+n runs, pressed through
    /// accessibility, after the policy's check of its title) while another window has the app's keyboard and the app
    /// is in the background (`newWindowBy`). The new window takes the app's keyboard and lands where the app cascades
    /// it, over the user's window it came from, so it's moved off the user's windows as cmd+n's is (`takeOwnWindow`).
    /// Used only when it's fresh (`menuWindow`). Nil when the user came into the app before the press: the keys go
    /// then, and say why they stop.
    static func newWindowByMenu(_ a: [String: Any], _ run: Run, from w: WinInfo) async throws -> WinInfo? {
        let app = Policy.appName(w.pid)
        let keyBefore = AX.focusedWindow(pid: w.pid)
        guard let (item, title) = AX.menuItem(pid: w.pid, shortcut: ["cmd", "n"]) else {
            let at = keyBefore.map { " (#\($0))" } ?? ""
            throw HelperError("keys for #\(w.id) would go to the window with \(app)'s keyboard\(at), and \(app) has no menu item "
                + "for cmd+n to press instead: nothing was done. Ask the user to click into #\(w.id)")
        }
        try Policy.checkItem(a, title)
        try Connection.check()
        guard !Hold.isFront(w.pid) else { return nil }  // looked at again just before: the user may have come in
        guard AX.act(item, kAXPressAction) == .success else {
            throw HelperError("\(app)'s \"\(title)\" menu item couldn't be pressed (keys would have gone to another window): "
                + "nothing was done. Ask the user to click into #\(w.id)")
        }
        guard let nw = try await run.newWindow(pid: w.pid, timeout: 4) else {
            throw HelperError("pressed \(app)'s \"\(title)\" menu item, but no new window appeared")
        }
        // A new window's page and tab strip take a moment to be readable.
        let fresh = try await Run.poll(floor: 0, every: 0.08, cap: 1.2, { () -> (Bool, Bool) in
            let win = AX.window(pid: nw.pid, wid: nw.id)
            let url = AX.pageURL(pid: nw.pid, wid: nw.id), address = win.flatMap { AX.addressText(in: $0) }
            return (freshWindow(tabs: tabCount(nw), url: url, address: address), url != nil || address != nil)
        }) { $0.0 || $0.1 }.0
        let shows = (Windows.info(nw.id) ?? nw).title
        switch menuWindow(fresh: fresh, front: Hold.isFront(w.pid)) {
        case .notFresh:
            throw HelperError("window #\(nw.id)" + (shows.isEmpty ? "" : " \"\(AX.clip(shows, 40))\"") + " opened after \(app)'s "
                + "\"\(title)\" menu item was pressed, but it isn't a new empty window, so it wasn't used: a page of the user's "
                + "may have opened it. Ask the user before you use or close it")
        case .userCameIn:
            agentWindows.insert(nw.id)
            throw HelperError("opened your window #\(nw.id) through \(app)'s menu, but the user came into \(app) meanwhile, so "
                + "it's in front of them: it wasn't moved, and nothing more was done. This clears when they leave \(app); or ask them")
        case .use:
            agentWindows.insert(nw.id)
        }
        return try await takeOwnWindow(nw, run, from: w, keyBefore: keyBefore, front: false,
                                       note: "opened your window #\(nw.id) through \(app)'s menu")
    }

    /// navigate's own new window `nw`, opened from window `w` (by cmd+n or through the menu: `note` says which), taken
    /// for the rest of the batch (`Run.moveTo`). The app cascades a new window over the one it came from, so when it
    /// would cover any of the user's windows of the app on its screen, it's moved at once to where it covers least of
    /// them (`ownWindowSpot`; theirs never move), at the size the batch's box gives a new window; not when the user may
    /// have opened it (`Run.arrange`), nor in foreground mode (as `Run.moveTo` places none there). When it took the
    /// app's keyboard from `keyBefore` while the app was in the background (`front` false, as the key or menu item was
    /// pressed), that's kept as the background keyboard move is: keys stop if the user switches in (`switchedIn`). The
    /// note says where it went and that it has the keyboard. The window as it is then.
    static func takeOwnWindow(_ nw: WinInfo, _ run: Run, from w: WinInfo, keyBefore: CGWindowID?, front: Bool,
                              note: String) async throws -> WinInfo {
        let app = Policy.appName(w.pid)
        let now = Windows.info(nw.id) ?? nw
        var moved = ""
        let may = run.arrange(w.pid)
        if !run.foreground, may.place, let screen = AX.screen(of: now.frame, AX.visibleScreens()) {
            let theirs = Windows.all(onScreenOnly: true).filter {
                $0.pid == w.pid && $0.layer == 0 && $0.id != nw.id && $0.alpha > 0.05 && owner($0.id) != .agent
            }.map(\.frame)
            let box = may.fit ? run.fitBox(for: nw.id) : nil
            let size = CGSize(width: min(now.frame.width, box?.width ?? .infinity), height: min(now.frame.height, box?.height ?? .infinity))
            if let to = ownWindowSpot(frame: now.frame, size: size, screen: screen, theirs: theirs),
               let f = AX.place(pid: nw.pid, wid: nw.id, at: to) {
                try await Run.placed(nw.id, at: f)
                moved = movedOffNote(before: Run.covered(CGRect(origin: now.frame.origin, size: size), by: theirs),
                                     after: Run.covered(f, by: theirs))
                let resized = abs(f.width - now.frame.width) > 1 || abs(f.height - now.frame.height) > 1
                moved += resized ? ", sized to \(Int(f.width))x\(Int(f.height)) pt" : ""
            }
        }
        let keyed = AX.focusedWindow(pid: w.pid) == nw.id
        // Taken off the user's window as the background keyboard move does: keys stop if they switch in (`switchedIn`).
        if keyed, !front, let from = keyBefore, from != nw.id {
            Session.current.keyMove = KeyMove(pid: w.pid, wid: nw.id, from: from, took: true)
        }
        let at = notes.count
        try await run.moveTo(Windows.info(nw.id) ?? nw, note: note + moved)
        // After what moveTo adds to the note (the size it shrank it to).
        if keyed, !run.foreground, at < notes.count { notes[at] += keyboardNote(front: front, app: app) }
        return Windows.info(nw.id) ?? nw
    }

    /// Where navigate's own new window, at `frame` as its app opened it, goes on `screen` (its visible area): where it
    /// covers least of the user's windows of its app there (`theirs`, which never move; `Run.leastCovering`), at `size`
    /// (what the batch's box gives a new window), wholly on that screen. Nil when it stays where it is: at that size
    /// where it opened it covers none of theirs (`Run.moveTo` shrinks it there), or it's there already.
    nonisolated static func ownWindowSpot(frame: CGRect, size: CGSize, screen: CGRect, theirs: [CGRect]) -> CGRect? {
        guard Run.covered(CGRect(origin: frame.origin, size: size), by: theirs) >= 1 else { return nil }
        let to = Run.leastCovering(size: size, from: frame.origin, screen: screen, avoid: theirs)
        return Run.matches(frame, to) ? nil : to
    }

    /// What navigate's note on its own new window says of its move (`ownWindowSpot`), from how much of the user's
    /// windows it covered where it opened (`before`) and covers now (`after`, in square points): off them, or onto as
    /// little of them as the screen has room for; nothing when it covers no less.
    nonisolated static func movedOffNote(before: CGFloat, after: CGFloat) -> String {
        if after < 1 { return " and moved it off the user's windows" }
        return after < before ? " and moved it to where it covers least of the user's windows (the screen has no free spot its size)" : ""
    }

    /// What navigate's note on its own new window adds when it has `app`'s keyboard: it's in front when the user next
    /// switches to the app, or, when the app was their front app already (`front`), it's where their keys go now.
    nonisolated static func keyboardNote(front: Bool, app: String) -> String {
        front ? "; it now has \(app)'s keyboard, and \(app) is the user's front app"
            : "; it now has \(app)'s keyboard, so it'll be in front when the user next switches to \(app)"
    }

    /// A browser window ready for an address: the app's key window, with its focus on a text input in it
    /// (a new window focuses its address bar).
    static func readyForAddress(pid: pid_t, wid: CGWindowID) -> Bool {
        guard AX.focusedWindow(pid: pid) == wid, let f = AX.focusedElement(pid: pid) else { return false }
        return AX.isInWindow(f, wid) && AX.isTextInput(f)
    }

    /// How long to wait for a page to load after a Return in the address bar (timeout_ms, ≤ 30 s).
    static func pageTimeout(_ a: [String: Any]) -> Double { min(max(num(a["timeout_ms"]) ?? 10000, 0), 30000) / 1000 }

    /// What a browser window shows: its page's address and its title (nil if neither can be read).
    static func shownPage(_ run: Run) -> [String?]? {
        guard case .window(let now) = run.target else { return nil }
        let s = [AX.pageURL(pid: now.pid, wid: now.id), Windows.info(now.id)?.title]
        return s.allSatisfy { $0 == nil } ? nil : s
    }

    /// After the Return that goes to `url` from the address bar: wait for the page to load, with a note when
    /// it hasn't, or when the window still shows the page it showed `before` (Return didn't take).
    static func awaitPage(_ url: String, before: [String?]?, _ run: Run, timeout: Double) async throws {
        guard case .window(let now) = run.target else { return }
        if !(try await AX.waitForPage(pid: now.pid, wid: now.id, timeout: timeout, first: firstPagePause(before, url))) {
            notes.append("the page was still loading after \(Int(timeout)) s")
        } else if AX.pageURL(pid: now.pid, wid: now.id) == nil, var f = try await frozenNow(run.target, tree: true), f.unread,
                  !(await revive(now, &f)) {
            // "Loaded" with no page to say so: in a window its app isn't drawing, the page has no tree. (Brought forward
            // and drawn again, `revive`, its page can be read: whether it's the new one is looked at below.)
            meta[now.id]?.frozen = f
            notes.append("can't tell whether the page loaded: \(frozenError(f, app: now.app, wid: now.id))")
        } else if let before, !sameAddress(before[0], url) {
            // "Loaded" may be the old page: Firefox keeps it, loaded and idle, until the new one answers.
            let until = Date().addingTimeInterval(timeout)
            var shown = shownPage(run)
            while shown.map({ $0 == before }) == true, Date() < until {
                try await Run.pause(0.1)
                shown = shownPage(run)
            }
            if shown.map({ $0 == before }) == true {
                notes.append("the window still shows \"\(AX.clip((before[0] ?? before[1]) ?? "", 60))\" \(Int(timeout)) s after "
                    + "Return: the page may still be loading, or Return didn't reach the address bar. Look before navigating again")
            } else if until.timeIntervalSinceNow > 0.5,
                      !(try await AX.waitForPage(pid: now.pid, wid: now.id, timeout: until.timeIntervalSinceNow,
                                                 first: secondPagePause(before, shown))) {
                notes.append("the page was still loading after \(Int(timeout)) s")
            }
        }
    }

    /// The pause before the first look at whether the page has loaded. When what the window showed is known
    /// and the typed address isn't its own, a short one: the wait for the window to change (above) keeps the
    /// old page from passing for the new one. Otherwise (the same address, or nothing to compare) 0.4 s.
    static func firstPagePause(_ before: [String?]?, _ url: String) -> Double {
        if let before, !sameAddress(before[0], url) { return 0.1 }
        return 0.4
    }

    /// The pause before the look once the window shows something else: none when its page's address has
    /// changed (the new page is in place), 0.4 s when only its title has.
    static func secondPagePause(_ before: [String?], _ now: [String?]?) -> Double {
        if let u = now?[0], u != before[0] { return 0 }
        return 0.4
    }

    /// Whether a page's address is the one typed (so it's not expected to change): scheme, "www." and a
    /// trailing slash aside.
    static func sameAddress(_ shown: String?, _ typed: String) -> Bool {
        func bare(_ s: String) -> String {
            var s = s.lowercased()
            for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
            if s.hasPrefix("www.") { s.removeFirst(4) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return shown.map { bare($0) == bare(typed) } ?? false
    }

    // MARK: - the page a link or a form's submit goes to

    /// A web page an action may take its window away from (a link followed, a form sent): the page as it was
    /// (`page`, its address and the window's title), to tell when it's changed. `watch`: how long to look for a sign
    /// that it's going before taking it that it isn't (s). `reload`: the window's Reload button, when it read Reload
    /// as the mark was made: it reads Stop while a page loads, the one sign of it while a slow server hasn't
    /// answered yet (the old page stays, loaded, at its address).
    struct PageMark {
        let page: AXUIElement
        let url: String?
        let title: String?
        let pid: pid_t
        let wid: CGWindowID
        let watch: Double
        var reload: ReloadButton? = nil
    }

    /// A browser window's Reload button, which reads Stop while its page loads (Firefox shows a Stop button in its
    /// place instead): found once per act (`Run.reload`), then only its label read again (`AX.loading`), or, once
    /// it's gone, the buttons beside it (`parent`'s).
    final class ReloadButton {
        var button: AXUIElement
        let parent: AXUIElement?
        init(_ button: AXUIElement, parent: AXUIElement?) { (self.button, self.parent) = (button, parent) }
    }

    /// The Reload button of window `w` (`AX.reloadButton`), looked for once per act: the next look reads its label.
    static func reloadButton(_ w: WinInfo, _ run: Run) -> ReloadButton? {
        if let known = run.reload, known.wid == w.id { return known.button }
        let found = AX.window(pid: w.pid, wid: w.id).flatMap { AX.reloadButton(in: $0) }.map { ReloadButton($0.button, parent: $0.parent) }
        run.reload = (w.id, found)
        return found
    }

    /// How long to look for a page going after a link is followed or a form sent (an address changes, or the page
    /// says it's loading), and after a press of a button in a page (it may send a form, or do something in place).
    nonisolated static let linkWatch = 1.0
    nonisolated static let submitWatch = 1.0
    nonisolated static let buttonWatch = 0.5
    /// The most a link or a submit waits for its page, from the action's end (s); then the batch goes on with a note.
    nonisolated static let pageCap = 10.0

    /// How long to watch for a new page after a press on an element with these roles (its own first, then those it's
    /// in, up to its web page): a link, or anything in one (its text, an image); a button or its text. Nil for
    /// what doesn't go anywhere when pressed (a field, a checkbox, a pop-up) or anything else.
    nonisolated static func pageWatch(_ roles: [String]) -> Double? {
        let stays: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXCheckBox", "AXRadioButton",
                                  "AXSwitch", "AXToggle", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXDisclosureTriangle"]
        guard let own = roles.first, !stays.contains(own) else { return nil }
        if roles.prefix(4).contains("AXLink") { return linkWatch }
        if roles.prefix(2).contains("AXButton") { return buttonWatch }
        return nil
    }

    /// The roles of `el` and what it's in, nearest first, up to the web page it's in (not included), five at most.
    static func containerRoles(_ el: AXUIElement) -> [String] {
        var out: [String] = []
        var cur: AXUIElement? = el
        while out.count < 5, let c = cur, let role = AX.value(c, kAXRoleAttribute) as? String, role != "AXWebArea" {
            out.append(role)
            cur = AX.parent(c)
        }
        return out
    }

    /// The mark for a press on `el` in a browser window of the batch: watched as long as `watch` says, or as long
    /// as its roles do (`pageWatch`). Nil outside a browser's web page, or for what doesn't go anywhere.
    static func pageMark(at el: AXUIElement?, _ run: Run, watch: Double? = nil) -> PageMark? {
        guard let el, case .window(let w) = run.target, isBrowser(w.pid), let page = AX.webArea(of: el),
              let wait = watch ?? pageWatch(containerRoles(el)) else { return nil }
        // Its Reload button only if it reads Reload now: a page loading already says nothing about this action.
        let reload = reloadButton(w, run).flatMap { AX.loading($0) == false ? $0 : nil }
        return PageMark(page: page, url: AX.address(page), title: Windows.info(w.id)?.title, pid: w.pid, wid: w.id, watch: wait,
                        reload: reload)
    }

    /// The mark for keys `seq` that include a plain Return, pressed where the focus is in a browser window of the
    /// batch: in a page's one-line field (a form sent), or on a link or button there. Nil for anything else (a
    /// text area's new line, the address bar, which waits for its page itself, Return with a modifier).
    static func pageMark(keys seq: [[String]], _ r: Route, _ run: Run) -> PageMark? {
        let returns = seq.contains { c in c.count == 1 && ["return", "enter", "kpenter"].contains(Keys.normalize(c[0])) }
        guard returns, isBrowser(r.pid), let f = AX.focusedElement(pid: r.pid), AX.isInWindow(f, r.wid) else { return nil }
        if AX.isTextInput(f) {
            guard AX.value(f, kAXRoleAttribute) as? String != "AXTextArea" else { return nil }
            return pageMark(at: f, run, watch: submitWatch)
        }
        return pageMark(at: f, run)
    }

    /// What a page shows now, against its mark: replaced or at another address (or the window has another title),
    /// still loading, or the same.
    enum PageSeen: Equatable { case same, loading, changed }

    /// How a watch for a page going ended: no sign of it (`quiet`), a new page in place (`changed`), loading that
    /// stopped with no new page (`ended`: a download, a cancelled request), or still loading at the cap.
    enum PageSign: Equatable { case quiet, changed, ended, stillLoading }

    /// The watch, apart from the screen (unit-tested): a look each `pause` until the page has changed; until `watch`
    /// s for a first sign of it (loading or changed), then on while it's loading, `cap` s at most.
    static func awaitPageSign(watch: Double, cap: Double, look: () -> PageSeen,
                              pause: () async throws -> Void, clock: () -> Double) async throws -> PageSign {
        let start = clock()
        var loading = false
        while true {
            switch look() {
            case .changed: return .changed
            case .loading: loading = true
            case .same: if loading { return .ended }
            }
            let t = clock() - start
            if !loading && t >= watch { return .quiet }
            if t >= cap { return .stillLoading }
            try await pause()
        }
    }

    /// What the page of `mark` shows now (`PageSeen`). A page that no longer answers has been replaced.
    static func pageSeen(_ mark: PageMark) -> PageSeen {
        guard AX.value(mark.page, kAXRoleAttribute) as? String == "AXWebArea" else { return .changed }
        if AX.address(mark.page) != mark.url || Windows.info(mark.wid)?.title != mark.title { return .changed }
        let loaded = AX.value(mark.page, "AXLoaded") as? Bool, busy = AX.value(mark.page, "AXBusy") as? Bool
        return pageSeen(loaded: loaded, busy: busy, stop: mark.reload.flatMap { AX.loading($0) })
    }

    /// What a page at its mark's address and title shows: loading when it says so (not loaded, or busy), or when the
    /// window's Reload button reads Stop (`stop`: a slow server's page on its way, the old one still shown); else the
    /// same. Nil: not told.
    nonisolated static func pageSeen(loaded: Bool?, busy: Bool?, stop: Bool?) -> PageSeen {
        loaded == false || busy == true || stop == true ? .loading : .same
    }

    /// After a link is followed or a form sent (`mark`): if the page goes, wait for the new one to load, `pageCap` s
    /// at most, so the batch's next action (and its picture) meets the new page rather than the old one or half
    /// of it. A page still loading then gets a note, so the action isn't repeated. No sign of a new page within the
    /// mark's watch: the page stays (a press that did something in place), and the batch goes on.
    static func awaitPage(after mark: PageMark, _ run: Run) async throws {
        let clock = { ProcessInfo.processInfo.systemUptime }
        let start = clock()
        let sign = try await awaitPageSign(watch: mark.watch, cap: pageCap, look: { pageSeen(mark) },
                                           pause: { try await Run.pause(0.1) }, clock: clock)
        var loaded = sign != .stillLoading
        if sign == .changed, case let left = pageCap - (clock() - start), left > 0.2 {
            loaded = try await AX.waitForPage(pid: mark.pid, wid: mark.wid, timeout: left, first: 0.15)
        }
        if Trace.on { Trace.log(["k": "page", "sign": "\(sign)", "ms": Int((clock() - start) * 1000), "loaded": loaded]) }
        if !loaded {
            notes.append("the page was still loading after \(Int(pageCap)) s: wait_for what it should show rather than doing "
                + "it again")
        }
    }

    /// open {url | path, app}: open a web address, file or app the way a double-click would, without
    /// bringing it to the front. Only http(s) and mailto links and documents: nothing that runs code.
    static func open(_ a: [String: Any], _ run: Run) async throws {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        let appName = (a["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var appURL: URL?
        if let appName {
            appURL = Windows.appURL(appName) ?? Windows.runningApp(appName)?.bundleURL
            guard appURL != nil else { throw HelperError("app not found: \(appName)") }
        }
        let opened: NSRunningApplication
        var what: String
        if let s = (a["url"] ?? a["path"] ?? a["file"]) as? String, !s.isEmpty {
            let u = try openable(s)
            // A terminal or script runner given the document would run it, whatever its name.
            if let appURL, let id = Bundle(url: appURL)?.bundleIdentifier?.lowercased(), runners.contains(id) || runnerApps.contains(id) {
                throw HelperError("won't open \(u.lastPathComponent) with \(appURL.deletingPathExtension().lastPathComponent): it could run it")
            }
            what = u.isFileURL ? u.lastPathComponent : u.absoluteString
            try Connection.check()
            if let appURL {
                opened = try await NSWorkspace.shared.open([u], withApplicationAt: appURL, configuration: cfg)
            } else {
                opened = try await NSWorkspace.shared.open(u, configuration: cfg)
            }
        } else if let appURL {
            what = appURL.deletingPathExtension().lastPathComponent
            try Connection.check()
            opened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        } else {
            throw HelperError("open needs url, path or app")
        }
        let name = opened.localizedName ?? "the app"
        let did = what == name || appURL != nil && a["url"] == nil && a["path"] == nil && a["file"] == nil
            ? "opened \(name)" : "opened \(what) in \(name)"
        if let nw = try await run.newWindow(pid: opened.processIdentifier, timeout: 6) {
            agentWindows.insert(nw.id)
            try await run.moveTo(nw, note: "\(did): now on its window #\(nw.id)")
        } else {
            notes.append("\(did); no new window appeared (windows lists the ones it has)")
        }
    }

    static let runnable: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "terminal", "scpt", "scptd",
        "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "iso", "jar", "mobileconfig", "prefpane",
        "saver", "kext", "plugin", "bundle", "osax", "fileloc", "webloc", "inetloc", "py", "pyw", "rb", "pl",
        "php", "lua", "tcl", "shortcut", "appex", "systemextension", "dext", "qlgenerator", "mdimporter",
        "alfredworkflow", "ipa", "xpc", "textclipping", "service",
    ]
    /// Apps that run what they open, beyond the default handlers in `runners`.
    static let runnerApps: Set<String> = [
        "dev.warp.warp-stable", "com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "com.apple.automator", "com.apple.scripteditor2", "com.apple.shortcuts", "com.runningwithcrayons.alfred",
        "com.apple.archiveutility", "com.apple.systemevents",
    ]
    static let runners: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.apple.installer", "org.python.pythonlauncher",
        "com.apple.systempreferences", "com.apple.automator.runner", "com.apple.shortcuts", "com.apple.scripteditor2",
    ]

    /// A URL `open` may hand to the system, or why not.
    static func openable(_ s: String) throws -> URL {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            guard let u = URL(string: s) else { throw HelperError("bad URL: \(s)") }
            return u
        }
        if !lower.hasPrefix("file:"), !s.hasPrefix("/"), !s.hasPrefix("~"), let colon = s.firstIndex(of: ":") {
            throw HelperError("open takes http(s) and mailto links and files, not \(s[..<colon]): links (they can make other apps act)")
        }
        let path = lower.hasPrefix("file:") ? (URL(string: s)?.path ?? "") : (s as NSString).expandingTildeInPath
        let u = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw HelperError("no such file: \(u.path)") }
        let handler = NSWorkspace.shared.urlForApplication(toOpen: u).flatMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() }
        if runnable.contains(u.pathExtension.lowercased()) || (!isDir.boolValue && FileManager.default.isExecutableFile(atPath: u.path))
            || handler.map(runners.contains) == true {
            throw HelperError("won't open \(u.lastPathComponent): opening it could run code or change settings; ask the user to")
        }
        return u
    }

    /// wait_for {text, role, gone, timeout_ms}: until an element showing `text` (and of `role`) is in
    /// the batch's window, what's open over it, or a window that appeared since the batch began (not the
    /// app's other windows: they may be the user's), or with gone=true until none is.
    /// wait_for {change: true, timeout_ms}: see `waitForChange`.
    static func waitFor(_ a: [String: Any], _ run: Run) async throws {
        guard case .window(let w) = run.target else { throw HelperError("wait_for needs a window target") }
        let q = a["text"] as? String ?? a["label"] as? String ?? ""
        let role = (a["role"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ms = num(a["timeout_ms"] ?? a["ms"]) ?? 5000
        guard (0...30000).contains(ms) else { throw HelperError("wait_for's timeout_ms is 0-30000") }
        let timeout = ms / 1000
        if waitsForChange(a) {
            guard q.isEmpty, role == nil, a["gone"] as? Bool != true else {
                throw HelperError("wait_for takes change: true or text (and/or role), not both")
            }
            return try await waitForChange(timeout, run)
        }
        guard !q.isEmpty || role != nil else { throw HelperError("wait_for needs text (and/or role), or change: true") }
        let gone = a["gone"] as? Bool == true
        let start = Date()
        let what = (role.map { "\($0) " } ?? "") + (q.isEmpty ? "" : "\"\(q)\"")
        // An app with nothing in its accessibility tree (a canvas, a game): watch the pixels instead.
        let byEye = !q.isEmpty && AX.search(pid: w.pid, windows: waitScope(w, run), query: "", limit: 1, budget: 0.5).isEmpty
        // A window its app isn't drawing won't show it, nor say it's gone: the wait stops then, saying so (`NotDrawn`),
        // unless its app was brought forward to draw it again (`Redrawn`): then it looks again.
        func undrawn(_ e: NotDrawn) -> HelperError {
            HelperError("wait_for: " + (gone ? "whether \(what) went away can't be told" : "\(what) can't be waited for") + ": \(e)")
        }
        var asked = -Double.infinity  // when it last asked whether the window is being drawn
        var askedChrome = -Double.infinity  // when it last asked that about a match in the browser's own controls
        while true {
            let found: Bool
            if byEye {  // (its picture isn't read when the window isn't being drawn: `ocrShot`)
                do { found = !(try await ocrFind(q, run.target)).isEmpty } catch let e as NotDrawn { throw undrawn(e) } catch { found = false }
            } else {
                let scope = waitScope(w, run)
                let hits = AX.search(pid: w.pid, windows: scope, query: q, role: role, limit: 1, budget: 1)
                found = !hits.isEmpty
                // A browser window its app isn't drawing has no page to read, but its tabs and toolbar carry the page's
                // title: a match only there isn't the page's, so the wait stops, saying so. Asked once a second at most.
                let elapsed = Date().timeIntervalSince(start)
                if let m = hits.first, elapsed - askedChrome >= 1, chromeOnly(m, w) {
                    askedChrome = elapsed
                    if var f = try await frozenNow(run.target, tree: true),
                       AX.search(pid: w.pid, windows: scope, query: q, role: role, limit: 1, budget: 1, pageOnly: true).isEmpty {
                        if await revive(w, &f) { continue }  // drawn again: looked for again
                        meta[w.id]?.frozen = f
                        throw HelperError("wait_for: " + (gone ? "whether \(what) went away can't be told" : "\(what) can't be waited for")
                            + ": \(notInPage(app: w.app)), and \(NotDrawn(frozen: f, app: w.app, wid: w.id))")
                    }
                }
            }
            let waited = Date().timeIntervalSince(start)
            // Not found (or gone): asked at once, then every second while it waits.
            if !found, !byEye, gone || waited - asked >= 1 {
                asked = waited
                do { try await checkDrawn(run.target) } catch let e as NotDrawn { throw undrawn(e) } catch is Redrawn { continue }
            }
            if found != gone {
                if waited > 0.5 { notes.append("\(what) \(gone ? "went away" : "appeared") after \(String(format: "%.1f", waited)) s") }
                return
            }
            if waited >= timeout {
                throw HelperError("wait_for: \(gone ? "still showing" : "no") \(what) after \(String(format: "%.1f", timeout)) s")
            }
            try await Run.pause(0.15)
        }
    }

    /// Where wait_for looks for text: window `w`, what's open over it, and the app's windows on screen now
    /// that weren't when the batch began.
    static func waitScope(_ w: WinInfo, _ run: Run) -> Set<CGWindowID> {
        waitScope(w.id, over: openOver(w), shown: Windows.all(onScreenOnly: true).filter { $0.pid == w.pid },
                  atStart: run.visibleBefore) { systemWindow($0, AX.window(pid: $0.pid, wid: $0.id)) }
    }

    /// Not macOS's own windows shown in the app's name (`system`: the dictation orb).
    nonisolated static func waitScope(_ target: CGWindowID, over: [CGWindowID], shown: [WinInfo],
                                      atStart: Set<CGWindowID>, system: (WinInfo) -> Bool) -> Set<CGWindowID> {
        Set([target] + over + shown.filter { !atStart.contains($0.id) && !system($0) }.map(\.id))
    }

    nonisolated static func waitsForChange(_ a: [String: Any]) -> Bool {
        ["wait_for", "waitfor"].contains(kind(a)) && a["change"] as? Bool == true
    }

    /// The keys wait_for takes. It also reads `label` and `ms` (older names), and every action may have
    /// `type`/`action`, `confirm` and puter-use's own "_" keys.
    nonisolated static let waitForKeys = ["text", "role", "gone", "change", "timeout_ms"]

    /// Where an action is aimed: screenshot pixels, an element's number, or what it shows.
    nonisolated static let aimKeys = ["x", "y", "element", "target"]
    /// Also read where an action is aimed: Anthropic's `coordinate` ([x, y]), and what a saved macro step adds:
    /// window points (`units: "pt"`), the one of several with its name it picks by place (`spot`), and how many
    /// windows were open over the window when it was saved (`over`).
    nonisolated static let aimAlso = ["coordinate", "units", "spot", "over"]
    /// What an agent writes on an action for itself (why it does it, what it's for): nothing reads them.
    nonisolated static let noteKeys: Set<String> = ["reason", "description", "comment", "note"]
    /// Keys every action may have: its kind (`type`, or `action` as Anthropic's computer use calls it), the
    /// user's OK (`confirm`), `optional` (skipped when what its target names isn't there: see `optionalProblem`
    /// for the actions it goes on) and `noteKeys`. puter-use's own keys start with "_".
    nonisolated static let everyAction: Set<String> = Set(["type", "action", "confirm", "optional"]).union(noteKeys)
    /// The kinds of click. Anthropic's computer use gives the modifier keys one holds as its `text` ("shift").
    nonisolated static let clickKinds: Set<String> = ["click", "left_click", "double_click", "triple_click", "right_click",
                                                      "middle_click"]

    /// A click's `text`, when it names modifier keys and nothing else ("shift", "ctrl+alt", ["cmd", "shift"]):
    /// Anthropic's computer use holds them for the click. Nil for other text (a label meant for target) and
    /// other kinds, whose text means something else.
    nonisolated static func modifierText(_ a: [String: Any]) -> Any? {
        guard clickKinds.contains(kind(a)), let v = a["text"] else { return nil }
        let names = Keys.splitCombo(v)
        return !names.isEmpty && names.allSatisfy({ Keys.modifiers[Keys.normalize($0)] != nil }) ? v : nil
    }

    /// The modifier keys action `a` holds as it goes: `keys` (or `modifiers`), else a click's `modifierText`.
    nonisolated static func modifierKeys(_ a: [String: Any]) -> Any? {
        let given = a["keys"] ?? a["modifiers"]
        guard Keys.splitCombo(given).isEmpty else { return given }
        return modifierText(a) ?? given
    }

    /// What a field of fill reads (as type, select or a checkbox's click do), and also what a type action
    /// written as a field carries (`type`/`action`), and the place a saved macro step gives it (`x`, `y`, in points).
    nonisolated static let fieldKeys = (takes: ["element", "target", "text", "option", "checked", "clear"],
                                        also: aimAlso + ["x", "y", "value", "select", "submit", "timeout_ms", "type", "action",
                                                         "confirm"])
    /// Parameters of act itself, which an action doesn't read (said so when one is put in an action).
    nonisolated static let actParams: Set<String> = ["window", "screenshot", "foreground", "settle_ms", "guard", "save_as", "marks",
                                                     "verify_edits", "crop_changes", "detail"]

    /// The kinds of action, the documented names first (for "did you mean"), then the other names they go by.
    nonisolated static let actionKinds = [
        "click", "double_click", "triple_click", "right_click", "middle_click", "move", "drag", "scroll", "mouse_down",
        "mouse_up", "type", "keypress", "key_down", "key_up", "hold_key", "menu", "fill", "select", "navigate", "open",
        "wait_for", "wait", "clipboard", "read", "paste", "set_value", "focus", "perform", "activate", "close_window", "macro",
        "screenshot", "left_click", "mouse_move", "hover", "left_click_drag", "type_text", "key", "press_key", "hotkey",
        "keydown", "keyup", "hold", "menu_item", "choose", "goto", "go_to", "open_url", "launch", "waitfor", "ax",
        "secondary", "sleep", "raise", "focus_window", "close",
    ]

    /// The keys an action of `kind` reads, under every name it reads them by (OpenAI's and Anthropic's
    /// computer-use names among them), as `perform` and the compound actions read them: `name`, the kind's
    /// documented name; `takes`, the keys an error lists; `also`, the other names and a saved macro step's
    /// keys. Besides these, `everyAction` and "_" keys. Nil for a kind no action has.
    nonisolated static func actionKeys(_ kind: String) -> (name: String, takes: [String], also: [String])? {
        switch kind {
        case "click", "left_click", "double_click", "triple_click", "right_click", "middle_click":
            return (kind == "left_click" ? "click" : kind, aimKeys + ["button", "keys", "item"], aimAlso + ["count", "clicks", "modifiers"])
        case "move", "mouse_move", "hover":  // (keys: held on the way, as OpenAI's computer use gives them)
            return ("move", aimKeys + ["keys"], aimAlso + ["modifiers"])
        case "mouse_down":
            return (kind, aimKeys + ["button", "keys"], aimAlso + ["modifiers"])
        case "mouse_up":  // (its button is the one held down: naming it changes nothing)
            return (kind, aimKeys + ["keys"], aimAlso + ["modifiers", "button"])
        case "drag", "left_click_drag":
            return ("drag", ["path", "from", "to", "button", "keys"],
                    ["start", "end", "start_coordinate", "coordinate", "x", "y", "modifiers", "units", "over"])
        case "scroll":  // (until, max_scrolls: scroll until a text shows, `untilProblem`)
            return (kind, aimKeys + ["scroll_x", "scroll_y", "direction", "amount", "until", "max_scrolls"],
                    aimAlso + ["dx", "dy", "scroll_direction", "scroll_amount"])
        case "type", "type_text":
            return ("type", ["text"] + aimKeys + ["clear", "submit"], aimAlso + ["value", "timeout_ms"])
        case "keypress", "key", "press_key", "hotkey":
            return ("keypress", ["keys", "repeat"], ["key", "text", "times"])
        case "key_down", "keydown":
            return ("key_down", ["keys"], ["key", "text"])
        case "key_up", "keyup":
            return ("key_up", ["keys"], ["key", "text"])
        case "hold_key", "hold":
            return ("hold_key", ["keys", "ms"], ["key", "text", "duration", "seconds"])
        case "menu", "menu_item":
            return ("menu", ["item"], ["path", "text"])
        case "fill":
            return (kind, ["fields", "submit"], [])
        case "select", "choose":
            return ("select", aimKeys + ["option"], aimAlso + ["value", "text"])
        case "navigate", "goto", "go_to":
            return ("navigate", ["url", "new_window", "timeout_ms"], [])
        case "open", "open_url", "launch":
            return ("open", ["url", "path", "app"], ["file"])
        case "wait_for", "waitfor":
            return ("wait_for", waitForKeys, ["label", "ms"])
        case "clipboard":
            return (kind, ["text", "offset", "limit", "query"], [])
        case "read":
            return (kind, ["element", "target", "region", "offset", "limit", "query"], [])
        case "paste":
            return (kind, ["text"], [])
        case "set_value":
            return (kind, aimKeys + ["text"], aimAlso + ["value"])
        case "focus":
            return (kind, aimKeys, aimAlso)
        case "ax", "secondary", "perform":
            return ("perform", aimKeys + ["name"], aimAlso + ["ax_action"])
        case "wait", "sleep":
            return ("wait", ["ms"], ["seconds", "duration"])
        case "activate", "raise", "focus_window":
            return ("activate", [], [])
        case "close_window", "close":
            return ("close_window", [], [])
        case "screenshot":
            return (kind, [], [])
        case "macro":
            return (kind, ["name", "vars"], ["macro"])
        default:
            return nil
        }
    }

    /// Why action `a` can't run as given, or nil: a kind no action has, or a key its kind doesn't read (in a
    /// fill's fields too), which would otherwise be ignored without a word (`timeout` for wait_for's
    /// `timeout_ms` waited the default 5 s; `delta_y` scrolled nothing). Each is named, with the key it most
    /// likely meant.
    nonisolated static func unknownKeys(_ a: [String: Any]) -> String? {
        let k = kind(a)
        guard !k.isEmpty else { return "has no type: say what it does, e.g. {\"type\": \"click\", \"target\": \"Save\"}" }
        guard let keys = actionKeys(k) else {
            return "is an unknown action type" + (closest(k, actionKinds).map { " (did you mean \($0)?)" } ?? "")
        }
        // With type there, action is the kind's name again (a computer-use call passed on as it came): any other
        // value of it isn't read (perform's action is its name).
        var unread: Set<String> = []
        if a["type"] is String, let v = a["action"], (v as? String).map({ actionKeys($0.lowercased()) == nil }) ?? true {
            unread = ["action"]
        }
        // OpenAI's computer use gives a scroll the keys to hold, but a scroll's events don't carry them: refused,
        // with what such a scroll is usually for, rather than a scroll without them.
        if keys.name == "scroll", !Keys.splitCombo(a["keys"] ?? a["modifiers"]).isEmpty {
            return "can't hold keys: to scroll sideways give scroll_x (or direction left/right); to zoom use the app's "
                + "zoom shortcut or menu"
        }
        // Anthropic's computer use gives a click the modifier keys to hold as its text (`modifierText`).
        let also = keys.also + (modifierText(a) != nil ? ["text"] : [])
        if let why = strayKeys(a, takes: keys.takes, also: also, what: "\(keys.name) takes", unread: unread) { return why }
        if keys.name == "fill", let fields = a["fields"] as? [[String: Any]] {
            for (i, f) in fields.enumerated() {
                if let why = strayKeys(f, takes: fieldKeys.takes, also: fieldKeys.also, what: "a field takes") { return "field \(i + 1) \(why)" }
            }
        }
        return nil
    }

    /// The keys of `a` that aren't in `takes` or `also` (nor `everyAction`'s, unless `unread`, or "_"), each with
    /// the one it most likely meant (a documented one, before another name), and what does take: `what` and the
    /// `takes`. One whose value says nothing (null, or an empty text, list or object, as a client that fills in
    /// every field sends for the ones it doesn't use) does no harm, and passes.
    nonisolated static func strayKeys(_ a: [String: Any], takes: [String], also: [String], what: String,
                                      unread: Set<String> = []) -> String? {
        let known = everyAction.subtracting(unread).union(takes).union(also)
        func empty(_ v: Any) -> Bool {
            v is NSNull || (v as? String)?.isEmpty == true || (v as? [Any])?.isEmpty == true || (v as? [String: Any])?.isEmpty == true
        }
        let bad = a.filter { !known.contains($0.key) && !$0.key.hasPrefix("_") && !empty($0.value) }.map { $0.key }.sorted()
        guard !bad.isEmpty else { return nil }
        let named = bad.map { k -> String in
            if ["role", "nth"].contains(k), takes.contains("target") { return "\"\(k)\" (it goes in target: {\"text\": …, \"\(k)\": …})" }
            if let m = closest(k, takes) ?? closest(k, also) { return "\"\(k)\" (did you mean \(m)?)" }
            return "\"\(k)\"" + (actParams.contains(k) ? " (that's act's own parameter)" : "")
        }
        return "has \(bad.count == 1 ? "an unknown key" : "unknown keys") \(named.joined(separator: ", ")): \(what) "
            + (takes.isEmpty ? "no keys" : takes.joined(separator: ", "))
    }

    /// Why action `a` can't run as given (`unknownKeys`), or a scroll that would move nothing (no distance, or
    /// one of 0, unless it scrolls until a text shows) or whose until or max_scrolls can't be read (`untilProblem`),
    /// or a fill whose fields, given as an object, have a value it can't set (`fieldValuesProblem`), or `optional`
    /// where it can't go (`optionalProblem`), or nil.
    nonisolated static func invalid(_ a: [String: Any]) -> String? {
        if let why = unknownKeys(a) { return why }
        if kind(a) == "scroll" {
            if let why = untilProblem(a) { return why }
            // A scroll until a text shows needs no distance: it goes about a window's height at a time (down, or in
            // direction). One it's given still has to move.
            let free = isGiven(a["until"]) && !scrollDistanceKeys.contains { isGiven(a[$0]) }
            if !free, case let d = scrollDelta(a), d.dx == 0, d.dy == 0 {
                return "would scroll 0 px: give scroll_y (pixels, positive = down) and/or scroll_x, or direction (up, down, left, "
                    + "right) with amount"
            }
        }
        // Fill's fields as an object: each value is text, a number, or true/false.
        if kind(a) == "fill", let byLabel = a["fields"] as? [String: Any], let why = fieldValuesProblem(byLabel) { return why }
        if let why = optionalProblem(a) { return why }
        return nil
    }

    /// Whether key value `v` says something: there, and not null.
    nonisolated static func isGiven(_ v: Any?) -> Bool { v.map { !($0 is NSNull) } ?? false }

    /// The keys that give a scroll's distance, under every name (`scrollDelta`), but its direction alone.
    nonisolated static let scrollDistanceKeys = ["scroll_x", "scroll_y", "dx", "dy", "amount", "scroll_amount"]

    /// Why a scroll's `until` (the text to scroll until it shows: "Total", or {"text": "Total", "role": "button"}) or
    /// `max_scrolls` (how many scrolls at most until then: 1 to 15) can't be read as given, or nil (also when neither
    /// is given; null is neither). max_scrolls means nothing without until, so it's refused alone.
    nonisolated static func untilProblem(_ a: [String: Any]) -> String? {
        func text(_ v: Any?) -> Bool { (v as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
        let hasUntil = isGiven(a["until"])
        if hasUntil, let u = a["until"] {
            var readable = text(u)
            if let d = u as? [String: Any] {
                let others = d.filter { !["text", "role"].contains($0.key) && isGiven($0.value) }
                readable = text(d["text"]) && (!isGiven(d["role"]) || d["role"] is String) && others.isEmpty
            }
            if !readable {
                return "has an until it can't read: until is the text to scroll until it shows, \"Total\" or "
                    + "{\"text\": \"Total\", \"role\": \"button\"}"
            }
        }
        guard isGiven(a["max_scrolls"]), let m = a["max_scrolls"] else { return nil }
        guard hasUntil else { return "has max_scrolls without until: it's how many times a scroll until a text shows may scroll" }
        let n = (m as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
        guard let n, n.rounded() == n, n >= 1, n <= 15 else {
            return "has max_scrolls \(m is String ? "\"\(m)\"" : "\(m)"): it's a whole number from 1 to 15"
        }
        return nil
    }

    /// The kinds of action `optional` goes on: those aimed at one element by target, whose skipping leaves nothing
    /// half done (not mouse_down or mouse_up, which hold or let go of a button for the actions around them).
    nonisolated static let optionalKinds: Set<String> = clickKinds.union([
        "move", "mouse_move", "hover", "scroll", "type", "type_text", "select", "choose", "set_value", "focus", "perform",
        "ax", "secondary", "read",
    ])

    /// Why `optional` can't go on action `a` as given, or nil (also when it's absent or false). It needs an action
    /// of `optionalKinds` aimed by target alone: a step by coordinates or an element number always runs (what's
    /// at a point is always something), and a fill's fields aren't skipped one by one, nor is a scroll until a text
    /// shows (what it looks for isn't there yet).
    nonisolated static func optionalProblem(_ a: [String: Any]) -> String? {
        func given(_ d: [String: Any]) -> Bool { d["optional"].map { !($0 is NSNull) && $0 as? Bool != false } ?? false }
        if kind(a) == "fill", let i = (a["fields"] as? [[String: Any]] ?? []).firstIndex(where: given) {
            return "field \(i + 1) has optional: a fill's fields aren't skipped one by one (only an action aimed by target is)"
        }
        guard let v = a["optional"], !(v is NSNull) else { return nil }
        guard let on = v as? Bool else { return "has optional \(v): it's true or false" }
        guard on else { return nil }
        if kind(a) == "scroll", isGiven(a["until"]) {
            return "can't be optional with until: optional skips a step whose target isn't there, and until scrolls to find "
                + "text that isn't there yet"
        }
        guard optionalKinds.contains(kind(a)) else {
            return "can't be optional: only an action aimed by target (click, move, scroll, type, select, set_value, focus, "
                + "perform, read) is skipped when nothing shows its target"
        }
        if a["target"] == nil || ["x", "y", "coordinate", "element"].contains(where: { a[$0] != nil }) {
            return "can't be optional without target: one by coordinates or element number always runs. Name what it "
                + "acts on by what it shows (target: \"Accept all\") to skip it when that isn't there"
        }
        return nil
    }

    /// An action skipped, not stopped at, when nothing shows its target: one with `optional: true` where that can
    /// go (`optionalProblem`). A saved macro's step too, whose keys weren't checked as it ran.
    nonisolated static func optionalStep(_ a: [String: Any]) -> Bool {
        a["optional"] as? Bool == true && optionalProblem(a) == nil
    }

    /// Whether step `a`, which failed with `error`, is skipped and the batch goes on: it's optional
    /// (`optionalStep`), and its target was `Missing` before any lookup of it found something (`found`: a miss
    /// after that, or anything else, is an error as ever: a refusal, a stop for the user's OK, several matches, one
    /// behind a dialog, a search that stopped early, or what went wrong once the target was found).
    nonisolated static func skipsOptional(_ a: [String: Any], _ error: Error, found: Bool) -> Bool {
        optionalStep(a) && !found && error is Missing
    }

    /// How far a scroll goes, in screenshot pixels (window points for a macro step): `scroll_x`/`scroll_y`
    /// (`dx`/`dy`), or Anthropic's `direction` with `amount` (steps of 100, 3 by default).
    nonisolated static func scrollDelta(_ a: [String: Any]) -> (dx: Double, dy: Double) {
        var dx = num(a["scroll_x"] ?? a["dx"]) ?? 0, dy = num(a["scroll_y"] ?? a["dy"]) ?? 0
        if let dir = a["direction"] as? String ?? a["scroll_direction"] as? String {
            let amt = (num(a["amount"] ?? a["scroll_amount"]) ?? 3) * 100
            switch dir { case "up": dy = -amt; case "down": dy = amt; case "left": dx = -amt; default: dx = amt }
        }
        return (dx, dy)
    }

    /// The one of `names` that `key` most likely meant, if any is close: one it's often written for (delta_y
    /// for scroll_y, menu_item for item), the same but for case and "_"/"-" (timeoutMs), the same first four
    /// letters (timeout, changed), or a typo or two (txt). Kinds of action too (clik, left_mouse_down).
    nonisolated static func closest(_ key: String, _ names: [String]) -> String? {
        let meant: [String: [String]] = [
            "target": ["text"], "query": ["text", "target"], "seconds": ["timeout_ms", "ms"], "wait": ["timeout_ms", "ms"],
            "timeout": ["timeout_ms", "ms"], "time": ["ms"], "delay": ["ms"], "milliseconds": ["ms"],
            "text": ["target"], "label": ["target"], "name": ["target"], "selector": ["target"], "into": ["target"],
            "id": ["element"], "field": ["fields", "target"],
            "coords": ["coordinate"], "position": ["coordinate"], "point": ["coordinate"], "location": ["coordinate"],
            "value": ["text"], "content": ["text"], "string": ["text"], "input": ["text"],
            "menuitem": ["item"], "menu": ["item"], "option": ["item"], "item": ["option"], "choice": ["option", "item"],
            "combo": ["keys"], "shortcut": ["keys"], "count": ["repeat"],
            "deltay": ["scroll_y"], "deltax": ["scroll_x"], "scroll": ["scroll_y"], "pixels": ["scroll_y"],
            "distance": ["scroll_y"], "dir": ["direction"], "clicks": ["amount"], "ticks": ["amount"], "steps": ["amount"],
            "address": ["url"], "link": ["url"], "href": ["url"], "uri": ["url"], "newtab": ["new_window"], "tab": ["new_window"],
            "application": ["app"], "bundleid": ["app"], "form": ["fields"], "inputs": ["fields"], "values": ["vars", "fields"],
            "variables": ["vars"], "args": ["vars"], "params": ["vars"], "enter": ["submit"], "pressenter": ["submit"],
            "replace": ["clear"], "overwrite": ["clear"],
            "action": ["name"], "leftmousedown": ["mouse_down"], "leftmouseup": ["mouse_up"], "visit": ["navigate"],
            "keycombo": ["keypress"],
        ]
        func plain(_ s: String) -> String { s.lowercased().filter { $0 != "_" && $0 != "-" } }
        let k = plain(key)
        if let m = meant[k]?.first(where: names.contains) { return m }
        if let n = names.first(where: { plain($0) == k }) { return n }
        if k.count >= 4, let n = names.first(where: { plain($0).commonPrefix(with: k).count >= 4 }) { return n }
        func distance(_ a: String, _ b: String) -> Int {  // edits from one to the other (Levenshtein)
            let b = Array(b)
            var row = Array(0...b.count)
            for (i, ca) in a.enumerated() {
                var prev = row[0]
                row[0] = i + 1
                for (j, cb) in b.enumerated() {
                    let cur = row[j + 1]
                    row[j + 1] = min(cur + 1, row[j] + 1, prev + (ca == cb ? 0 : 1))
                    prev = cur
                }
            }
            return row[b.count]
        }
        return names.map { ($0, distance(plain($0), k)) }.filter { $0.1 <= 2 && $0.1 < k.count }.min { $0.1 < $1.1 }?.0
    }

    /// The window as wait_for {change} compares it: the same capture size whatever the call's options.
    static func changeLook(_ t: Target) async throws -> Signature {
        Signature(try await plan(t, region: nil, Opts([:])).run().image)
    }

    /// How much of the window (a fraction of its signature's cells) has to look different for wait_for
    /// {change}: a page or list redrawn, a dialog. A caret, a spinner, a focus ring, a line of status text
    /// or a browser's loading signs (its tab spinner, Stop button, "Waiting for…" line) stay under it.
    nonisolated static let changeThreshold = 0.01

    nonisolated static func changed(from base: Signature, to now: Signature) -> Bool {
        guard let d = base.diff(now, outW: now.w, outH: now.h) else { return false }
        return d.fraction > changeThreshold
    }

    /// What ended a wait_for {change}: the window's picture, or a window (it closed, one opened, or the
    /// batch is on another window by now).
    enum ChangeSeen: Equatable { case picture, window }

    /// wait_for {change: true}: until the window looks different from the start of the batch (so a change
    /// that began during an earlier action counts), or a window opens or it closes; then, for a change in
    /// the picture, until it settles. Nothing in time is a note, not an error: the batch goes on.
    static func waitForChange(_ timeout: Double, _ run: Run) async throws {
        guard case .window(let w) = run.target else { throw HelperError("wait_for needs a window target") }
        guard let base = run.changeBase else {
            throw HelperError("wait_for: the window couldn't be captured when the batch began, so there's nothing to compare with")
        }
        let clock = { ProcessInfo.processInfo.systemUptime }
        let start = clock()
        var shotPlan: CapturePlan?, madeFor: PlanBasis?
        let seen = try await awaitChange(
            from: base.wid == w.id ? base.sig : nil, timeout: timeout,
            look: {
                // A new plan when something opens over the window or it moves (as for act's screenshot).
                let now = PlanBasis.of(run.target)
                if shotPlan == nil || now != madeFor {
                    (shotPlan, madeFor) = (try? await Handlers.plan(run.target, region: nil, Opts([:])), now)
                }
                let sig = (try? await shotPlan?.run()).map { Signature($0.image) }
                if Trace.on, let sig { Trace.log(["k": "change", "fraction": base.sig.diff(sig, outW: sig.w, outH: sig.h)?.fraction ?? 0]) }
                return sig
            },
            window: { Windows.info(w.id)?.onScreen != true || !newWindows(w, run).isEmpty },
            pause: { try await Run.pause(0.15) }, clock: clock)
        guard let seen else {
            notes.append("wait_for: no visible change within \(String(format: "%.1f", timeout)) s (a spinner or a line of "
                + "text doesn't count)")
            return
        }
        let after = String(format: "%.1f", seen.after)
        guard seen.seen == .picture else {
            if base.wid != w.id { return }  // the batch moved to a window it opened (and said so)
            notes.append(Windows.info(w.id)?.onScreen != true ? "the window closed after \(after) s" : "a new window opened")
            return
        }
        do {
            _ = try await settle(basis: { PlanBasis.of(run.target) }, makePlan: { try await Handlers.plan(run.target, region: nil, Opts([:])) },
                                 capture: { try await $0.run() }, pause: { try await Run.pause(0.15) })
        } catch let e as Cancelled { throw e } catch {}  // gone meanwhile: nothing left to settle
        notes.append("the window changed after \(after) s (settled at \(String(format: "%.1f", clock() - start)) s)")
    }

    /// `waitForChange`'s loop, apart from the screen (unit-tested): a look each `pause` until one differs from
    /// `base` by more than `changeThreshold` (no `base`: the batch is on another window, a change in itself),
    /// or `window` says one opened or closed. How long that took, or nil after `timeout` seconds.
    static func awaitChange(from base: Signature?, timeout: Double, look: () async throws -> Signature?,
                            window: () -> Bool, pause: () async throws -> Void,
                            clock: () -> Double) async throws -> (seen: ChangeSeen, after: Double)? {
        let start = clock()
        while true {
            guard let base, !window() else { return (.window, clock() - start) }
            if let now = try await look(), changed(from: base, to: now) { return (.picture, clock() - start) }
            if clock() - start >= timeout { return nil }
            try await pause()
        }
    }

    /// The app's windows that have appeared since the batch began and aren't in `w`'s picture: not a sheet
    /// within it, nor a tooltip or popover.
    static func newWindows(_ w: WinInfo, _ run: Run) -> [WinInfo] {
        appeared(Windows.all(onScreenOnly: true), over: Windows.info(w.id) ?? w, atStart: run.visibleBefore) {
            systemWindow($0, AX.window(pid: $0.pid, wid: $0.id))
        }
    }

    /// Of `wins`, `w`'s app's windows not on screen at `atStart` and not in `w`'s picture (a sheet within it,
    /// a tooltip, a popover), nor macOS's own shown in the app's name (`system`: the dictation orb, which
    /// can open when a text field takes the focus).
    nonisolated static func appeared(_ wins: [WinInfo], over w: WinInfo, atStart: Set<CGWindowID>,
                                     system: (WinInfo) -> Bool) -> [WinInfo] {
        wins.filter {
            $0.pid == w.pid && $0.layer == 0 && !atStart.contains($0.id) && $0.frame.width >= 200
                && $0.frame.height >= 120 && !w.frame.contains($0.frame) && !system($0)
        }
    }
}

extension AX {
    /// Pick `option` in a pop-up button, combo box or menu button through accessibility: its menu is
    /// opened (if its items aren't already readable) and the matching item pressed. Matches exactly,
    /// else by a unique prefix, else a unique substring. `check` sees the title matched before it's
    /// chosen (the policy's say on it). Returns the title picked. `menuLater`: this is the batch's last
    /// action, and the end of the batch looks for a menu left open as long as this would (`Handlers.marked`).
    /// A pop-up whose list opens apart from it (a web page's in Firefox, drawn in a window of its own) is read
    /// from that list (`dropdown`); `typeAhead`, the route keys to its window go by, lets one in a web page be
    /// picked by its first letters if pressing the item doesn't take (`typeAhead(_:_:among:_:)`). `click` posts a
    /// click on it as a click action does (whether one went out), for a web page's pop-up in Firefox whose press
    /// opens no list (`clicksOpen`).
    @MainActor static func choose(_ el: AXUIElement, _ option: String, menuLater: Bool = false, typeAhead keys: Route? = nil,
                                  click: (() async throws -> Bool)? = nil,
                                  check: (String) throws -> Void = { _ in }) async throws -> String {
        let role = value(el, kAXRoleAttribute) as? String ?? ""
        let want = menuKey(option)
        if let cur = value(el, kAXValueAttribute) as? String, menuKey(cur) == want { return cur }
        if role == "AXComboBox" {
            // Its options, if it shows them (a list it may have to drop down first).
            let options = await comboOptions(el)
            var pick = option
            if !options.isEmpty {
                var hits = options.filter { menuKey($0) == want }
                if hits.isEmpty { hits = options.filter { menuKey($0).hasPrefix(want) } }
                if hits.isEmpty { hits = options.filter { menuKey($0).contains(want) } }
                guard hits.count == 1 else {
                    let names = optionList(hits.isEmpty ? options : hits, near: option, quote: true)
                    throw HelperError(hits.isEmpty ? "no option \"\(option)\" (options: \(names)); to enter other text, type it"
                                                   : "\"\(option)\" matches several: \(names)")
                }
                pick = hits[0]
            } else if let pid = pidOf(el), Policy.level(pid) == .click {
                // With no options to match, this is typing the text in.
                throw Policy.refusal(pid, .click, doing: "setting a combo box's text")
            }
            try check(pick)
            guard write(el, kAXValueAttribute, pick as CFString) == .success else {
                throw HelperError("it didn't take the value \"\(pick)\"")
            }
            // Confirm, as Return would, so the app acts on the new value. Not in browsers: there a combo
            // box is often a search field, and confirming would submit it.
            var names: CFArray?
            AXUIElementCopyActionNames(el, &names)
            if let pid = pidOf(el), !Handlers.isBrowser(pid), (names as? [String] ?? []).contains(kAXConfirmAction) {
                act(el, kAXConfirmAction)
            }
            if options.isEmpty { Handlers.notes.append("couldn't read its options: set its text to \"\(pick)\"") }
            return pick
        }
        func menu() -> AXUIElement? {
            children(el).first { ["AXMenu", "AXList"].contains(value($0, kAXRoleAttribute) as? String ?? "") }
        }
        func items() -> [(AXUIElement, String)] {
            guard let m = menu() else { return [] }
            return children(m).compactMap { item in
                guard let t = (value(item, kAXTitleAttribute) as? String) ?? (value(item, kAXValueAttribute) as? String),
                      !t.isEmpty else { return nil }
                return (item, t)
            }
        }
        var list = items()
        var opened = false
        let pid = pidOf(el)
        let web = webArea(of: el) != nil
        // The app's own menu that opened for it, when its list isn't among its children: a web page's pop-up in
        // Firefox has its list drawn apart, in a window of its own, read as the open-menu note reads one.
        var dropdown: AXUIElement?
        var menuBefore = true  // a menu of the app was open before it was pressed (one is closed between actions)
        if list.isEmpty {
            var names: CFArray?
            AXUIElementCopyActionNames(el, &names)
            let acts = names as? [String] ?? []
            let open = acts.contains(kAXPressAction) ? kAXPressAction : kAXShowMenuAction
            guard acts.isEmpty || acts.contains(open) else { throw HelperError("it has no menu to choose from (\(role.dropFirst(2)))") }
            // A menu open already isn't this one's: not taken for its list, nor closed here.
            menuBefore = pid.map { openMenu(pid: $0) != nil } ?? true
            // Some apps open the menu before replying and only reply once it closes: don't wait on that.
            AXUIElementSetMessagingTimeout(el, 0.6)
            let err = act(el, open)
            AXUIElementSetMessagingTimeout(el, 0)
            guard err == .success || err == .cannotComplete else { throw HelperError("couldn't open its menu (\(err.rawValue))") }
            opened = true
            func look(_ tries: Int) async {
                for _ in 0..<tries {
                    await Input.ms(50)
                    list = items()
                    if !list.isEmpty { return }
                    if !menuBefore, let pid, let m = openMenu(pid: pid), dropdownOf(el, menu: m, pid: pid) {
                        let found = optionItems(m)
                        if !found.isEmpty {
                            (dropdown, list) = (m, found)
                            return
                        }
                    }
                }
            }
            // Firefox ignores the press of a page's pop-up in a window that hasn't had a click yet: its list is looked
            // for a shorter while, then a click opens it (once), and it's looked for as before.
            let gecko = pid.map { Windows.isGecko($0) } ?? false
            let mayClick = click != nil && web && gecko
            await look(mayClick ? 12 : 30)
            if mayClick, list.isEmpty {
                let menuNow = pid.map { openMenu(pid: $0) != nil } ?? true
                if clicksOpen(web: web, gecko: gecko, menuBefore: menuBefore, menuNow: menuNow, listed: false), let click,
                   try await click() {
                    await look(30)
                } else {
                    await look(18)
                }
            }
        }
        // The route keys go by to close a list that ignores accessibility's cancel (Escape), as the open-menu note's.
        let escape = keys ?? windowID(el).flatMap { Windows.info($0) }.flatMap { try? Handlers.route(.window($0), at: nil, foreground: false) }
        /// Nothing picked: what the press opened is closed, its own menu, or in a web page a menu of the app's that
        /// opened apart (Escape if accessibility's cancel doesn't take), so none is left open to take the user's typing.
        func close() async {
            if opened, let m = menu() { cleanup(m, kAXCancelAction) }
            if opened, !menuBefore, web || dropdown != nil, let pid, let m = openMenu(pid: pid) {
                _ = await Handlers.dismiss(dropdown ?? m, pid: pid, escape)
            }
        }
        guard !list.isEmpty else {
            await close()
            throw HelperError("couldn't read its options" + (web ? "; focus it and type the first letters of the option" : ""))
        }
        var hits = list.filter { menuKey($0.1) == want }
        if hits.isEmpty { hits = list.filter { menuKey($0.1).hasPrefix(want) } }
        if hits.isEmpty { hits = list.filter { menuKey($0.1).contains(want) } }
        guard hits.count == 1 else {
            await close()
            let names = optionList((hits.isEmpty ? list : hits).map(\.1), near: option, quote: true)
            throw HelperError(hits.isEmpty ? "no option \"\(option)\" (options: \(names))" : "\"\(option)\" matches several: \(names)")
        }
        do { try check(hits[0].1) } catch {
            await close()
            throw error
        }
        if dropdown != nil {
            // Its item pressed, the list should close and the pop-up show the choice. Else the list is closed (Escape
            // if need be) and, in a web page, the choice typed by its first letters.
            let (item, title) = hits[0]
            let pressed = act(item, kAXPressAction) == .success
            let took = pressed ? await shows(el, title, pid: pid) : false
            if !took {
                await close()
                if web, let keys, try await typeAhead(el, title, among: list.map(\.1), keys) { return title }
                throw HelperError("couldn't pick \"\(title)\" from its list (it's closed again)")
            }
        } else {
            guard act(hits[0].0, kAXPressAction) == .success else {
                await close()
                throw HelperError("couldn't pick \"\(hits[0].1)\" (disabled?)")
            }
        }
        // The item is chosen, but a menu opened through accessibility can stay open (taking the user's
        // typing): close it. As the batch's last action (`menuLater`), the end of the batch looks for one
        // as long and closes it with no note (`pickedFromMenu`), so in a native app it's looked for once
        // here. Not where `act` waits in full (a browser): its first frame there would come sooner.
        if opened, let pid = pidOf(el) {
            let full = windowID(el).flatMap { Windows.info($0) }.map { Handlers.waitsInFull(.window($0)) }
            let once = Handlers.looksOnce(menuLater: menuLater, waitsInFull: full)
            for _ in 0..<8 {  // it may still be on its way up
                if let m = openMenu(pid: pid) {
                    await Input.ms(80)
                    closeMenu(m)
                    break
                }
                if once { break }
                await Input.ms(50)
            }
            if menuLater { Handlers.pickedFromMenu(pid: pid) }
        }
        return hits[0].1
    }

    /// Whether a pop-up whose press opened no list (`listed`) gets a click to open it, posted as a click action posts
    /// one: Firefox (`gecko`) ignores the press of a web page's pop-up (`web`) in a window that hasn't had a click
    /// yet, and opens its list only for a click. Not with a menu of the app open, before the press (`menuBefore`: not
    /// its list) or since (`menuNow`: a click on the pop-up would close a list on its way up).
    nonisolated static func clicksOpen(web: Bool, gecko: Bool, menuBefore: Bool, menuNow: Bool, listed: Bool) -> Bool {
        web && gecko && !menuBefore && !menuNow && !listed
    }

    /// Whether menu `m`, open in app `pid` just after pop-up `el` was pressed, is its list: where a list of it
    /// opens (`dropdownFits`), by the menu's own frame or its window's.
    static func dropdownOf(_ el: AXUIElement, menu m: AXUIElement, pid: pid_t) -> Bool {
        let at = frame(el)
        return dropdownFits(menu: frame(m), control: at) || menuWindows(pid).contains { dropdownFits(menu: $0, control: at) }
    }

    /// Whether a menu at `menu` is where a pop-up at `control` opens its list: side by side with it across, and over
    /// it or just above or below it. Frames not known: no.
    nonisolated static func dropdownFits(menu: CGRect?, control: CGRect?) -> Bool {
        guard let m = menu, let c = control, m.width > 0, m.height > 0, c.width > 0, c.height > 0 else { return false }
        guard min(m.maxX, c.maxX) > max(m.minX, c.minX) else { return false }
        return max(m.minY - c.maxY, c.minY - m.maxY) <= 40
    }

    /// The options of list `m` with their titles: each item's title, else its value, else the first text in it,
    /// leaving out those with none (separators). `read` and `kids` read an element's text and children (for tests).
    static func optionItems(_ m: AXUIElement,
                            read: (AXUIElement, String) -> String? = { AX.value($0, $1) as? String },
                            kids: (AXUIElement) -> [AXUIElement] = { AX.children($0) }) -> [(AXUIElement, String)] {
        func some(_ s: String?) -> String? { s.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } }
        var out: [(AXUIElement, String)] = []
        for item in kids(m) {
            if let t = some(read(item, kAXTitleAttribute)) {
                out.append((item, t))
            } else if let t = some(read(item, kAXValueAttribute)) {
                out.append((item, t))
            } else if let t = kids(item).compactMap({ some(read($0, kAXValueAttribute)) }).first {
                out.append((item, t))
            }
        }
        return out
    }

    /// After an item of pop-up `el`'s list was pressed: whether the pop-up shows `title` now (0.6 s at most), or,
    /// where it doesn't say what it shows, whether its list (app `pid`'s open menu) has closed.
    @MainActor static func shows(_ el: AXUIElement, _ title: String, pid: pid_t?) async -> Bool {
        for _ in 0..<12 {
            await Input.ms(50)
            if let v = value(el, kAXValueAttribute) as? String {
                if menuKey(v) == menuKey(title) { return true }
            } else if pid.map({ openMenu(pid: $0) == nil }) ?? true {
                return true
            }
        }
        return false
    }

    /// Pick `title` in web page pop-up `el` (its list closed) by typing the first letters of it while it has the
    /// focus, as a person can: only letters that pick it and nothing else among `titles` (`typeAheadPrefix`), only
    /// where the policy allows keys, and only while the focus is on the pop-up itself (`canTypeAhead`, before each
    /// key: never into a text field). Keys go by route `r`. Whether the pop-up shows it then.
    @MainActor static func typeAhead(_ el: AXUIElement, _ title: String, among titles: [String], _ r: Route) async throws -> Bool {
        guard let pid = pidOf(el), Policy.level(pid) == .full, let letters = typeAheadPrefix(title, among: titles) else { return false }
        func ready() -> Bool {
            let f = focusedElement(pid: pid)
            return canTypeAhead(focusRole: f.flatMap { value($0, kAXRoleAttribute) as? String }, onControl: f.map { CFEqual($0, el) } ?? false)
        }
        if !ready() {
            write(el, kAXFocusedAttribute, kCFBooleanTrue)
            await Input.ms(60)
        }
        var typed = 0
        for ch in letters {
            guard ready() else {
                if typed > 0 { Handlers.notes.append("the focus left the pop-up while picking \"\(clip(title, 40))\": look at what it shows") }
                return false
            }
            if typed > 0 { await Input.sleep(Handlers.typist.between()) }
            try await Handlers.press([String(ch)], r)
            typed += 1
        }
        for _ in 0..<8 {
            await Input.ms(50)
            if let v = value(el, kAXValueAttribute) as? String, menuKey(v) == menuKey(title) { return true }
        }
        return false
    }

    /// The letters to type into a web page's pop-up to pick `title` among its options `titles`, whichever it shows
    /// now: the shortest start of it that no other option starts with (case aside), of letters and digits only,
    /// and not one letter again ("aa" goes through the options starting with "a" one at a time). Nil if none does.
    nonisolated static func typeAheadPrefix(_ title: String, among titles: [String]) -> String? {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let want = norm(title)
        var others = titles.map(norm)
        guard let i = others.firstIndex(of: want) else { return nil }
        others.remove(at: i)
        var prefix = ""
        for ch in want {
            guard ch.isASCII, ch.isLetter || ch.isNumber else { return nil }
            prefix.append(ch)
            if prefix.count > 1, Set(prefix).count == 1 { continue }
            if !others.contains(where: { $0.hasPrefix(prefix) }) { return prefix }
        }
        return nil
    }

    /// Whether a letter typed now goes to a web page's pop-up to pick from it: the focus is on the pop-up itself
    /// (`onControl`), a pop-up button (`focusRole`), not a text field or anything else that takes letters as text.
    nonisolated static func canTypeAhead(focusRole: String?, onControl: Bool) -> Bool {
        onControl && focusRole == "AXPopUpButton"
    }

    /// The title of the option `option` would choose, when it can be read without opening anything (for
    /// the confirm policy); else `option` itself.
    static func optionTitle(_ el: AXUIElement, _ option: String) -> String? {
        let want = menuKey(option)
        let titles = children(el).filter { value($0, kAXRoleAttribute) as? String == "AXMenu" }.flatMap { children($0) }
            .compactMap { value($0, kAXTitleAttribute) as? String }.filter { !$0.isEmpty }
        var hits = titles.filter { menuKey($0) == want }
        if hits.isEmpty { hits = titles.filter { menuKey($0).hasPrefix(want) } }
        if hits.isEmpty { hits = titles.filter { menuKey($0).contains(want) } }
        return hits.count == 1 ? hits[0] : option
    }

    /// What select picks from: a pop-up button, combo box or menu button.
    static func isChoosable(_ el: AXUIElement) -> Bool {
        ["AXPopUpButton", "AXComboBox", "AXMenuButton"].contains(value(el, kAXRoleAttribute) as? String ?? "")
    }

    /// What checked sets: a checkbox, radio button or switch.
    static func isCheckable(_ el: AXUIElement) -> Bool {
        ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"].contains(value(el, kAXRoleAttribute) as? String ?? "")
    }

    /// What a key of fill's object form may name: a text input, a pop-up or combo box, a checkbox or its kin.
    static func isFillable(_ el: AXUIElement) -> Bool {
        Handlers.fillableRoles.contains(value(el, kAXRoleAttribute) as? String ?? "")
    }

    /// The one control that `fits` which text `label` is the title of (`AXServesAsTitleForUIElements`), else
    /// the one the label element it's in is the title of (a web page's `<label>` holding the text). Nil when
    /// none or several do: only what the app says, never a guess by where things are. `role`, `serves` and
    /// `parent` read those of an element (there for tests).
    static func titled(by label: AXUIElement, _ fits: (AXUIElement) -> Bool,
                       role: (AXUIElement) -> String? = { AX.value($0, kAXRoleAttribute) as? String },
                       serves: (AXUIElement) -> [AXUIElement] = {
                           AX.value($0, kAXServesAsTitleForUIElementsAttribute) as? [AXUIElement] ?? []
                       },
                       parent: (AXUIElement) -> AXUIElement? = { AX.parent($0) }) -> AXUIElement? {
        var el = label
        for step in 0..<2 {
            let r = role(el) ?? ""
            guard r == "AXStaticText" || r == "AXGroup" else { return nil }
            let them = serves(el).filter(fits)
            if them.count == 1 { return them[0] }
            guard them.isEmpty, step == 0, r == "AXStaticText", let up = parent(el) else { return nil }
            el = up
        }
        return nil
    }

    /// A combo box's options: from its list, dropping it down for a moment if it has to.
    @MainActor static func comboOptions(_ el: AXUIElement) async -> [String] {
        func read() -> [String] {
            for k in children(el) where ["AXList", "AXTable", "AXScrollArea"].contains(value(k, kAXRoleAttribute) as? String ?? "") {
                var out: [String] = []
                func walk(_ e: AXUIElement, _ depth: Int) {
                    guard depth < 5, out.count < 200 else { return }
                    for c in children(e) {
                        let r = value(c, kAXRoleAttribute) as? String ?? ""
                        if r == "AXStaticText" || r == "AXTextField", let s = (value(c, kAXValueAttribute) as? String) ?? caption(c),
                           !s.isEmpty { out.append(s) } else { walk(c, depth + 1) }
                    }
                }
                walk(k, 0)
                if !out.isEmpty { return out }
            }
            return []
        }
        var found = read()
        if !found.isEmpty { return found }
        let expanded = value(el, kAXExpandedAttribute) as? Bool
        guard expanded == false, write(el, kAXExpandedAttribute, kCFBooleanTrue) == .success
        else { return [] }
        for _ in 0..<10 {
            await Input.ms(40)
            found = read()
            if !found.isEmpty { break }
        }
        cleanup(el, set: kAXExpandedAttribute, kCFBooleanFalse)  // even after a cancel
        return found
    }

    /// After a navigation: true once the window's web page says it has loaded (false on timeout). Pages
    /// that don't say (no AXLoaded) count as loaded; the batch's end settle covers them. The first look
    /// comes after `first` s, then every 0.1 s.
    @MainActor static func waitForPage(pid: pid_t, wid: CGWindowID, timeout: Double, first: Double = 0.4) async throws -> Bool {
        try await Run.pause(min(first, timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let win = window(pid: pid, wid: wid), let page = webArea(win) else { return true }
            if (value(page, "AXLoaded") as? Bool) != false, (value(page, "AXBusy") as? Bool) != true { return true }
            try await Run.pause(0.1)
        }
        return false
    }

    /// The address of the window's (first) web page, if it says.
    static func pageURL(pid: pid_t, wid: CGWindowID) -> String? {
        guard let win = window(pid: pid, wid: wid), let page = webArea(win) else { return nil }
        return address(page)
    }

    /// The address of web page `page`, if it says.
    static func address(_ page: AXUIElement) -> String? {
        guard let u = value(page, kAXURLAttribute) else { return nil }
        if CFGetTypeID(u) == CFURLGetTypeID() { return (u as! URL).absoluteString }
        return u as? String
    }

    /// What a browser's Reload button's label says of its page: loading when it reads Stop ("Stop", "Stop loading
    /// this page"), not loading when it reads Reload or Refresh ("Reload this page"), nil for any other label.
    nonisolated static func loadState(_ label: String) -> Bool? {
        let s = label.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "stop" || s.hasPrefix("stop loading") || s.hasPrefix("stop (") { return true }
        if s.hasPrefix("reload") || s.hasPrefix("refresh") { return false }
        return nil
    }

    /// The name of the element `vals` (its `attrs`) are of: its title, description or help, the first there is.
    nonisolated static func buttonLabel(_ vals: [AnyObject]) -> String? {
        for i in [2, 3, 12] where vals.count > i {
            if let s = vals[i] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }

    /// A browser window's Reload button (or its Stop button, while a page loads) and what it's in: the first button
    /// by such a label (`loadState`), breadth first through the window's own controls, never into a page, `visits`
    /// elements at most. `read` gives an element's `attrs` (for tests).
    static func reloadButton(in win: AXUIElement, visits: Int = 300,
                             read: (AXUIElement) -> [AnyObject]? = readAttrs) -> (button: AXUIElement, parent: AXUIElement?)? {
        var level: [(el: AXUIElement, parent: AXUIElement?)] = [(win, nil)]
        var seen = 0
        while !level.isEmpty {
            var next: [(el: AXUIElement, parent: AXUIElement?)] = []
            for (el, parent) in level {
                seen += 1
                guard seen <= visits else { return nil }
                guard let vals = read(el), vals.count > 5 else { continue }
                let role = vals[0] as? String
                if role == "AXWebArea" { continue }
                if role == "AXButton", let label = buttonLabel(vals), loadState(label) != nil { return (el, parent) }
                next += (vals[5] as? [AXUIElement] ?? []).map { ($0, el) }
            }
            level = next
        }
        return nil
    }

    /// Whether the page of the window `b` is in loads, by its Reload button (`loadState`): its label read again; once
    /// it's gone or says something else (Firefox shows a Stop button in place of its Reload button), the buttons
    /// beside it, and the one found is kept. Nil when that can't be told.
    static func loading(_ b: Handlers.ReloadButton, read: (AXUIElement) -> [AnyObject]? = readAttrs) -> Bool? {
        func state(_ el: AXUIElement) -> Bool? {
            guard let vals = read(el), vals.count > 5, vals[0] as? String == "AXButton", let label = buttonLabel(vals) else { return nil }
            return loadState(label)
        }
        if let s = state(b.button) { return s }
        guard let p = b.parent, let vals = read(p), vals.count > 5 else { return nil }
        for k in vals[5] as? [AXUIElement] ?? [] {
            if let s = state(k) {
                b.button = k
                return s
            }
        }
        return nil
    }

    /// The window's (first) web page, looked for breadth-first a few levels down.
    static func webArea(_ win: AXUIElement) -> AXUIElement? {
        var level = [win]
        for _ in 0..<12 {
            var next: [AXUIElement] = []
            for el in level {
                if (value(el, kAXRoleAttribute) as? String) == "AXWebArea" { return el }
                next += children(el)
            }
            if next.isEmpty || next.count > 400 { return nil }
            level = next
        }
        return nil
    }
}
