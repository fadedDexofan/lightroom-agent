import { test } from "node:test";
import assert from "node:assert/strict";
import { McpSession } from "../lib/mcp.mjs";

test("progress notifications stay associated with the live request", async () => {
  const session = new McpSession();
  const sent = [];
  session.send = (message) => sent.push(message);
  const progress = [];
  const pending = session.rpc("tools/call", { name: "export_photos" }, 1000, {
    onProgress: (value) => progress.push(value),
  });

  session.onStdout(
    '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"unrelated","progress":9}}\n',
  );
  session.onStdout(
    '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"live-1","progress":1,"total":2}}\n',
  );
  session.onStdout('{"jsonrpc":"2.0","id":1,"result":{"exported":2}}\n');

  assert.deepEqual(await pending, { exported: 2 });
  assert.deepEqual(progress, [{ progressToken: "live-1", progress: 1, total: 2 }]);
  assert.deepEqual(sent[0].params._meta, { progressToken: "live-1" });
});

test("client cancel sends the request id and ignores a late result", async () => {
  const session = new McpSession();
  const sent = [];
  session.send = (message) => sent.push(message);
  const controller = new AbortController();
  const pending = session.rpc("tools/call", { name: "import_photos" }, 1000, { signal: controller.signal });
  const rejected = assert.rejects(pending, /cancelled/);

  controller.abort();
  await rejected;
  session.onStdout('{"jsonrpc":"2.0","id":1,"result":{"imported":1}}\n');

  assert.deepEqual(sent[1], {
    jsonrpc: "2.0",
    method: "notifications/cancelled",
    params: { requestId: 1, reason: "Live test cancellation" },
  });
  assert.equal(session.pending.size, 0);
});

test("a tool answer keeps every image block in order beside the envelope", async () => {
  const session = new McpSession();
  session.send = () => {};
  const pending = session.tool("get_photo_detail", { photo_ids: ["1"], regions: [] });
  const content = [
    { type: "text", text: '{"outcome":"done","data":{"regions":[{"image_index":1},{"image_index":2}]}}' },
    { type: "image", data: "AAA", mimeType: "image/jpeg" },
    { type: "image", data: "BBB", mimeType: "image/jpeg" },
  ];
  session.onStdout(`${JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content } })}\n`);

  const answer = await pending;
  assert.deepEqual(
    answer.images.map((image) => image.data),
    ["AAA", "BBB"],
  );
  assert.equal(answer.image.data, "AAA");
  assert.equal(answer.data.regions.length, 2);
});
