import { describe, expect, it } from "vitest";
import { newBackend } from "./test.helpers";

const post = (t: ReturnType<typeof newBackend>, body: unknown) =>
  t.fetch("/waitlist", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

const rows = (t: ReturnType<typeof newBackend>) => t.run(async (ctx) => await ctx.db.query("waitlist").collect());

describe("POST /waitlist", () => {
  it("stores one row per email, upgrades to founding, and never downgrades", async () => {
    const t = newBackend();
    const first = await post(t, { email: "  Fixture@Example.test ", language: "Korean", source: "hackathon" });
    expect(first.status).toBe(200);
    expect(first.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(await first.json()).toEqual({ ok: true, created: true });

    expect(await (await post(t, { email: "fixture@example.test", plan: "founding" })).json()).toEqual({ ok: true, created: false });
    await post(t, { email: "fixture@example.test", plan: "free" });

    expect(await rows(t)).toMatchObject([{ email: "fixture@example.test", plan: "founding", language: "Korean", source: "hackathon" }]);
  });

  it("rejects bad input and silently drops honeypot submissions", async () => {
    const t = newBackend();
    expect((await post(t, { email: "not-an-email" })).status).toBe(400);
    expect((await post(t, { email: "a@example.test", plan: "premium" })).status).toBe(400);
    expect((await t.fetch("/waitlist", { method: "POST", body: "{" })).status).toBe(400);
    expect((await post(t, { email: "bot@example.test", website: "https://spam.test" })).status).toBe(200);
    expect(await rows(t)).toEqual([]);
  });

  it("answers the CORS preflight", async () => {
    const response = await newBackend().fetch("/waitlist", { method: "OPTIONS" });
    expect(response.status).toBe(204);
    expect(response.headers.get("Access-Control-Allow-Methods")).toContain("POST");
  });
});
