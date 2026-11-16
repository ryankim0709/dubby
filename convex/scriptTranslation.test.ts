import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { alice, newBackend } from "./test.helpers";

type OpenAiCall = { path: string; body: { model: string; store: boolean; input: string; text: unknown } };

const lines = [
  { speaker: "Synthetic Hero", seconds: 2.4, text: "You came back for me." },
  { speaker: "Synthetic Rival", seconds: 1.2, text: "Of course I did." },
  { seconds: 0.8, text: "Let's go." },
];
const body = (overrides: Record<string, unknown> = {}) => JSON.stringify({ sourceLocale: "en-US", targetLocale: "ko-KR", sceneTitle: "Synthetic scene", lines, ...overrides });
const post = (requestBody: string): RequestInit => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: requestBody });

/** Answers Responses API calls with the given model output and records each request body. */
function fakeOpenAI(outputText: string): OpenAiCall[] {
  const calls: OpenAiCall[] = [];
  vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname !== "api.openai.com") return new Response("not faked", { status: 500 });
    calls.push({ path: url.pathname, body: JSON.parse(String(init?.body ?? "{}")) });
    return Response.json({
      id: "resp_test",
      object: "response",
      created_at: 0,
      model: "gpt-6-luna-test",
      status: "completed",
      output: [{ type: "message", id: "msg_1", status: "completed", role: "assistant", content: [{ type: "output_text", text: outputText, annotations: [] }] }],
    });
  });
  return calls;
}

beforeEach(() => {
  vi.stubEnv("OPENAI_API_KEY", "test-openai-key");
  vi.spyOn(console, "log").mockImplementation(() => {});
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("script translation route", () => {
  it("answers 401 before any provider call when nobody is signed in", async () => {
    const calls = fakeOpenAI(JSON.stringify({ lines: ["하나", "둘", "셋"] }));
    const response = await newBackend().fetch("/scripts/translate", post(body()));
    expect(response.status).toBe(401);
    expect(calls).toEqual([]);
  });

  it("translates the whole section in one request, with speakers and lengths, and returns one line per line", async () => {
    const calls = fakeOpenAI(JSON.stringify({ lines: ["나를 데리러 돌아왔구나.", "당연하지.", "가자."] }));
    const response = await newBackend().withIdentity(alice).fetch("/scripts/translate", post(body()));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ locale: "ko-KR", lines: ["나를 데리러 돌아왔구나.", "당연하지.", "가자."] });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.path).toBe("/v1/responses");
    expect(calls[0]!.body).toMatchObject({ model: "gpt-6-luna", store: false, text: { format: { type: "json_schema", strict: true } } });
    expect(calls[0]!.body.input).toContain("Target language: ko-KR");
    expect(calls[0]!.body.input).toContain("1. [Synthetic Hero, 2.4 s] You came back for me.");
    expect(calls[0]!.body.input).toContain("3. [speaker unknown, 0.8 s] Let's go.");
  });

  it("rejects a translation that doesn't keep one line per line, since lines are paired with timings by position", async () => {
    fakeOpenAI(JSON.stringify({ lines: ["나를 데리러 돌아왔구나. 당연하지.", "가자."] }));
    const response = await newBackend().withIdentity(alice).fetch("/scripts/translate", post(body()));
    expect(response.status).toBe(502);
    expect(await response.json()).toMatchObject({ code: "provider_failed" });
  });

  it("refuses a translation into the scene's own language without spending credit", async () => {
    const calls = fakeOpenAI(JSON.stringify({ lines: [] }));
    const response = await newBackend().withIdentity(alice).fetch("/scripts/translate", post(body({ targetLocale: "en-US" })));
    expect(response.status).toBe(400);
    expect(calls).toEqual([]);
  });
});
