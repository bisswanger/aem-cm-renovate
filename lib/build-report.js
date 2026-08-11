#!/usr/bin/env node
//
// Build the Markdown reports for a Renovate run.
//
// Reads the paginated Gitea PR JSON (pulls-page-*.json) from PAGES_DIR and writes,
// into REPORTS_DIR, one <sanitized-branch>.md per PR (header + Changes table +
// changed files + the Renovate body incl. Release Notes) plus an index.md.
//
// Environment:
//   REPORTS_DIR                target directory for the generated .md files
//   REPO_DIR                   the local checkout (used to list changed files)
//   PAGES_DIR                  directory holding pulls-page-*.json
//   REPO_NAME                  repo name, used in the report heading
//   RENOVATE_PROBLEM_BRANCHES  comma/newline list of branches with artifact errors

const fs=require('fs'), path=require('path'), {execSync}=require('child_process');
const { REPORTS_DIR, REPO_DIR, PAGES_DIR, REPO_NAME } = process.env;
const problem=new Set((process.env.RENOVATE_PROBLEM_BRANCHES||'').split(/[\n,]/).map(s=>s.trim()).filter(Boolean));

let prs=[];
for(const f of fs.readdirSync(PAGES_DIR).filter(f=>/^pulls-page-\d+\.json$/.test(f))){
  try{const a=JSON.parse(fs.readFileSync(path.join(PAGES_DIR,f),'utf8')); if(Array.isArray(a)) prs.push(...a);}catch{}
}
prs=[...new Map(prs.map(p=>[p.number,p])).values()].sort((a,b)=>(a.head?.ref||'').localeCompare(b.head?.ref||''));

// Age comes from Renovate's structured report (RENOVATE_REPORT_*), not the PR body
// (where it is only a badge image). Keyed by branchName; a grouped branch has several
// upgrades, so we collect all ages and show lowest–highest. (Merge-confidence has no
// offline value — it's a rendered badge image — so it is not shown in the index.)
const ageByBranch={};
if(process.env.REPORT_JSON && fs.existsSync(process.env.REPORT_JSON)){
  try{
    const rep=JSON.parse(fs.readFileSync(process.env.REPORT_JSON,'utf8'));
    for(const repo of Object.values(rep.repositories||{}))
      for(const mgr of Object.values(repo.packageFiles||{}))
        for(const pf of mgr)
          for(const d of (pf.deps||[]))
            for(const u of (d.updates||[])){
              const b=u.branchName; if(!b) continue;
              if(typeof u.newVersionAgeInDays==='number') (ageByBranch[b]??=[]).push(u.newVersionAgeInDays);
            }
  }catch{}
}
const ageCell=b=>{ const a=ageByBranch[b]; if(!a||!a.length) return '—';
  const lo=Math.min(...a), hi=Math.max(...a); return lo===hi?`${lo}d`:`${lo}–${hi}d`; };

const sanitize=b=>b.replace(/[^A-Za-z0-9._-]+/g,'-');
const filesFor=branch=>{ try{
  return execSync(`git -C "${REPO_DIR}" show --pretty=format: --name-only ${branch}`,{encoding:'utf8'})
    .split('\n').map(s=>s.trim()).filter(Boolean);
}catch{ return []; } };

// Parse Renovate's PR body table into per-package {pkg, from, to}. The Change
// cell holds `old` → `new` (sometimes wrapped in a markdown link).
const parseUpdates=body=>{
  const out=[];
  for(const line of (body||'').split('\n')){
    if(!line.startsWith('|')||!line.includes('→')) continue; // → = U+2192
    const cells=line.split('|').map(s=>s.trim());
    if(cells.length<3) continue;
    const pkg=cells[1].replace(/^\[([^\]]+)\].*$/,'$1').trim(); // [name](url) -> name
    const m=cells[2].match(/`([^`]+)`\s*→\s*`([^`]+)`/);
    if(!pkg||!m) continue;
    out.push({pkg,from:m[1],to:m[2],type:verType(m[1],m[2])});
  }
  return out;
};
// Classify old→new as major / minor / patch (falls back to "update" for
// non-semver values such as AEM SDK timestamp versions or digests).
function verType(from,to){
  const seg=v=>String(v||'').replace(/^[^\d]*/,'').split(/[.+\-]/).map(x=>parseInt(x,10));
  const a=seg(from),b=seg(to);
  if(!a.length||isNaN(a[0])||isNaN(b[0])) return 'update';
  if((a[0]||0)!==(b[0]||0)) return 'major';
  if((a[1]||0)!==(b[1]||0)) return 'minor';
  if((a[2]||0)!==(b[2]||0)) return 'patch';
  return 'update';
}
const sev={major:3,minor:2,patch:1,update:0};
const typeLabel=ups=>[...new Set(ups.map(u=>u.type))].sort((x,y)=>sev[y]-sev[x]).join(', ')||'—';
const changeLabel=ups=> ups.length===1 ? `${ups[0].from} → ${ups[0].to}` : `${ups.length} packages`;
// Table sort rank by scope: patch → minor → major (→ other). For grouped branches
// the highest-severity type present decides the bucket (a branch with any major
// counts as major).
const scopeRank={patch:0,minor:1,major:2,update:3};
const primaryType=ups=>[...new Set(ups.map(u=>u.type))].sort((x,y)=>sev[y]-sev[x])[0]||'update';
const sortRank=ups=> scopeRank[primaryType(ups)] ?? 3;
// Renovate security/vulnerability fixes: the branch is named ...-vulnerability
// and/or the PR body references a vulnerability alert / CVE / GHSA advisory.
const isSecurity=(branch,body)=> /vulnerabilit/i.test(branch) || /vulnerabilit|CVE-\d|GHSA-/i.test(body||'');

// keep intro + updates table + Release Notes; drop Renovate's Configuration/footer boilerplate
const trimBody=body=>{
  let b=body||'';
  const cfg=b.search(/\n-{3}\s*\n+#{2,4}\s*Configuration/); if(cfg>=0) b=b.slice(0,cfg);
  const foot=b.search(/This PR has been generated by/i); if(foot>=0) b=b.slice(0,foot);
  return b.trim();
};

let updTotal=0, flagged=0, secCount=0; const index=[];
for(const pr of prs){
  const branch=pr.head?.ref||'unknown';
  const isProb=problem.has(branch); if(isProb) flagged++;
  const isSec=isSecurity(branch,pr.body); if(isSec) secCount++;
  // Labels Renovate set on the PR (Gitea returns them as {id,name,color,...}).
  const labels=(pr.labels||[]).map(l=>l&&l.name).filter(Boolean);
  const files=filesFor(branch);
  const ups=parseUpdates(pr.body);
  updTotal+=ups.length;
  const md=[
    `# ${pr.title}`,``,
    ...(isSec?[`> 🔒 **SECURITY UPDATE** — this branch fixes a known vulnerability; prioritize it.`,``]:[]),
    `- **Branch:** \`${branch}\``,
    `- **Base:** \`${pr.base?.ref||'?'}\``,
    ...(isSec?[`- 🔒 **Security:** yes (vulnerability fix)`]:[]),
    `- **Update type:** ${typeLabel(ups)}`,
    `- **Dependency updates:** ${ups.length}`,
    ...(isProb?[`- ⚠ **Artifact/lockfile problem** — see \`.renovate-tmp/gitea-run.log\``]:[]),
    ``,`## Changes`,
    ...(ups.length?[
      `| Package | Type | From | To |`,`|---|---|---|---|`,
      ...ups.map(u=>`| \`${u.pkg}\` | ${u.type} | \`${u.from}\` | \`${u.to}\` |`)
    ]:['_(no parsable version changes)_']),
    ``,`## Changed files`,
    ...(files.length?files.map(f=>`- \`${f}\``):['- _(none detected)_']),
    ``,`---`,``,
    trimBody(pr.body)||'_(no PR body)_',``
  ].join('\n');
  const file=sanitize(branch)+'.md';
  fs.writeFileSync(path.join(REPORTS_DIR,file),md);
  index.push({branch,title:pr.title||branch,type:typeLabel(ups),change:changeLabel(ups),rank:sortRank(ups),labels,isProb,isSec,file});
}
// escape a value for a Markdown table cell / link text
const mdCell=s=>String(s||'').replace(/\|/g,'\\|');
const mdText=s=>mdCell(s).replace(/[\[\]]/g,'\\$&');
// Sort: security first, then by scope (minor → patch → major), then by branch name.
index.sort((a,b)=> (b.isSec - a.isSec) || (a.rank - b.rank) || a.branch.localeCompare(b.branch));
const summary=`**${prs.length}** branches · **${updTotal}** dependency updates`
  +(secCount?` · **🔒 ${secCount} security**`:'')
  +(flagged?` · **${flagged}** with artifact/lockfile problems`:'');
const idx=[
  `# Renovate report — ${REPO_NAME}`,``,
  `Generated: ${new Date().toISOString()}`,``,
  summary,``,
  `| Title | Branch | Type | Change | Age | Labels | Notes |`,`|---|---|---|---|---|---|---|`,
  ...index.map(e=>{
    const notes=[e.isSec?'🔒 security':'', e.isProb?'⚠ artifact':''].filter(Boolean).join(' · ');
    const labels=e.labels&&e.labels.length ? e.labels.map(l=>`\`${mdCell(l)}\``).join(', ') : '—';
    return `| [${mdText(e.title)}](./${e.file}) | \`${e.branch}\` | ${e.type} | ${e.change} | ${ageCell(e.branch)} | ${labels} | ${notes} |`;
  }),
  ``
].join('\n');
fs.writeFileSync(path.join(REPORTS_DIR,'index.md'),idx);
console.log(`   wrote ${index.length} report(s) + index.md`);
console.log(`   ${prs.length} branches, ${updTotal} updates`+(secCount?`, ${secCount} security`:'')+(flagged?`, ${flagged} with artifact/lockfile problems`:''));
