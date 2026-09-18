#!/usr/bin/env node
'use strict';

// Checks that editors/vscode's declared `engines.vscode` floor is >= every
// runtime dependency's own `engines.vscode` requirement (smash #5582).
// #5574 raised the floor by hand after it drifted silently across the
// vscode-languageclient 9->10 bump: the dependency started requiring
// ^1.91.0 while the extension still declared ^1.75.0, so a user on
// 1.75-1.90 could install it and it threw on activation. Nothing else in
// the tree checks this, so the drift is silent again the next time any
// dependency raises its own floor.
//
// Usage: node check-engines-floor.js [extensionDir]
// extensionDir defaults to this script's own parent directory.

const fs = require('fs');
const path = require('path');

const extensionDir = process.argv[2] || path.resolve(__dirname, '..');
const packageJsonPath = path.join(extensionDir, 'package.json');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// The MINIMUM version a range admits. Every `engines.vscode` value in this
// dependency tree is one of `^1.91.0`, `~1.75.0`, `>=1.80.0` or a bare
// `1.91.0` -- for all of those the minimum is exactly the leading `X.Y.Z`
// triplet, so a full semver-range parser is not needed here.
function minVersion(range) {
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(range);
  if (!m) {
    return null;
  }
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

function isBelow(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) {
      return a[i] < b[i];
    }
  }
  return false;
}

// Node's own `require.resolve(name + '/package.json')` goes through the
// package's `exports` map, and most of this tree (vscode-languageclient
// included) does not list `package.json` in it -- that throws
// ERR_PACKAGE_PATH_NOT_EXPORTED even though the file is right there on disk.
// This walks node_modules directories directly instead, the same directory
// climb Node's own resolver does before consulting `exports`, bounded by a
// fixed step count (Power of 10: no unbounded loop) that comfortably covers
// any real filesystem depth.
const maxResolveSteps = 64;

function resolvePackageJson(name, fromDir) {
  let dir = fromDir;
  for (let i = 0; i < maxResolveSteps; i++) {
    const candidate = path.join(dir, 'node_modules', name, 'package.json');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      return null;
    }
    dir = parent;
  }
  return null;
}

// Depth-first over each dependency's own `dependencies`, bounded by
// `visited` (one entry per resolved package.json path) so a cycle in the
// npm graph cannot loop forever.
function walk(name, fromDir, visited, findings) {
  const pkgJsonPath = resolvePackageJson(name, fromDir);
  if (!pkgJsonPath) {
    findings.missing.push(name);
    return;
  }
  if (visited.has(pkgJsonPath)) {
    return;
  }
  visited.add(pkgJsonPath);

  const pkg = readJson(pkgJsonPath);
  const required = pkg.engines && pkg.engines.vscode;
  if (required) {
    findings.checked.push({ name: pkg.name || name, version: pkg.version || '', requires: required });
  }

  const deps = pkg.dependencies || {};
  const nextFromDir = path.dirname(pkgJsonPath);
  for (const dep of Object.keys(deps)) {
    walk(dep, nextFromDir, visited, findings);
  }
}

function main() {
  const nodeModulesPath = path.join(extensionDir, 'node_modules');
  if (!fs.existsSync(nodeModulesPath)) {
    // A checkout that has never run `npm install` in editors/vscode is a
    // valid state -- no build step here installs it -- so this is a SKIP,
    // not a failure. It must still be loud: a silent exit 0 here would be
    // exactly the "quietly succeeds when it cannot run" shape this repo has
    // been bitten by before.
    console.log(
      `check-engines-floor: SKIP - ${nodeModulesPath} is absent (run \`npm install\` in editors/vscode first); cannot verify the engines.vscode floor against runtime dependencies`
    );
    process.exit(0);
    return;
  }

  const pkg = readJson(packageJsonPath);
  const floorRange = pkg.engines && pkg.engines.vscode;
  if (!floorRange) {
    console.error('check-engines-floor: package.json has no engines.vscode to check against');
    process.exit(1);
    return;
  }
  const floor = minVersion(floorRange);
  if (!floor) {
    console.error(`check-engines-floor: cannot parse engines.vscode "${floorRange}"`);
    process.exit(1);
    return;
  }

  const prodDeps = Object.keys(pkg.dependencies || {});
  const visited = new Set();
  const findings = { checked: [], missing: [] };
  for (const dep of prodDeps) {
    walk(dep, extensionDir, visited, findings);
  }

  if (findings.missing.length > 0) {
    console.error(`check-engines-floor: could not resolve: ${findings.missing.join(', ')} (run \`npm install\` in editors/vscode)`);
    process.exit(1);
    return;
  }

  let failed = false;
  for (const f of findings.checked) {
    const requiredMin = minVersion(f.requires);
    const exceeds = requiredMin !== null && isBelow(floor, requiredMin);
    console.log(`check-engines-floor: ${f.name}@${f.version} requires vscode ${f.requires} (floor ${floorRange}) - ${exceeds ? 'EXCEEDS FLOOR' : 'ok'}`);
    if (exceeds) {
      failed = true;
    }
  }

  if (failed) {
    console.error(`check-engines-floor: engines.vscode (${floorRange}) is below a runtime dependency's own requirement; raise it to match`);
    process.exit(1);
    return;
  }
}

main();
