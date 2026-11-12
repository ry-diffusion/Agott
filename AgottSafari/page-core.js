// Agott's page snapshot, the part with no DOM in it: turns the elements the
// content script found into the short list the model reads, the same way
// AXCompactor does for apps (Agott/Senses/AXTree.swift). Kept apart so the
// unit tests can run it in JavaScriptCore.
//
// In: entries in reading order, each one of
//   { kind: "control", ref, role, name, value, placeholder, flags, visible, full }
//   { kind: "text" | "heading" | "image", ref, name, visible }
//   { kind: "section", name }   …   { kind: "end" }
// Out: { items: [{ ref, role, label, value, placeholder, flags, section, header, full }], offscreen, truncated }

(function (root) {
    "use strict";

    const OPTIONS = { maxItems: 220, maxCharacters: 7000, labelLength: 70, valueLength: 120, textLength: 160 };

    /// One line, whitespace folded, cut at `limit` with an ellipsis. Icon-font
    /// glyphs (private use) say nothing, so they read as nothing.
    function clean(text, limit) {
        if (text === null || text === undefined) return null;
        const flat = String(text).replace(/\s+/g, " ").trim();
        if (!flat) return null;
        if (/^[-\s]+$/.test(flat)) return null;
        if (flat.length <= limit) return flat;
        return flat.slice(0, limit - 1) + "…";
    }

    /// The line the model sees, the same as AXItem.line in Swift (the id is
    /// the ref here; Swift puts its own).
    function line(item, id) {
        if (item.header) return "— " + item.label;
        const parts = ["[" + (id === undefined ? item.ref : id) + "]"];
        if (item.role !== "text") parts.push(item.role);
        if (item.label) parts.push("\"" + item.label + "\"");
        if (item.value !== null && item.value !== undefined && item.value !== item.label) parts.push("=\"" + item.value + "\"");
        else if (item.placeholder) parts.push("(" + item.placeholder + ")");
        return parts.concat(item.flags || []).join(" ");
    }

    const isText = (item) => item.role === "text" || item.role === "heading";
    const isFocused = (item) => (item.flags || []).indexOf("focused") >= 0;

    function compact(entries, given) {
        const options = Object.assign({}, OPTIONS, given || {});
        let items = [];
        let offscreen = 0;
        const sections = [];
        const section = () => (sections.length ? sections[sections.length - 1] : "");

        for (const entry of entries) {
            if (entry.kind === "section") {
                const title = clean(entry.name, options.labelLength) || "";
                sections.push(title || section());
                if (title) items.push({ ref: 0, role: "section", label: title, flags: [], section: section(), header: true });
                continue;
            }
            if (entry.kind === "end") {
                sections.pop();
                continue;
            }
            const flags = (entry.flags || []).slice();
            if (entry.visible === false && flags.indexOf("focused") < 0) {
                if (entry.kind === "control" || entry.kind === "text") offscreen += 1;
                continue;
            }

            if (entry.kind === "text" || entry.kind === "heading") {
                const text = clean(entry.name, options.textLength);
                if (!text) continue;
                const last = items[items.length - 1];
                // The same words twice in a row (a label and then its field's
                // name, a caption repeated) are said once.
                if (last && !last.header && last.label === text) continue;
                items.push({ ref: entry.ref || 0, role: entry.kind, label: text, flags: flags, section: section() });
                continue;
            }

            if (entry.kind === "image") {
                const text = clean(entry.name, options.labelLength);
                if (!text) continue;
                items.push({ ref: entry.ref || 0, role: "image", label: text, flags: flags, section: section() });
                continue;
            }

            // A control.
            const label = clean(entry.name, options.labelLength) || "";
            const raw = entry.value === null || entry.value === undefined ? null : String(entry.value);
            let value = null;
            let full = null;
            if (raw !== null) {
                if (entry.role === "textarea") {
                    const shown = clean(raw, options.valueLength);
                    value = shown && raw.length > options.valueLength ? shown + " (" + raw.length + " characters)" : shown;
                } else {
                    value = clean(raw, options.valueLength);
                }
                if (raw.length > options.valueLength) full = raw.slice(0, 4000);
            }
            if (entry.full) full = String(entry.full).slice(0, 4000);
            const item = {
                ref: entry.ref, role: entry.role, label: label, value: value,
                placeholder: clean(entry.placeholder, options.labelLength), flags: flags, section: section(),
            };
            if (full) item.full = full;
            // Text just before a control that says the same (its <label>) goes.
            const last = items[items.length - 1];
            if (label && last && last.role === "text" && last.label === label) items.pop();
            items.push(item);
        }

        // Section lines with nothing of their own under them.
        items = items.filter((item, index) => {
            if (!item.header) return true;
            const next = items[index + 1];
            return !!next && !next.header && next.section === item.label;
        });

        // The cap: plain text goes first, from the end, then controls; the
        // focused element never.
        let truncated = 0;
        let total = items.reduce((sum, item) => sum + line(item).length + 1, 0);
        while (items.length > options.maxItems || total > options.maxCharacters) {
            let victim = -1;
            for (let index = items.length - 1; index >= 0; index -= 1) {
                if (isText(items[index]) && !isFocused(items[index])) { victim = index; break; }
            }
            if (victim < 0) {
                for (let index = items.length - 1; index >= 0; index -= 1) {
                    if (!isFocused(items[index])) { victim = index; break; }
                }
            }
            if (victim < 0) break;
            total -= line(items[victim]).length + 1;
            items.splice(victim, 1);
            truncated += 1;
        }
        return { items: items, offscreen: offscreen, truncated: truncated };
    }

    root.AgottPageCore = { OPTIONS: OPTIONS, clean: clean, line: line, compact: compact };
})(typeof globalThis !== "undefined" ? globalThis : this);
