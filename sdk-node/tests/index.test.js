const { describe, it } = require('node:test');
const assert = require('node:assert');
const { listCredentials, getField, getKey } = require('../src/index');

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
});
