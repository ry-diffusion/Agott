// The bridge between Agott on this Mac and the page in front. Agott sends a
// request through the native port (SFSafariApplication.dispatchMessage); this
// passes it to the content script of the active tab and sends the answer back
// with sendNativeMessage, which the extension's handler hands to Agott.

"use strict";

const APP = "br.com.zesmoi.Agott";
let port = null;

function connect() {
    try {
        port = browser.runtime.connectNative(APP);
    } catch (error) {
        port = null;
        setTimeout(connect, 5000);
        return;
    }
    port.onMessage.addListener((message) => { answer(message); });
    port.onDisconnect.addListener(() => {
        port = null;
        setTimeout(connect, 2000);
    });
}

connect();

async function answer(message) {
    // Safari hands over { name, userInfo } from dispatchMessage.
    const info = (message && (message.userInfo || message.message)) || message || {};
    if (!info.id || typeof info.request !== "string") return;
    let body;
    try {
        body = await run(JSON.parse(info.request));
    } catch (error) {
        body = { error: String((error && error.message) || error) };
    }
    try {
        await browser.runtime.sendNativeMessage(APP, { type: "reply", id: info.id, body: JSON.stringify(body) });
    } catch (error) {
        console.error("Agott: could not answer", error);
    }
}

async function run(request) {
    if (request.op === "ping") return { ok: true, version: browser.runtime.getManifest().version };
    const tabs = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    const tab = tabs && tabs[0];
    if (!tab || tab.id === undefined) return { error: "Safari has no page open.", unreachable: true };
    return toTab(tab.id, request);
}

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

/// A read is retried while a new page loads (and the script is put into a
/// page that was open before the extension was turned on); an action is sent
/// once, never twice.
async function toTab(tabId, request) {
    const reading = request.op === "snapshot";
    const deadline = Date.now() + 3000;
    let injected = false;
    let problem = "no answer";
    for (;;) {
        try {
            const reply = await browser.tabs.sendMessage(tabId, { agott: request }, { frameId: 0 });
            if (reply !== undefined && reply !== null) return reply;
        } catch (error) {
            problem = String((error && error.message) || error);
        }
        if (!reading) return { error: "The page did not answer (" + problem + "); it may have moved to another page.", lost: true };
        if (!injected) {
            injected = true;
            try {
                await browser.scripting.executeScript({ target: { tabId: tabId }, files: ["page-core.js", "content.js"] });
                continue;
            } catch (error) {
                problem = String((error && error.message) || error);
            }
        }
        if (Date.now() > deadline) return { error: "The page cannot be read (" + problem + ").", unreachable: true };
        await wait(150);
    }
}
