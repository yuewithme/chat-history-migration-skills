'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function arg(name, position) { const i=process.argv.indexOf(name); return i>=0?process.argv[i+1]:process.argv[position]; }
const rawDir=path.resolve(arg('--raw',2)||'');
const finalDir=path.resolve(arg('--final',3)||'');
if (!rawDir || !finalDir) throw new Error('Usage: node verify-backup.js --raw <raw-dir> --final <candidate-dir>');
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const readJson=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const manifest=readJson(path.join(finalDir,'attachments','manifest.json'));
const report=readJson(path.join(finalDir,'metadata','export-report.json'));

function jsonFiles(dir) {
  const out=[];
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir,{withFileTypes:true})) {
    const p=path.join(dir,entry.name);
    if (entry.isDirectory()) out.push(...jsonFiles(p)); else if (entry.name.endsWith('.json')) out.push(p);
  }
  return out;
}
const rawConversationFiles=jsonFiles(path.join(rawDir,'json')).concat(jsonFiles(path.join(rawDir,'projects')).filter(p=>path.basename(path.dirname(p))==='json'));
const finalConversationFiles=jsonFiles(path.join(finalDir,'conversations'));
const rawById=new Map();
const rawParseFailures=[];
for (const p of rawConversationFiles) {
  try { const j=readJson(p); const id=j.id||j.conversation_id; if (id) rawById.set(id,p); }
  catch(e) { rawParseFailures.push({file:path.relative(rawDir,p),error:e.message}); }
}
const finalIds=new Set(), zeroByte=[], mismatches=[], duplicateIds=[], finalParseFailures=[];
for (const p of finalConversationFiles) {
  if (fs.statSync(p).size===0) zeroByte.push(path.relative(finalDir,p));
  try {
    const j=readJson(p), id=j.id||j.conversation_id;
    if (finalIds.has(id)) duplicateIds.push(id); else finalIds.add(id);
    const raw=rawById.get(id); if (!raw||hash(raw)!==hash(p)) mismatches.push(id||path.relative(finalDir,p));
  } catch(e) { finalParseFailures.push({file:path.relative(finalDir,p),error:e.message}); }
}
const badHashes=[], missingPaths=[], manifestIds=new Set();
for (const item of manifest.files) {
  const p=path.join(finalDir,item.stored_path);
  if (!fs.existsSync(p)) missingPaths.push(item.stored_path); else if (hash(p)!==item.sha256) badHashes.push(item.stored_path);
  for (const id of item.file_ids||[]) manifestIds.add(id);
}
const referenced=new Set();
for (const p of rawById.values()) for (const m of fs.readFileSync(p,'utf8').matchAll(/(?:sediment|file-service):\/\/(file_[A-Za-z0-9_]+)/g)) referenced.add(m[1]);
const projectIndex=readJsonIf(path.join(rawDir,'projects','project-index.json'),[]);
for (const project of projectIndex) for (const f of project.files||[]) if (f.file_id||f.id) referenced.add(f.file_id||f.id);
function readJsonIf(p,fallback){try{return readJson(p)}catch{return fallback}}
const excluded=new Set((report.excluded_generated_files||[]).map(x=>x.file_id));
const failed=new Set((report.failed_files||[]).map(x=>x.file_id));
const unaccounted=[...referenced].filter(id=>!manifestIds.has(id)&&!excluded.has(id)&&!failed.has(id));
const forbidden=[], jwtHits=[];
function walk(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);if(e.isDirectory())walk(p);else{
  if(/\.(md|html|jsonl|zip)$/i.test(e.name))forbidden.push(path.relative(finalDir,p));
  if(/\.(json|txt|js)$/i.test(e.name)&&/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/.test(fs.readFileSync(p,'utf8')))jwtHits.push(path.relative(finalDir,p));
}}}
walk(finalDir);
const result={passed:false,raw_conversations:rawById.size,final_conversations:finalIds.size,raw_parse_failures:rawParseFailures,
  final_parse_failures:finalParseFailures,zero_byte_json:zeroByte,duplicate_conversation_ids:duplicateIds,json_hash_mismatches:mismatches,
  manifest_files:manifest.files.length,missing_manifest_files:missingPaths,bad_manifest_hashes:badHashes,referenced_file_ids:referenced.size,
  unaccounted_references:unaccounted,failed_files:report.failed_files||[],failed_conversations:report.failed_conversations||[],forbidden_formats:forbidden,jwt_hits:jwtHits};
result.passed=result.raw_conversations===result.final_conversations&&![rawParseFailures,finalParseFailures,zeroByte,duplicateIds,mismatches,missingPaths,badHashes,unaccounted,forbidden,jwtHits,result.failed_files,result.failed_conversations].some(a=>a.length);
fs.mkdirSync(path.join(finalDir,'metadata'),{recursive:true});
fs.writeFileSync(path.join(finalDir,'metadata','final-verification.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));
if(!result.passed)process.exitCode=1;
