import { WhopClient, WhopEnvironment } from "@whop/sdk";
import { z } from "zod";
import { ConfigurationError, requiredEnv } from "./env";
import { whopRequest } from "./whop";

export const clubChallenge = {
  id: "bridge-v1",
  title: "Make the scene yours",
  sceneId: "tears-of-steel-bridge",
  sceneTitle: "Tears of Steel: The Bridge",
  prompt: "Dub Thom or Celia in English. Share your performance, then give someone one helpful spoken tip.",
};

export const uploadRequest = z.object({
  requestId: z.uuid(),
  kind: z.enum(["video", "voice"]),
  byteSize: z.number().int().positive().max(25_000_000),
});
export const publishRequest = z.object({
  uploadId: z.string().min(1),
  caption: z.string().trim().max(300),
  replyToMessageId: z.string().startsWith("post_").nullable(),
});

export const clubFile = z.object({
  id: z.string().startsWith("file_"),
  content_type: z.string().nullable(),
  size: z.number().nullable(),
  upload_status: z.enum(["pending", "processing", "ready", "failed"]),
  removed_by_moderation: z.boolean(),
  url: z.url().nullable(),
  duration_seconds: z.number().nullable(),
});
export const uploadFile = clubFile.extend({ upload_url: z.url(), upload_headers: z.record(z.string(), z.string()) });
export const clubMessage = z.object({
  id: z.string().startsWith("post_"),
  channel_id: z.string(),
  author_user_id: z.string().startsWith("user_"),
  content: z.string().nullable(),
  created_at: z.iso.datetime({ offset: true }),
  replying_to_message_id: z.string().nullable(),
  attachments: z.array(clubFile),
});

export function clubClient(token: string): WhopClient {
  if (process.env.WHOP_SANDBOX !== "true") throw new ConfigurationError("Dub Clubs requires WHOP_SANDBOX=true for this demo");
  return new WhopClient({ token, environment: WhopEnvironment.Sandbox, apiVersionDate: "2026-11-13-1", maxRetries: 0, timeoutInSeconds: 10 });
}

export async function clubUserClient(userId: string): Promise<WhopClient> {
  const root = clubClient(requiredEnv("WHOP_CLUB_API_KEY"));
  const access = z.object({ token: z.string().min(20) }).parse(await whopRequest("clubs.token", () => root.accessTokens.create({
    account_id: requiredEnv("WHOP_CLUB_ACCOUNT_ID"), user_id: userId,
    scoped_actions: ["dms:read", "dms:message:manage"],
    expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
  })));
  return clubClient(access.token);
}

export type ClubPost = { id: string; authorId: string; authorName: string; caption: string; createdAt: string; replyToMessageId: string | null; kind: "video" | "voice"; mediaURL: string; durationSeconds: number | null };
export type ClubFeed = { name: string; challenge: typeof clubChallenge; viewerId: string; members: { id: string; displayName: string }[]; posts: ClubPost[] };

export function validClubMedia(kind: "video" | "voice", contentType: string | null): boolean {
  return kind === "video" ? contentType === "video/mp4" : contentType === "audio/mp4" || contentType === "audio/mp4a-latm" || contentType === "audio/x-m4a";
}
