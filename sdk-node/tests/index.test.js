const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const childProcess = require('node:child_process');
const { listCredentials, getField, getKey, runWithSecrets } = require('../src/index');

describe('module exports', () => {
  it('exports listCredentials function', () => {
    assert.strictEqual(typeof listCredentials, 'function');
  });

  it('exports getField function', () => {
    assert.strictEqual(typeof getField, 'function');
  });

  it('exports getKey function', () => {
    assert.strictEqual(typeof getKey, 'function');
  });

  it('preserves multiple credentials and prefix in run arguments', () => {
    const originalExistsSync = fs.existsSync;
    const originalSpawnSync = childProcess.spawnSync;
    let invocation;
    fs.existsSync = () => true;
    childProcess.spawnSync = (cli, args, options) => {
      invocation = { cli, args, options };
      return { status: 0 };
    };

    try {
      const result = runWithSecrets(
        ['first', 'second'],
        ['node', 'script.js'],
        { prefix: 'KEYKEEPER_', verbose: true }
      );
      assert.strictEqual(result.status, 0);
      assert.deepStrictEqual(invocation, {
        cli: '/usr/local/bin/keykeeper',
        args: [
          'run',
          '-c', 'first',
          '-c', 'second',
          '--prefix', 'KEYKEEPER_',
          '--verbose',
          '--',
          'node', 'script.js',
        ],
        options: { stdio: 'inherit' },
      });
    } finally {
      fs.existsSync = originalExistsSync;
      childProcess.spawnSync = originalSpawnSync;
    }
  });
});

describe('caller reason', () => {
  // 授权窗上的「调用方留言」只有调用方写得出来。SDK 一直没有这个参数，
  // 所以每一个走 SDK 的请求在弹窗里都是一片空白，用户只看得到一个 bundle id。
  it('passes --reason through to the CLI when given', () => {
    const calls = [];
    const original = childProcess.spawnSync;
    childProcess.spawnSync = (cli, args) => { calls.push(args); return { status: 0 }; };
    try {
      runWithSecrets('neon-costs', ['echo', 'hi'], { reason: '跑一次对账脚本' });
      const args = calls[0];
      assert.ok(args.includes('--reason'));
      assert.strictEqual(args[args.indexOf('--reason') + 1], '跑一次对账脚本');
      assert.ok(args.indexOf('--reason') < args.indexOf('--'), '--reason 必须在 -- 之前，否则会被当成子命令的参数');

      runWithSecrets('neon-costs', ['echo', 'hi']);
      assert.ok(!calls[1].includes('--reason'), '没写就不写，不要替调用方编理由');
    } finally {
      childProcess.spawnSync = original;
    }
  });
});
