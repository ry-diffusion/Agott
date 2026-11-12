import { describe, expect, it } from "vitest";

/**
 * The record format the Swift apps write (Shared/Sync/SyncCrypto.swift),
 * opened here with WebCrypto: proof that it is plain, standard crypto any
 * client can speak, and that the Worker never needs the key.
 *
 *   master  = PBKDF2-HMAC-SHA256(passphrase, salt, rounds) → 32 bytes
 *   seal    = HKDF-SHA256(master, salt "agott-sync", info "agott-sync-v1 seal")
 *   name    = HKDF-SHA256(master, salt "agott-sync", info "agott-sync-v1 name")
 *   id      = base64url(HMAC-SHA256(name, "routine/<uuid>")[0..24])
 *   data    = "v1." + base64url(nonce ‖ AES-256-GCM(seal, plaintext, aad "agott-sync-v1|" + id) ‖ tag)
 */
const enc = new TextEncoder();

function fromBase64URL(text: string): Uint8Array {
	const base64 = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
	return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function toBase64URL(bytes: Uint8Array): string {
	return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function subkey(master: Uint8Array, info: string): Promise<ArrayBuffer> {
	const key = await crypto.subtle.importKey("raw", master, "HKDF", false, ["deriveBits"]);
	return crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: enc.encode("agott-sync"), info: enc.encode(info) }, key, 256);
}

async function recordID(master: Uint8Array, name: string): Promise<string> {
	const key = await crypto.subtle.importKey("raw", await subkey(master, "agott-sync-v1 name"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	return toBase64URL(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(name))).slice(0, 24));
}

async function open(master: Uint8Array, sealed: string, id: string): Promise<string> {
	const combined = fromBase64URL(sealed.slice("v1.".length));
	const key = await crypto.subtle.importKey("raw", await subkey(master, "agott-sync-v1 seal"), "AES-GCM", false, ["decrypt"]);
	const plain = await crypto.subtle.decrypt(
		{ name: "AES-GCM", iv: combined.slice(0, 12), additionalData: enc.encode(`agott-sync-v1|${id}`) },
		key,
		combined.slice(12),
	);
	return new TextDecoder().decode(plain);
}

describe("record format", () => {
	// The vector SyncCryptoTests.opensTheSharedVector checks on the Swift side.
	const master = new Uint8Array(32).fill(7);
	const sealed = "v1.60wdyc6nKWxaCii3MG78nE0eDP4nY_Oq5zqpqxUGvyURXQ8hpUYX";

	it("names records as the apps do", async () => {
		expect(await recordID(master, "routine/ABC")).toBe("NWz5B724jr62hb3qwoI6n5mxrxh_elp4");
	});

	it("opens what the apps sealed", async () => {
		expect(await open(master, sealed, "NWz5B724jr62hb3qwoI6n5mxrxh_elp4")).toBe('{"hello":1}');
	});

	it("will not open it under another id or key", async () => {
		await expect(open(master, sealed, "another-id-0000000000")).rejects.toThrow();
		await expect(open(new Uint8Array(32).fill(8), sealed, "NWz5B724jr62hb3qwoI6n5mxrxh_elp4")).rejects.toThrow();
	});
});
