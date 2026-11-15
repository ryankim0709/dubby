import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./_generated/api";
import { type World, record, startWorld, upload } from "./test.helpers";

let world: World;
let attemptId: string;

beforeEach(async () => {
  vi.useFakeTimers();
  world = await startWorld();
  const { projectId } = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
  const storageId = await upload(world.t, "audio/wav", 100);
  attemptId = (await record(world.t, world.a, { projectId, lineId: world.line1, storageId })).attemptId;
});
afterEach(() => {
  vi.useRealTimers();
});

describe("GET /media/attempts/{attemptId}/audio", () => {
  it("streams the recording to its owner with its stored content type", async () => {
    const response = await world.a.fetch("/media/attempts/" + attemptId + "/audio");
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("audio/wav");
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array(100).fill(7));
  });

  it("serves byte ranges so playback can seek", async () => {
    const path = "/media/attempts/" + attemptId + "/audio";
    const middle = await world.a.fetch(path, { headers: { Range: "bytes=10-19" } });
    expect(middle.status).toBe(206);
    expect(middle.headers.get("Content-Range")).toBe("bytes 10-19/100");
    expect((await middle.arrayBuffer()).byteLength).toBe(10);
    const tail = await world.a.fetch(path, { headers: { Range: "bytes=-5" } });
    expect(tail.headers.get("Content-Range")).toBe("bytes 95-99/100");
    const openEnded = await world.a.fetch(path, { headers: { Range: "bytes=90-" } });
    expect(openEnded.headers.get("Content-Range")).toBe("bytes 90-99/100");
    expect((await world.a.fetch(path, { headers: { Range: "bytes=500-600" } })).status).toBe(416);
  });

  it("answers 404 to another user, exactly as for a missing recording", async () => {
    const other = await world.b.fetch("/media/attempts/" + attemptId + "/audio");
    const missing = await world.b.fetch("/media/attempts/not-an-id/audio");
    expect(other.status).toBe(404);
    expect(missing.status).toBe(404);
    expect(await other.json()).toEqual(await missing.json());
  });

  it("answers 401 without an identity and 404 for other paths", async () => {
    expect((await world.t.fetch("/media/attempts/" + attemptId + "/audio")).status).toBe(401);
    expect((await world.a.fetch("/media/attempts/" + attemptId)).status).toBe(404);
  });
});
