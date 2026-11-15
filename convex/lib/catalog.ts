import type { Doc, Id } from "../_generated/dataModel";
import type { QueryCtx } from "../_generated/server";

/** The newest revision of each line of a character, in dialogue order. */
export async function latestLines(ctx: QueryCtx, characterId: Id<"characters">): Promise<Doc<"referenceLines">[]> {
  const rows = await ctx.db
    .query("referenceLines")
    .withIndex("by_character", (q) => q.eq("characterId", characterId))
    .collect();
  const newest = new Map<string, Doc<"referenceLines">>();
  for (const row of rows) {
    const current = newest.get(row.lineKey);
    if (current === undefined || row.referenceVersion > current.referenceVersion) newest.set(row.lineKey, row);
  }
  return [...newest.values()].sort((a, b) => a.order - b.order);
}

export function lineView(line: Doc<"referenceLines">) {
  return {
    lineId: line._id,
    lineKey: line.lineKey,
    characterId: line.characterId,
    order: line.order,
    text: line.text,
    startSeconds: line.startSeconds,
    endSeconds: line.endSeconds,
    locale: line.locale,
    referenceVersion: line.referenceVersion,
  };
}
