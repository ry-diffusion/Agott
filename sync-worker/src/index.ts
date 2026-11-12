import { DurableObject } from "cloudflare:workers";

/**
 * Agott sync: a blind, versioned store for one person's encrypted records.
 *
 * Devices seal every record (routines, days done, API keys) with a key
 * derived from a passphrase that never leaves them; this Worker only keeps
 * opaque ids and ciphertext, in one SQLite Durable Object per person, so
 * every write for that person is serialised and strongly consistent.
 *
 * Auth: `Authorization: Bearer <token>`. The tokens live in the
 * `AGOTT_TOKENS` secret (comma or newline separated, one per person, at least
 * 32 characters). A token picks its vault by its SHA-256, so tokens are never
 * stored, and no tokens configured means every request is refused.
 */

export interface Env {
	VAULT: DurableObjectNamespace<Vault>;
	AGOTT_TOKENS?: string;
}

/** Key-derivation parameters and a sealed known value, in the clear. */
export interface Meta {
	kdf: string;
	salt: string;
	rounds: number;
	check: string;
}

export type StoredRecord = {
	id: string;
	version: number;
	seq: number;
	/** Sealed bytes as the device sent them; null once deleted. */
	data: string | null;
	updated: number;
};

export type PutResult =
	| { ok: true; record: StoredRecord }
	| { ok: false; status: 409 | 507; error: string; current: StoredRecord | null };

const ID = /^[A-Za-z0-9_-]{16,64}$/;
const B64URL = /^[A-Za-z0-9._-]+$/;
const MAX_DATA = 64 * 1024;
const MAX_RECORDS = 20_000;
const PAGE = 500;
const MIN_TOKEN = 32;

export class Vault extends DurableObject<Env> {
	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.blockConcurrencyWhile(async () => {
			this.ctx.storage.sql.exec(`
				CREATE TABLE IF NOT EXISTS records (
					id TEXT PRIMARY KEY,
					version INTEGER NOT NULL,
					seq INTEGER NOT NULL,
					data TEXT,
					updated INTEGER NOT NULL
				);
				CREATE INDEX IF NOT EXISTS records_seq ON records (seq);
				CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
			`);
		});
	}

	getMeta(): Meta | null {
		const row = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'kdf'").toArray()[0];
		return row ? (JSON.parse(row.value) as Meta) : null;
	}

	/** Set once, by the first device; the same again is fine. */
	putMeta(meta: Meta): { created: boolean; meta: Meta } {
		const current = this.getMeta();
		if (current) return { created: false, meta: current };
		this.ctx.storage.sql.exec("INSERT INTO meta (key, value) VALUES ('kdf', ?)", JSON.stringify(meta));
		return { created: true, meta };
	}

	/** Everything changed after `since`, oldest first. */
	list(since: number, limit: number): { records: StoredRecord[]; cursor: number; more: boolean } {
		const rows = this.ctx.storage.sql
			.exec<StoredRecord>(
				"SELECT id, version, seq, data, updated FROM records WHERE seq > ? ORDER BY seq LIMIT ?",
				since,
				limit + 1,
			)
			.toArray();
		const more = rows.length > limit;
		const records = rows.slice(0, limit);
		return { records, cursor: records.at(-1)?.seq ?? since, more };
	}

	/**
	 * Writes a record if `base` is the version the device last saw (0 for a
	 * new one); otherwise hands back the current one. `data: null` deletes,
	 * leaving a tombstone other devices will see.
	 */
	put(id: string, data: string | null, base: number): PutResult {
		const sql = this.ctx.storage.sql;
		const current = sql
			.exec<StoredRecord>("SELECT id, version, seq, data, updated FROM records WHERE id = ?", id)
			.toArray()[0] ?? null;
		if ((current?.version ?? 0) !== base) {
			return { ok: false, status: 409, error: "changed elsewhere", current };
		}
		if (!current) {
			const count = sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM records").one().n;
			if (count >= MAX_RECORDS) return { ok: false, status: 507, error: "vault full", current: null };
		}
		const seq = sql.exec<{ next: number }>("SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM records").one().next;
		const record: StoredRecord = { id, version: base + 1, seq, data, updated: Date.now() };
		sql.exec(
			`INSERT INTO records (id, version, seq, data, updated) VALUES (?, ?, ?, ?, ?)
			 ON CONFLICT (id) DO UPDATE SET version = excluded.version, seq = excluded.seq,
			 data = excluded.data, updated = excluded.updated`,
			record.id,
			record.version,
			record.seq,
			record.data,
			record.updated,
		);
		return { ok: true, record };
	}

	/** Everything gone: for a new passphrase. */
	async wipe(): Promise<void> {
		await this.ctx.storage.deleteAll();
		this.ctx.storage.sql.exec(`
			CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, version INTEGER NOT NULL, seq INTEGER NOT NULL, data TEXT, updated INTEGER NOT NULL);
			CREATE INDEX IF NOT EXISTS records_seq ON records (seq);
			CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
		`);
	}
}

const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { "cache-control": "no-store" } });
const fail = (status: number, error: string) => json({ error }, status);

async function sha256(text: string): Promise<ArrayBuffer> {
	return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

const hex = (buffer: ArrayBuffer) => [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** The vault name for this request's token, or null if it is not one of ours. */
export async function vaultName(request: Request, env: Env): Promise<string | null> {
	const header = request.headers.get("authorization") ?? "";
	const match = /^Bearer\s+(\S+)$/i.exec(header);
	if (!match) return null;
	const given = await sha256(match[1]);
	const tokens = (env.AGOTT_TOKENS ?? "").split(/[\s,]+/).filter((token) => token.length >= MIN_TOKEN);
	let found = false;
	for (const token of tokens) {
		// Compare every one, in constant time, so timing says nothing.
		if (crypto.subtle.timingSafeEqual(given, await sha256(token))) found = true;
	}
	return found ? hex(given) : null;
}

async function readJSON<T>(request: Request): Promise<T | null> {
	const length = Number(request.headers.get("content-length") ?? 0);
	if (length > MAX_DATA * 2) return null;
	const text = await request.text();
	if (text.length > MAX_DATA * 2) return null;
	try {
		return JSON.parse(text) as T;
	} catch {
		return null;
	}
}

function validMeta(meta: Partial<Meta> | null): meta is Meta {
	return (
		!!meta &&
		typeof meta.kdf === "string" && meta.kdf.length <= 40 &&
		typeof meta.salt === "string" && meta.salt.length >= 16 && meta.salt.length <= 128 && B64URL.test(meta.salt) &&
		Number.isInteger(meta.rounds) && (meta.rounds as number) >= 100_000 && (meta.rounds as number) <= 10_000_000 &&
		typeof meta.check === "string" && meta.check.length <= 512 && B64URL.test(meta.check)
	);
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname.replace(/\/+$/, "");

		if (path === "/v1/health" && request.method === "GET") {
			return json({ ok: true, service: "agott-sync", version: 1 });
		}
		if (!path.startsWith("/v1/")) return fail(404, "not found");

		const name = await vaultName(request, env);
		if (!name) return fail(401, "unauthorized");
		const vault = env.VAULT.getByName(name);

		if (path === "/v1/meta") {
			if (request.method === "GET") {
				const meta = await vault.getMeta();
				return meta ? json(meta) : fail(404, "no vault yet");
			}
			if (request.method === "PUT") {
				const meta = await readJSON<Partial<Meta>>(request);
				if (!validMeta(meta)) return fail(400, "bad meta");
				const result = await vault.putMeta({ kdf: meta.kdf, salt: meta.salt, rounds: meta.rounds, check: meta.check });
				const same = JSON.stringify(result.meta) === JSON.stringify({ kdf: meta.kdf, salt: meta.salt, rounds: meta.rounds, check: meta.check });
				return json(result.meta, result.created ? 201 : same ? 200 : 409);
			}
			return fail(405, "method not allowed");
		}

		if (path === "/v1/records" && request.method === "GET") {
			const since = Math.max(0, Number.parseInt(url.searchParams.get("since") ?? "0", 10) || 0);
			const limit = Math.min(PAGE, Math.max(1, Number.parseInt(url.searchParams.get("limit") ?? `${PAGE}`, 10) || PAGE));
			return json(await vault.list(since, limit));
		}

		const recordMatch = /^\/v1\/records\/([^/]+)$/.exec(path);
		if (recordMatch) {
			const id = recordMatch[1];
			if (!ID.test(id)) return fail(400, "bad id");
			let data: string | null;
			let base: number;
			if (request.method === "PUT") {
				const body = await readJSON<{ data?: unknown; base?: unknown }>(request);
				if (!body) return fail(413, "too large or not JSON");
				if (typeof body.data !== "string" || !B64URL.test(body.data)) return fail(400, "bad data");
				if (body.data.length > MAX_DATA) return fail(413, "too large");
				data = body.data;
				base = Number(body.base ?? 0);
			} else if (request.method === "DELETE") {
				data = null;
				base = Number(url.searchParams.get("base") ?? NaN);
			} else {
				return fail(405, "method not allowed");
			}
			if (!Number.isInteger(base) || base < 0) return fail(400, "bad base");
			const result = await vault.put(id, data, base);
			return result.ok ? json(result.record) : json({ error: result.error, current: result.current }, result.status);
		}

		if (path === "/v1/vault" && request.method === "DELETE") {
			if (request.headers.get("x-agott-confirm") !== "wipe") return fail(400, "send X-Agott-Confirm: wipe");
			await vault.wipe();
			return new Response(null, { status: 204 });
		}

		return fail(404, "not found");
	},
} satisfies ExportedHandler<Env>;
