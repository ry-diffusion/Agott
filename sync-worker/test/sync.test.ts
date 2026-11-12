import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker, { type Env, type StoredRecord } from "../src/index";

const ALICE = "test-token-alice-0123456789abcdefghij";
const BRUNO = "test-token-bruno-0123456789abcdefghij";
const BASE = "https://sync.example";

function call(path: string, init: RequestInit & { token?: string | null } = {}) {
	const headers = new Headers(init.headers);
	const token = init.token === undefined ? ALICE : init.token;
	if (token) headers.set("authorization", `Bearer ${token}`);
	if (init.body) headers.set("content-type", "application/json");
	return SELF.fetch(`${BASE}${path}`, { ...init, headers });
}

const id = (n: number) => `record-${String(n).padStart(10, "0")}`;
const put = (key: string, data: string, base = 0, token?: string) =>
	call(`/v1/records/${key}`, { method: "PUT", body: JSON.stringify({ data, base }), token });

describe("auth", () => {
	it("answers health without a token", async () => {
		const response = await call("/v1/health", { token: null });
		expect(response.status).toBe(200);
		expect(await response.json()).toMatchObject({ ok: true, service: "agott-sync" });
	});

	it("refuses no token, a wrong one, and one too short to be configured", async () => {
		expect((await call("/v1/records", { token: null })).status).toBe(401);
		expect((await call("/v1/records", { token: "test-token-mallory-0123456789abcdefgh" })).status).toBe(401);
		expect((await call("/v1/records", { token: "short" })).status).toBe(401);
	});

	it("refuses everyone when no tokens are configured", async () => {
		const request = new Request(`${BASE}/v1/records`, { headers: { authorization: `Bearer ${ALICE}` } });
		const response = await worker.fetch(request, { ...(env as unknown as Env), AGOTT_TOKENS: "" });
		expect(response.status).toBe(401);
	});

	it("keeps each person's vault apart", async () => {
		await put(id(900), "v1.alice", 0, ALICE);
		const bruno = await (await call("/v1/records", { token: BRUNO })).json<{ records: StoredRecord[] }>();
		expect(bruno.records.find((record) => record.id === id(900))).toBeUndefined();
	});
});

describe("meta", () => {
	const meta = { kdf: "pbkdf2-sha256", salt: "c2FsdHNhbHRzYWx0c2FsdA", rounds: 600000, check: "v1.Y2hlY2s" };

	it("is set once by the first device", async () => {
		expect((await call("/v1/meta", { token: BRUNO })).status).toBe(404);
		expect((await call("/v1/meta", { method: "PUT", body: JSON.stringify(meta), token: BRUNO })).status).toBe(201);
		expect((await call("/v1/meta", { method: "PUT", body: JSON.stringify(meta), token: BRUNO })).status).toBe(200);
		const other = await call("/v1/meta", { method: "PUT", body: JSON.stringify({ ...meta, salt: "b3RoZXJzYWx0b3RoZXJzYWx0" }), token: BRUNO });
		expect(other.status).toBe(409);
		expect(await other.json()).toEqual(meta);
		expect(await (await call("/v1/meta", { token: BRUNO })).json()).toEqual(meta);
	});

	it("rejects weak or malformed parameters", async () => {
		expect((await call("/v1/meta", { method: "PUT", body: JSON.stringify({ ...meta, rounds: 1000 }) })).status).toBe(400);
		expect((await call("/v1/meta", { method: "PUT", body: JSON.stringify({ ...meta, salt: "<script>" }) })).status).toBe(400);
		expect((await call("/v1/meta", { method: "PUT", body: "not json" })).status).toBe(400);
	});
});

describe("records", () => {
	it("stores, versions and lists changes since a cursor", async () => {
		const first = await put(id(1), "v1.one");
		expect(first.status).toBe(200);
		const one = await first.json<StoredRecord>();
		expect(one).toMatchObject({ id: id(1), version: 1, data: "v1.one" });

		await put(id(2), "v1.two");
		const updated = await (await put(id(1), "v1.one-again", 1)).json<StoredRecord>();
		expect(updated.version).toBe(2);
		expect(updated.seq).toBeGreaterThan(one.seq);

		const since = await (await call(`/v1/records?since=${one.seq}`)).json<{ records: StoredRecord[]; cursor: number }>();
		expect(since.records.map((record) => record.id)).toEqual([id(2), id(1)]);
		expect(since.cursor).toBe(updated.seq);
	});

	it("hands back the current copy when a write is based on an old one", async () => {
		await put(id(3), "v1.mac");
		await put(id(3), "v1.watch", 1);
		const stale = await put(id(3), "v1.phone", 1);
		expect(stale.status).toBe(409);
		const body = await stale.json<{ current: StoredRecord }>();
		expect(body.current).toMatchObject({ data: "v1.watch", version: 2 });
		// A day already marked done elsewhere: the same id, created twice.
		expect((await put(id(3), "v1.again", 0)).status).toBe(409);
	});

	it("deletes as a tombstone other devices see", async () => {
		await put(id(4), "v1.routine");
		const gone = await call(`/v1/records/${id(4)}?base=1`, { method: "DELETE" });
		expect(gone.status).toBe(200);
		const list = await (await call("/v1/records")).json<{ records: StoredRecord[] }>();
		expect(list.records.find((record) => record.id === id(4))).toMatchObject({ data: null, version: 2 });
	});

	it("pages through many changes", async () => {
		for (let n = 100; n < 112; n++) await put(id(n), `v1.n${n}`, 0, BRUNO);
		let since = 0;
		const seen: string[] = [];
		for (;;) {
			const page = await (await call(`/v1/records?since=${since}&limit=5`, { token: BRUNO })).json<{ records: StoredRecord[]; cursor: number; more: boolean }>();
			seen.push(...page.records.map((record) => record.id));
			since = page.cursor;
			if (!page.more) break;
		}
		expect(seen.filter((key) => key.startsWith("record-00000001"))).toHaveLength(12);
	});

	it("checks ids, data and size", async () => {
		expect((await put("short", "v1.x")).status).toBe(400);
		expect((await put(id(5), "plain text with spaces")).status).toBe(400);
		expect((await put(id(5), "v1." + "a".repeat(70_000))).status).toBe(413);
		expect((await call(`/v1/records/${id(5)}`, { method: "PUT", body: "{" })).status).toBe(413);
		expect((await put(id(5), "v1.x", -1)).status).toBe(400);
	});

	it("wipes only when asked plainly", async () => {
		await put(id(6), "v1.x", 0, BRUNO);
		expect((await call("/v1/vault", { method: "DELETE", token: BRUNO })).status).toBe(400);
		const wiped = await call("/v1/vault", { method: "DELETE", token: BRUNO, headers: { "x-agott-confirm": "wipe" } });
		expect(wiped.status).toBe(204);
		const list = await (await call("/v1/records", { token: BRUNO })).json<{ records: StoredRecord[] }>();
		expect(list.records).toHaveLength(0);
		expect((await call("/v1/meta", { token: BRUNO })).status).toBe(404);
	});
});
