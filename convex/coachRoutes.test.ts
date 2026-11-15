import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { alice, grantCoachPremium, newBackend } from "./test.helpers";

const sessionBody = JSON.stringify({ characterId: "anakin", language: "es" });
const replyBody = JSON.stringify({ characterId: "anakin", languageName: "Spanish", turns: [{ role: "learner", text: "Hola" }] });
const post = (body: string): RequestInit => ({ method: "POST", headers: { "Content-Type": "application/json" }, body });

let fetchSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  fetchSpy = vi.spyOn(globalThis, "fetch");
  for (const name of ["OPENAI_API_KEY", "LIVEAVATAR_API_KEY"]) vi.stubEnv(name, "");
});
afterEach(() => {
  vi.unstubAllEnvs();
  fetchSpy.mockRestore();
});

describe("coach routes", () => {
  it("answers 401 before any provider call when there is no identity", async () => {
    const t = newBackend();
    for (const [path, body] of [["/coach/session-token", sessionBody], ["/coach/reply", replyBody]] as const) {
      const response = await t.fetch(path, post(body));
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: expect.any(String), code: "unauthenticated" });
    }
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("answers 401 for malformed bodies too, so unauthenticated callers learn nothing", async () => {
    const response = await newBackend().fetch("/coach/reply", post("not json"));
    expect(response.status).toBe(401);
  });

  it("answers 400 with an error body for bad requests", async () => {
    const t = newBackend().withIdentity(alice);
    const notJson = await t.fetch("/coach/reply", post("not json"));
    expect(notJson.status).toBe(400);
    expect(await notJson.json()).toEqual({ error: expect.any(String), code: "invalid_request" });
    expect((await t.fetch("/coach/session-token", post(JSON.stringify({ characterId: "anakin", language: "Spanish" })))).status).toBe(400);
    expect((await t.fetch("/coach/reply", post(JSON.stringify({ characterId: "anakin", languageName: "Spanish", turns: [{ role: "coach", text: "Hi" }] })))).status).toBe(400);
  });

  it("answers 404 for an unknown coach", async () => {
    const t = newBackend().withIdentity(alice);
    const unknown = (body: string) => body.replace("anakin", "nobody");
    expect((await t.fetch("/coach/session-token", post(unknown(sessionBody)))).status).toBe(404);
    const reply = await t.fetch("/coach/reply", post(unknown(replyBody)));
    expect(reply.status).toBe(404);
    expect(await reply.json()).toEqual({ error: "No coach named nobody", code: "not_found" });
  });

  it("answers 503 without calling a provider when its key is unset", async () => {
    const t = newBackend().withIdentity(alice);
    await grantCoachPremium(t, alice);
    for (const [path, body] of [["/coach/session-token", sessionBody], ["/coach/reply", replyBody]] as const) {
      const response = await t.fetch(path, post(body));
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: expect.stringContaining("isn't set"), code: "not_configured" });
    }
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("keeps the public routes open and spend-free", async () => {
    const t = newBackend();
    const characters = await t.fetch("/coach/characters");
    expect(characters.status).toBe(200);
    expect((await characters.json()).characters[0]).toEqual({ id: "anakin", name: "Anakin", summary: expect.any(String) });

    const health = await t.fetch("/health");
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ ok: true, service: "dubby-backend", schemaVersion: 1 });
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
