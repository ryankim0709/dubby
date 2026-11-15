import { httpRouter } from "convex/server";
import { registerTutoringRoutes } from "./tutoringHttp";

// The coach and tutoring routes live in tutoringHttp.ts; other route groups register here beside them.
const http = httpRouter();
registerTutoringRoutes(http);

export default http;
