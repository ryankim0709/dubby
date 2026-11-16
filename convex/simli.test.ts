import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./_generated/api";
import { alice, grantCoachPremium, newBackend } from "./test.helpers";

const route = "/tutor/take-coach/avatar-session";
const request = { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ characterId: "anakin" }) };
let fetchSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  vi.stubEnv("SIMLI_API_KEY", "fixture-simli-key-do-not-use");
  vi.stubEnv("SIMLI_FACE_ID_ANAKIN", "fixture-anakin-face");
  vi.stubEnv("SIMLI_FACE_ID_OBI_WAN", "fixture-obi-wan-face");
  fetchSpy = vi.spyOn(globalThis, "fetch");
});

afterEach(() => {
  vi.unstubAllEnvs();
  fetchSpy.mockRestore();
});

describe("take coach Simli session", () => {
  it("rejects unsigned, unpaid, invalid and unknown-character requests before calling Simli", async () => {
    const backend = newBackend();
    expect((await backend.fetch(route, request)).status).toBe(401);
    const learner = backend.withIdentity(alice);
    await learner.mutation(api.users.ensure, {});
    expect((await learner.fetch(route, request)).status).toBe(403);
    expect((await learner.fetch(route, { ...request, body: "{" })).status).toBe(400);
    expect((await learner.fetch(route, { ...request, body: JSON.stringify({ characterId: "missing" }) })).status).toBe(404);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it.each([
    { characterId: "anakin", faceId: "fixture-anakin-face" },
    { characterId: "obi-wan", faceId: "fixture-obi-wan-face" },
  ])("uses $characterId's server-selected face and returns only an ephemeral token", async ({ characterId, faceId }) => {
    fetchSpy.mockResolvedValue(Response.json({ session_token: "fixture-session-token", extra: "ignored" }));
    const backend = newBackend();
    await grantCoachPremium(backend, alice);
    const response = await backend.withIdentity(alice).fetch(route, {
      ...request,
      body: JSON.stringify({ characterId, faceId: "untrusted-face", apiKey: "untrusted-key" }),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ sessionToken: "fixture-session-token" });
    expect(fetchSpy).toHaveBeenCalledExactlyOnceWith("https://api.simli.ai/compose/token", expect.objectContaining({
      headers: { "Content-Type": "application/json", "x-simli-api-key": "fixture-simli-key-do-not-use" },
      body: JSON.stringify({ faceId, handleSilence: true, maxSessionLength: 600, maxIdleTime: 180 }),
    }));
  });

  it("reports missing configuration without spending provider credit", async () => {
    vi.stubEnv("SIMLI_FACE_ID_ANAKIN", "");
    const backend = newBackend();
    await grantCoachPremium(backend, alice);
    const response = await backend.withIdentity(alice).fetch(route, request);
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ code: "not_configured" });
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("retries a transient provider failure, but redacts credentials and does not retry an invalid key", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("temporarily unavailable", { status: 503 }));
    fetchSpy.mockResolvedValueOnce(Response.json({ session_token: "fixture-session-token" }));
    const backend = newBackend();
    await grantCoachPremium(backend, alice);
    const learner = backend.withIdentity(alice);
    expect((await learner.fetch(route, request)).status).toBe(200);
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    fetchSpy.mockClear();
    fetchSpy.mockResolvedValue(Response.json({ detail: "Invalid key fixture-simli-key-do-not-use", session_token: "fixture-failed-token" }, { status: 401 }));
    const rejected = await learner.fetch(route, request);
    expect(rejected.status).toBe(502);
    const body = await rejected.text();
    expect(body).toContain("[redacted]");
    expect(body).not.toContain("fixture-simli-key-do-not-use");
    expect(body).not.toContain("fixture-failed-token");
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it.each([{ session_token: "" }, { token: "wrong-field" }])("refuses an unusable successful provider response", async (body) => {
    fetchSpy.mockResolvedValue(Response.json(body));
    const backend = newBackend();
    await grantCoachPremium(backend, alice);
    const response = await backend.withIdentity(alice).fetch(route, request);
    expect(response.status).toBe(502);
    expect(await response.json()).toMatchObject({ code: "provider_failed" });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });
});
