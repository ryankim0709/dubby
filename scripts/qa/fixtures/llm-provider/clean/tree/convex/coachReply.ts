import OpenAI from "openai";
const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
export async function reply(input: string) {
  return client.responses.create({ model: "gpt-5.5", input });
}
