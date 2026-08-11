#!/usr/bin/env node
//
// Read JSON and print one value from it.
//
// Usage:
//   node json-get.js <source> <expr>
//     source   '-' to read from stdin, otherwise a file path
//     expr     a JS expression evaluated with the parsed value bound to `j`
//              (default: 'j')
//
// Examples:
//   curl ... | node json-get.js - 'j.sha1'      # token from a Gitea response
//   node json-get.js pulls-page-1.json 'j.length'

const fs=require('fs');
const source=process.argv[2] ?? '-';
const expr=process.argv[3] || 'j';
const raw=fs.readFileSync(source==='-'?0:source,'utf8');
const j=JSON.parse(raw);
const value=Function('j',`return (${expr});`)(j);
process.stdout.write(String(value));
