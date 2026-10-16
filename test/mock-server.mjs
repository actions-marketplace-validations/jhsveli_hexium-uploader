import http from "node:http";
import crypto from "node:crypto";

const PORT = Number(process.env.PORT || 8787);
const PART_SIZE = Number(process.env.PART_SIZE || 1000);
const EXPECT_MD5 = process.env.EXPECT_MD5 || null;

const state = new Map(); // uuid -> { expectedSize, parts: Map<number, Buffer> }

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  const path = url.pathname;

  // Part PUTs (no auth) -> store bytes, return a quoted ETag like S3.
  const partMatch = path.match(/^\/parts\/([^/]+)\/(\d+)$/);
  if (req.method === "PUT" && partMatch) {
    const [, uuid, num] = partMatch;
    const buf = await readBody(req);
    const entry = state.get(uuid);
    if (!entry) return json(res, 404, { detail: "unknown upload" });
    entry.parts.set(Number(num), buf);
    const etag = `"${crypto.createHash("md5").update(buf).digest("hex")}"`;
    console.log(`[mock] PUT part ${num}: ${buf.length} bytes etag=${etag}`);
    res.writeHead(200, { ETag: etag, "Content-Length": 0 });
    return res.end();
  }

  let body = {};
  if (req.method === "POST") {
    try {
      body = JSON.parse((await readBody(req)).toString() || "{}");
    } catch {
      return json(res, 400, { detail: "bad json" });
    }
  }

  if (path === "/api/experimental/usermedia/initiate-upload/") {
    if (req.method !== "POST") return json(res, 405, { detail: "method" });
    console.log(`[mock] initiate-upload body=${JSON.stringify(body)}`);
    const size = body.file_size_bytes ?? 0;
    const uuid = crypto.randomUUID();
    const upload_urls = [];
    let offset = 0;
    let partNumber = 1;
    while (offset < size) {
      const length = Math.min(PART_SIZE, size - offset);
      upload_urls.push({
        part_number: partNumber,
        offset,
        length,
        url: `http://127.0.0.1:${PORT}/parts/${uuid}/${partNumber}`,
      });
      offset += length;
      partNumber++;
    }
    state.set(uuid, { expectedSize: size, parts: new Map() });
    return json(res, 200, { user_media: { uuid }, upload_urls });
  }

  const finishMatch = path.match(/^\/api\/experimental\/usermedia\/([^/]+)\/finish-upload\/$/);
  if (req.method === "POST" && finishMatch) {
    const uuid = finishMatch[1];
    console.log(`[mock] finish-upload body=${JSON.stringify(body)}`);
    const entry = state.get(uuid);
    if (!entry) return json(res, 404, { detail: "unknown upload" });
    const parts = body.parts || [];
    const buf = Buffer.concat(
      [...parts].sort((a, b) => a.PartNumber - b.PartNumber).map((p) => entry.parts.get(p.PartNumber) || Buffer.alloc(0)),
    );
    const md5 = crypto.createHash("md5").update(buf).digest("hex");
    console.log(`[mock] reassembled ${buf.length}/${entry.expectedSize} bytes md5=${md5}`);
    if (buf.length !== entry.expectedSize) return json(res, 400, { detail: "size mismatch" });
    if (EXPECT_MD5 && md5 !== EXPECT_MD5) return json(res, 400, { detail: "md5 mismatch" });
    return json(res, 200, { uuid, status: "uploaded" });
  }

  const abortMatch = path.match(/^\/api\/experimental\/usermedia\/([^/]+)\/abort-upload\/$/);
  if (req.method === "POST" && abortMatch) {
    return json(res, 200, { status: "aborted" });
  }

  if (path === "/api/experimental/submission/submit/") {
    if (req.method !== "POST") return json(res, 405, { detail: "method" });
    console.log(`[mock] submit body=${JSON.stringify(body)}`);
    const missing = [];
    for (const k of ["author_name", "categories", "communities", "has_nsfw_content", "upload_uuid"]) {
      if (!(k in body)) missing.push(k);
    }
    if (missing.length) return json(res, 400, { detail: `missing fields: ${missing.join(",")}` });
    return json(res, 200, {
      package_version: {
        full_name: `${body.author_name}-MockMod`,
        version_number: "1.0.0",
      },
    });
  }

  return json(res, 404, { detail: `no route: ${req.method} ${path}` });
});

server.listen(PORT, "127.0.0.1", () => console.log(`[mock] listening on http://127.0.0.1:${PORT} part_size=${PART_SIZE}`));
