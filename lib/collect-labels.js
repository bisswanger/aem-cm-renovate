#!/usr/bin/env node
//
// Collect every label name a Renovate config might apply to a PR/issue, so the
// caller can pre-create them in Gitea. Renovate's Gitea platform looks up label
// IDs by name (lib/modules/platform/gitea/index.js: lookupLabelByName) and
// silently drops any label it can't find — it does NOT create missing labels
// the way it does on GitHub/GitLab. A brand-new Gitea repo has zero labels, so
// without this, every "labels"/"addLabels" entry in the config is dropped and
// PRs always land with an empty labels array.
//
// Usage:
//   node collect-labels.js <renovate-config.json>
//
// Walks the whole config tree (top-level "labels" plus every packageRule's
// "labels"/"addLabels") and prints one unique label name per line.

const fs=require('fs');
const file=process.argv[2];
const cfg=JSON.parse(fs.readFileSync(file,'utf8'));

const names=new Set();
(function walk(node){
  if(Array.isArray(node)){ for(const v of node) walk(v); return; }
  if(node && typeof node==='object'){
    for(const [k,v] of Object.entries(node)){
      if((k==='labels'||k==='addLabels') && Array.isArray(v)){
        for(const l of v) if(typeof l==='string') names.add(l);
      } else walk(v);
    }
  }
})(cfg);

for(const n of names) process.stdout.write(n+'\n');
