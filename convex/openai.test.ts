import OpenAI from "openai";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ConfigurationError } from "./lib/env";
import { createOpenAIClient, describeOpenAIFailure } from "./lib/openai";

let fetchSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  fetchSpy = vi.spyOn(globalThis, "fetch");
});
afterEach(() => {
  vi.unstubAllEnvs();
  fetchSpy.mockRestore();
});

describe("createOpenAIClient", () => {
  it("raises the configuration error without touching the network when the key is unset", () => {
    vi.stubEnv("OPENAI_API_KEY", "");
    expect(() => createOpenAIClient()).toThrow(ConfigurationError);
    expect(() => createOpenAIClient()).toThrow("OPENAI_API_KEY");
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("builds a bounded client when the key is set, still without a request", () => {
    vi.stubEnv("OPENAI_API_KEY", "sk-fixture-not-a-real-key");
    const client = createOpenAIClient();
    expect(client.maxRetries).toBe(2);
    expect(client.timeout).toBe(30_000);
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe("describeOpenAIFailure", () => {
  it("reports the status only, never the provider body", () => {
    const error = OpenAI.APIError.generate(429, { message: "secret echoed by the provider sk-fixture" }, "secret echoed by the provider", new Headers());
    expect(describeOpenAIFailure(error)).toEqual({ status: 429, message: "OpenAI request failed with status 429" });
  });

  it("describes a connection failure without a status and ignores other errors", () => {
    const connection = new OpenAI.APIConnectionError({ message: "socket hang up" });
    expect(describeOpenAIFailure(connection)).toEqual({ status: null, message: "OpenAI request failed: no response from the provider" });
    expect(describeOpenAIFailure(new Error("boom"))).toBeNull();
  });
});
