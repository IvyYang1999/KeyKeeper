const { execFile } = require('node:child_process');
const fs = require('node:fs');

function findCli() {
  const paths = [
    '/usr/local/bin/keykeeper',
    '/opt/homebrew/bin/keykeeper',
  ];
  for (const p of paths) {
    if (fs.existsSync(p)) return p;
  }
  throw new Error(
    'keykeeper CLI not found. Install KeyKeeper from https://github.com/IvyYang1999/KeyKeeper'
  );
}

function run(...args) {
  return new Promise((resolve, reject) => {
    const cli = findCli();
    execFile(cli, args, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(stderr.trim() || `keykeeper exited with code ${error.code}`));
        return;
      }
      resolve(stdout);
    });
  });
}

async function listCredentials() {
  const output = await run('list');
  if (output.includes('No credentials stored')) return [];
  return output
    .trim()
    .split('\n')
    .filter(line => line.includes(' | '))
    .map(line => line.split(' | ')[0].trim());
}

async function getField(credentialId, fieldName) {
  return run('get', credentialId, fieldName);
}

async function getKey(credentialId, fieldName) {
  return run('get', credentialId, fieldName);
}

function runWithSecrets(credentialIds, command, options = {}) {
  const { prefix = '', verbose = false } = options;
  if (typeof credentialIds === 'string') credentialIds = [credentialIds];

  const cli = findCli();
  const args = ['run'];
  for (const id of credentialIds) {
    args.push('-c', id);
  }
  if (prefix) args.push('--prefix', prefix);
  if (verbose) args.push('--verbose');
  args.push('--', ...command);

  const { spawnSync } = require('node:child_process');
  return spawnSync(cli, args, { stdio: 'inherit' });
}

module.exports = { listCredentials, getField, getKey, runWithSecrets };
