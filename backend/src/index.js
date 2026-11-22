// Tessere — Cloudflare Worker: family sync (end-to-end encrypted payloads)
// and Apple Wallet pass signing. See README › Server.
import { handle } from "./api.js";

export default {
  async fetch(request, env) {
    return handle(request, env);
  },
};
