// Agott's hands and eyes inside a Safari page. Reads the page into a short
// list of what can be pressed or read (page-core.js compacts it) and acts on
// an element by the ref it was given: click, focus, set a value with real
// input and change events, pick an option, scroll, submit. Only answers the
// background script, which only asks when Agott on this Mac does.

(function () {
    "use strict";
    if (window.__agottPage) return;
    window.__agottPage = true;

    const core = globalThis.AgottPageCore;
    const LIMITS = { elements: 8000, milliseconds: 400 };

    // Refs: the same element keeps its number for as long as the page lives.
    const refs = new WeakMap();
    const elements = new Map();
    let nextRef = 1;

    function refOf(element) {
        let ref = refs.get(element);
        if (!ref) {
            ref = nextRef++;
            refs.set(element, ref);
        }
        elements.set(ref, new WeakRef(element));
        return ref;
    }

    function elementFor(ref) {
        const weak = elements.get(ref);
        const element = weak && weak.deref();
        return element && element.isConnected ? element : null;
    }

    // MARK: Reading

    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "IFRAME", "OBJECT", "EMBED", "CANVAS", "VIDEO", "AUDIO", "MAP"]);
    const BUTTON_INPUTS = new Set(["button", "submit", "reset", "image", "file"]);

    function attribute(element, name) {
        const value = element.getAttribute(name);
        return value === null ? null : value.trim();
    }

    function roleOf(element) {
        const aria = (attribute(element, "role") || "").split(/\s+/)[0].toLowerCase();
        switch (aria) {
        case "link": return "link";
        case "button": return "button";
        case "checkbox": return "checkbox";
        case "switch": return "switch";
        case "radio": return "radio";
        case "menuitem": case "menuitemcheckbox": case "menuitemradio": return "menuitem";
        case "tab": return "tab";
        case "option": return "option";
        case "combobox": return "combobox";
        case "textbox": return attribute(element, "aria-multiline") === "true" ? "textarea" : "field";
        case "searchbox": return "search";
        case "slider": case "spinbutton": return "slider";
        case "heading": return "heading";
        case "img": return "image";
        default: break;
        }
        const tag = element.tagName;
        if (tag === "A" && element.hasAttribute("href")) return "link";
        if (tag === "BUTTON" || tag === "SUMMARY") return "button";
        if (tag === "INPUT") {
            const type = (attribute(element, "type") || "text").toLowerCase();
            if (type === "hidden") return null;
            if (BUTTON_INPUTS.has(type)) return "button";
            if (type === "checkbox") return "checkbox";
            if (type === "radio") return "radio";
            if (type === "range") return "slider";
            if (type === "color") return "colorwell";
            if (type === "search") return "search";
            if (type === "password") return "password";
            return "field";
        }
        if (tag === "TEXTAREA") return "textarea";
        if (tag === "SELECT") return "select";
        if (/^H[1-6]$/.test(tag)) return "heading";
        if (tag === "IMG") return "image";
        if (element.isContentEditable && !(element.parentElement && element.parentElement.isContentEditable)) return "textarea";
        if (element.hasAttribute("onclick")) return "button";
        if (element.hasAttribute("tabindex") && element.tabIndex >= 0 && getComputedStyle(element).cursor === "pointer") return "button";
        return null;
    }

    const FIELDS = new Set(["field", "search", "password", "textarea", "combobox", "select", "slider", "colorwell"]);

    function textOf(element) {
        return (element.innerText !== undefined ? element.innerText : element.textContent) || "";
    }

    function labelledBy(element) {
        const ids = attribute(element, "aria-labelledby");
        if (!ids) return null;
        const words = ids.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map(textOf).join(" ");
        return words.trim() || null;
    }

    /// A <label>'s own words, without the text of the controls inside it
    /// (a select's options would otherwise become its name).
    function labelText(label) {
        let words = "";
        for (const node of label.childNodes) {
            if (node.nodeType === Node.TEXT_NODE) words += node.data;
            else if (node.nodeType === Node.ELEMENT_NODE && !/^(INPUT|SELECT|TEXTAREA|BUTTON)$/.test(node.tagName)) words += " " + labelText(node);
        }
        return words.replace(/\s+/g, " ").trim();
    }

    /// The element's name, roughly the way the accessibility tree names it.
    function nameOf(element, role) {
        const named = labelledBy(element) || attribute(element, "aria-label");
        if (named) return named;
        const tag = element.tagName;
        if (tag === "IMG" || (tag === "INPUT" && element.type === "image")) return attribute(element, "alt") || attribute(element, "title");
        if (FIELDS.has(role) || role === "checkbox" || role === "radio" || role === "switch") {
            const labels = element.labels ? Array.from(element.labels).map(labelText).join(" ").trim() : "";
            if (labels) return labels;
            if (role === "checkbox" || role === "radio" || role === "switch") {
                const own = textOf(element).trim();
                if (own) return own;
            }
            return attribute(element, "title") || attribute(element, "name");
        }
        if (tag === "INPUT") return element.value || attribute(element, "title");
        const own = textOf(element).trim();
        if (own) return own;
        // An icon button: the picture's words, then the tooltip.
        const picture = element.querySelector("img[alt], svg[aria-label], [aria-label]");
        if (picture) return attribute(picture, "alt") || attribute(picture, "aria-label");
        const title = element.querySelector("svg title");
        return attribute(element, "title") || (title ? title.textContent : null);
    }

    function valueOf(element, role) {
        const tag = element.tagName;
        const checked = attribute(element, "aria-checked");
        if (role === "checkbox" || role === "radio" || role === "switch") {
            if (tag === "INPUT") return element.indeterminate ? "mixed" : element.checked ? "on" : "off";
            if (checked) return checked === "true" ? "on" : checked === "mixed" ? "mixed" : "off";
            return null;
        }
        if (role === "password") return element.value ? "••••" : null;
        if (tag === "SELECT") {
            const chosen = Array.from(element.selectedOptions).map((option) => option.text.trim());
            return chosen.join(", ");
        }
        if (tag === "INPUT" || tag === "TEXTAREA") return element.value;
        if (role === "textarea" && element.isContentEditable) return textOf(element);
        if (role === "slider") return attribute(element, "aria-valuetext") || attribute(element, "aria-valuenow");
        if (role === "combobox" || role === "field") return attribute(element, "aria-valuetext") || null;
        return null;
    }

    function flagsOf(element, role) {
        const flags = [];
        if (element.disabled || attribute(element, "aria-disabled") === "true") flags.push("disabled");
        if (isFocused(element)) flags.push("focused");
        if (attribute(element, "aria-selected") === "true") flags.push("selected");
        const current = attribute(element, "aria-current");
        if (current && current !== "false") flags.push("current");
        const expanded = attribute(element, "aria-expanded");
        if (expanded === "true") flags.push("expanded");
        else if (expanded === "false") flags.push("collapsed");
        else if (element.tagName === "SUMMARY" && element.parentElement && element.parentElement.tagName === "DETAILS") {
            flags.push(element.parentElement.open ? "expanded" : "collapsed");
        }
        if (FIELDS.has(role)) {
            if (element.required || attribute(element, "aria-required") === "true") flags.push("required");
            if (element.readOnly || attribute(element, "aria-readonly") === "true") flags.push("readonly");
            if (attribute(element, "aria-invalid") === "true") flags.push("invalid");
        }
        return flags;
    }

    function isFocused(element) {
        let active = document.activeElement;
        while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
        return active === element;
    }

    function inView(rect) {
        if (!rect || (rect.width <= 0 && rect.height <= 0)) return false;
        return rect.bottom > 0 && rect.right > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth;
    }

    function hidden(element, style) {
        if (element.hasAttribute("inert") || attribute(element, "aria-hidden") === "true") return true;
        // display: contents has no box of its own, only its children do.
        if ((style || getComputedStyle(element)).display === "contents") return false;
        if (typeof element.checkVisibility === "function") {
            return !element.checkVisibility({ opacityProperty: true, visibilityProperty: true });
        }
        const computed = style || getComputedStyle(element);
        return computed.display === "none" || computed.visibility === "hidden";
    }

    /// Landmarks that get a section line, by their name.
    function sectionOf(element) {
        const role = (attribute(element, "role") || "").toLowerCase();
        const tag = element.tagName;
        const name = labelledBy(element) || attribute(element, "aria-label");
        if (tag === "DIALOG" || role === "dialog" || role === "alertdialog") return "Dialog" + (name ? ": " + name : "");
        if (tag === "NAV" || role === "navigation") return name || "Navigation";
        if (tag === "ASIDE" || role === "complementary") return name || "Sidebar";
        if ((tag === "FORM" || role === "form" || role === "region" || role === "search") && name) return name;
        if (role === "menu" || role === "menubar") return name || "Menu";
        return null;
    }

    /// An open modal dialog is all that can be used while it is up.
    function modal() {
        const open = Array.from(document.querySelectorAll("dialog[open], [aria-modal='true']"));
        return open.reverse().find((element) => {
            if (hidden(element)) return false;
            try { if (element.matches(":modal")) return true; } catch (error) { /* older engines */ }
            return attribute(element, "aria-modal") === "true";
        }) || null;
    }

    function children(node) {
        if (node.shadowRoot) return node.shadowRoot.childNodes;
        if (node.tagName === "SLOT") {
            const assigned = node.assignedNodes({ flatten: true });
            return assigned.length ? assigned : node.childNodes;
        }
        return node.childNodes;
    }

    function read() {
        const entries = [];
        const started = performance.now();
        let visited = 0;
        let incomplete = false;
        const run = { text: "", first: null, ref: 0 };

        function flush() {
            if (run.text.trim()) {
                let rect = null;
                try {
                    const range = document.createRange();
                    range.selectNodeContents(run.first);
                    rect = range.getBoundingClientRect();
                } catch (error) { /* detached */ }
                entries.push({ kind: "text", name: run.text, visible: inView(rect), ref: run.ref });
            }
            run.text = "";
            run.first = null;
        }

        function control(element, role, inHeading) {
            const entry = {
                kind: "control", ref: refOf(element), role: role, name: nameOf(element, role),
                value: valueOf(element, role), placeholder: attribute(element, "placeholder") || attribute(element, "aria-placeholder"),
                flags: flagsOf(element, role), visible: inView(element.getBoundingClientRect()),
            };
            if (inHeading) entry.flags.push("heading");
            if (element.tagName === "SELECT") {
                entry.full = "Options: " + Array.from(element.options).map((option) => option.text.trim()).filter(Boolean).join(" · ");
            }
            entries.push(entry);
        }

        function walk(node, inHeading) {
            for (const child of children(node)) {
                if (child.nodeType === Node.TEXT_NODE) {
                    if (!run.first) {
                        run.first = child;
                        run.ref = child.parentElement ? refOf(child.parentElement) : 0;
                    }
                    run.text += child.data;
                    continue;
                }
                if (child.nodeType !== Node.ELEMENT_NODE || SKIP.has(child.tagName)) continue;
                if (++visited > LIMITS.elements || performance.now() - started > LIMITS.milliseconds) {
                    incomplete = true;
                    return;
                }
                if (child.tagName === "BR") { run.text += " "; continue; }
                const style = getComputedStyle(child);
                if (hidden(child, style)) continue;

                const role = roleOf(child);
                if (role === "heading") {
                    flush();
                    // A heading that is a link reads as the link.
                    if (child.querySelector("a[href], button, [role='link'], [role='button']")) {
                        walk(child, true);
                        flush();
                    } else {
                        entries.push({ kind: "heading", ref: refOf(child), name: textOf(child), visible: inView(child.getBoundingClientRect()) });
                    }
                    continue;
                }
                if (role === "image") {
                    const words = nameOf(child, role);
                    if (words) {
                        flush();
                        entries.push({ kind: "image", ref: refOf(child), name: words, visible: inView(child.getBoundingClientRect()) });
                    }
                    continue;
                }
                if (role) {
                    flush();
                    control(child, role, inHeading);
                    continue;
                }

                const section = sectionOf(child);
                const display = style.display;
                const block = display !== "contents" && !display.startsWith("inline");
                if (section) {
                    flush();
                    entries.push({ kind: "section", name: section });
                    walk(child, inHeading);
                    flush();
                    entries.push({ kind: "end" });
                    continue;
                }
                // A table row reads as one line, its cells joined.
                if (display === "table-cell") {
                    if (run.text.trim()) run.text += " · ";
                    walk(child, inHeading);
                    continue;
                }
                if (block) flush();
                walk(child, inHeading);
                if (block) flush();
            }
        }

        const dialog = modal();
        if (dialog) {
            entries.push({ kind: "section", name: sectionOf(dialog) || "Dialog" });
            walk(dialog, false);
            flush();
            entries.push({ kind: "end" });
        } else if (document.body) {
            walk(document.body, false);
            flush();
        }

        const compacted = core.compact(entries);
        const scroller = document.scrollingElement || document.documentElement;
        const range = scroller.scrollHeight - window.innerHeight;
        return {
            url: location.href,
            title: document.title,
            items: compacted.items,
            offscreen: compacted.offscreen,
            truncated: compacted.truncated,
            incomplete: incomplete,
            scrolled: range > 8 ? Math.round(Math.min(1, Math.max(0, scroller.scrollTop / range)) * 100) : null,
        };
    }

    // MARK: Acting

    function point(element) {
        const rect = element.getBoundingClientRect();
        return { clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
    }

    function reveal(element) {
        element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    }

    /// The whole sequence a real click makes, so pages that listen for
    /// pointer or mouse events (menus, custom buttons) hear it too.
    function click(element, how) {
        reveal(element);
        const at = point(element);
        const base = Object.assign({ bubbles: true, cancelable: true, composed: true, view: window, button: how === "context" ? 2 : 0 }, at);
        const pointer = Object.assign({ pointerId: 1, pointerType: "mouse", isPrimary: true }, base);
        element.dispatchEvent(new PointerEvent("pointerover", pointer));
        element.dispatchEvent(new MouseEvent("mouseover", base));
        element.dispatchEvent(new PointerEvent("pointerdown", pointer));
        element.dispatchEvent(new MouseEvent("mousedown", base));
        if (typeof element.focus === "function") element.focus({ preventScroll: true });
        element.dispatchEvent(new PointerEvent("pointerup", pointer));
        element.dispatchEvent(new MouseEvent("mouseup", base));
        if (how === "context") {
            element.dispatchEvent(new MouseEvent("contextmenu", base));
            return;
        }
        if (typeof element.click === "function") element.click();
        else element.dispatchEvent(new MouseEvent("click", Object.assign({ detail: 1 }, base)));
        if (how === "double") element.dispatchEvent(new MouseEvent("dblclick", Object.assign({ detail: 2 }, base)));
    }

    function fire(element, type, data) {
        if (type === "input" || type === "beforeinput") {
            element.dispatchEvent(new InputEvent(type, { bubbles: true, cancelable: type === "beforeinput", composed: true, inputType: "insertText", data: data }));
        } else {
            element.dispatchEvent(new Event(type, { bubbles: true }));
        }
    }

    function choose(select, text) {
        const wanted = text.trim().toLowerCase();
        const options = Array.from(select.options);
        const match = options.find((option) => option.text.trim().toLowerCase() === wanted || option.value.toLowerCase() === wanted)
            || options.find((option) => option.text.toLowerCase().includes(wanted));
        if (!match) {
            return { error: "No option matches \"" + text + "\". The options are: " + options.map((option) => option.text.trim()).join(" · ") };
        }
        if (select.multiple) match.selected = true;
        else select.value = match.value;
        fire(select, "input");
        fire(select, "change");
        return { chose: match.text.trim() };
    }

    /// Sets a field's text through the value setter of its prototype (so a
    /// framework that tracks the value sees the change) and sends the events a
    /// person's typing sends.
    function setValue(element, text, replace) {
        if (element.tagName === "SELECT") return choose(element, text);
        if (element.disabled || element.readOnly) return { error: "That field cannot be changed." };
        reveal(element);
        element.focus({ preventScroll: true });
        if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
            const prototype = element instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, "value").set;
            fire(element, "beforeinput", text);
            setter.call(element, replace ? text : element.value + text);
            fire(element, "input", text);
            fire(element, "change");
            return {};
        }
        if (element.isContentEditable) {
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(element);
            if (!replace) range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
            if (!document.execCommand("insertText", false, text)) {
                if (replace) element.textContent = text;
                else element.append(text);
                fire(element, "input", text);
            }
            return {};
        }
        return { error: "That element is not a field." };
    }

    function submit(element) {
        const form = element && (element.form || element.closest("form"));
        if (form) {
            if (typeof form.requestSubmit === "function") form.requestSubmit();
            else form.submit();
            return;
        }
        const target = element || document.activeElement || document.body;
        for (const type of ["keydown", "keypress", "keyup"]) {
            target.dispatchEvent(new KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true }));
        }
    }

    function scroller(element) {
        for (let node = element; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (/(auto|scroll|overlay)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 4) return node;
        }
        return document.scrollingElement || document.documentElement;
    }

    function step(element, up) {
        if (element instanceof HTMLInputElement && (element.type === "range" || element.type === "number")) {
            if (up) element.stepUp(); else element.stepDown();
            fire(element, "input");
            fire(element, "change");
            return {};
        }
        const key = up ? "ArrowUp" : "ArrowDown";
        element.focus({ preventScroll: true });
        element.dispatchEvent(new KeyboardEvent("keydown", { key: key, code: key, bubbles: true, cancelable: true }));
        element.dispatchEvent(new KeyboardEvent("keyup", { key: key, code: key, bubbles: true, cancelable: true }));
        return {};
    }

    /// Waits until the page stops changing: no mutation for 150 ms, 1.5 s at most.
    function settle() {
        return new Promise((resolve) => {
            let quiet = null;
            let cap = null;
            const observer = new MutationObserver(() => {
                clearTimeout(quiet);
                quiet = setTimeout(done, 150);
            });
            function done() {
                observer.disconnect();
                clearTimeout(quiet);
                clearTimeout(cap);
                resolve();
            }
            observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            quiet = setTimeout(done, 150);
            cap = setTimeout(done, 1500);
        });
    }

    async function act(request) {
        const element = request.ref ? elementFor(request.ref) : null;
        if (request.ref && !element) return { error: "gone" };
        let answer = {};
        switch (request.action) {
        case "click": click(element); break;
        case "double": click(element, "double"); break;
        case "context": click(element, "context"); break;
        case "focus": reveal(element); element.focus({ preventScroll: true }); break;
        case "show": reveal(element); break;
        case "increment": answer = step(element, true); break;
        case "decrement": answer = step(element, false); break;
        case "type":
            answer = element ? setValue(element, request.text || "", !!request.replace) : { error: "No field given." };
            if (!answer.error && request.submit) submit(element);
            break;
        case "submit": submit(element); break;
        case "scroll": {
            const target = element ? scroller(element) : (document.scrollingElement || document.documentElement);
            target.scrollBy({ top: -(request.lines || 0) * 40, behavior: "instant" });
            break;
        }
        default: return { error: "Unknown action " + request.action };
        }
        if (answer.error) return answer;
        await settle();
        return Object.assign({ ok: true }, answer);
    }

    browser.runtime.onMessage.addListener((message) => {
        if (!message || !message.agott) return undefined;
        const request = message.agott;
        const work = request.op === "snapshot" ? Promise.resolve(read()) : act(request);
        return work.catch((error) => ({ error: String((error && error.message) || error) }));
    });
})();
