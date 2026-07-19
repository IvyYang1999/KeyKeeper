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
