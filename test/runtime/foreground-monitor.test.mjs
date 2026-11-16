import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { ForegroundMonitor } from "./support/foreground-monitor.mjs";

test("observer loss rejects future requests without writing to a dead input pipe", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cua-foreground-test-"));
  const binary = path.join(directory, "observer");
  await fs.writeFile(binary, `#!${process.execPath}\nprocess.stdout.write('{"event":"ready"}\\n');\nsetTimeout(() => process.exit(1), 10);\n`, { mode: 0o700 });
  const observer = new ForegroundMonitor(binary);
  try {
    await observer.ready; await observer.exit;
    await assert.rejects(observer.snapshot(), /exited/);
    await assert.rejects(observer.close(), /Foreground monitor/);
  } finally { await fs.rm(directory, { recursive: true }); }
});

test("startup failure remains observable until cleanup without an unhandled rejection", async () => {
  const observer = new ForegroundMonitor(path.join(os.tmpdir(), `missing-cua-observer-${process.pid}`));
  await assert.rejects(observer.ready, /ENOENT/);
  await new Promise((resolve) => setImmediate(resolve));
  await assert.rejects(observer.snapshot(), /ENOENT/);
  await assert.rejects(observer.close());
});

test("closing returns the final activation sample instead of an earlier snapshot", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "cua-foreground-test-"));
  const binary = path.join(directory, "observer");
  await fs.writeFile(binary, `#!${process.execPath}
const r = require('node:readline').createInterface({ input: process.stdin });
process.stdout.write('{"event":"ready"}\\n');
r.on('line', line => {
  const q = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: q.id, state: { available: true, truncated: false, targetActivations: q.command === 'stop' ? 1 : 0 } }) + '\\n');
  if (q.command === 'stop') { r.close(); process.stdin.pause(); }
});\n`, { mode: 0o700 });
  const observer = new ForegroundMonitor(binary);
  try {
    assert.equal((await observer.snapshot()).targetActivations, 0);
    assert.equal((await observer.close()).targetActivations, 1);
  } finally { await fs.rm(directory, { recursive: true }); }
});
