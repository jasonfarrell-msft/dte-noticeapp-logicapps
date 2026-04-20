// Inline JS code executed by the Logic App's "Execute JavaScript Code" action.
// This file is read at build time by _build_scanner.js and embedded into the workflow JSON.
var html = workflowContext.actions['Get_RootHtml'].outputs.body;
var cacheStatus = workflowContext.actions['Read_Discovery_Cache'].outputs.statusCode;
var cacheBody = (cacheStatus === 200) ? workflowContext.actions['Read_Discovery_Cache'].outputs.body : null;
var inputs = workflowContext.actions['Compose_Discovery_Inputs'].outputs;
var label = inputs.dropdownLabel;
var model = inputs.parserModel;
var siteId = inputs.siteId;
var now = new Date().toISOString();

function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function findUlAfterLabel(html, label) {
  var idx = html.toLowerCase().indexOf(label.toLowerCase());
  if (idx < 0) return null;
  var after = html.substring(idx + label.length);
  var ul = after.match(/<ul[^>]*>([\s\S]*?)<\/ul>/i);
  return ul ? ul[1] : null;
}

function extractHtmlTableV1(ulInner) {
  var items = [], seen = {};
  var re = /<li[^>]*>\s*<a[^>]*href=['"]([^'"]+)['"][^>]*>([\s\S]*?)<\/a>/gi;
  var m;
  while ((m = re.exec(ulInner)) !== null) {
    var href = m[1];
    var text = m[2].replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
    var codeM = href.match(/[?&]Pipe=([A-Za-z0-9]+)/i);
    if (!codeM) continue;
    var code = codeM[1].toUpperCase();
    if (seen[code]) continue;
    seen[code] = true;
    var name = text.replace(/\s*\([^)]*\)\s*$/, '').trim();
    items.push({ code: code, name: name, value: null });
  }
  return items;
}

function extractJsonGridV1(ulInner) {
  var items = [], seen = {};
  var re = /onclick=["']changeAsset\(\s*['"](\d+)['"]\s*,\s*['"]([^'"]+)['"]\s*\)/gi;
  var m;
  while ((m = re.exec(ulInner)) !== null) {
    var value = m[1];
    var fullText = m[2];
    var codeM = fullText.match(/\(([A-Z0-9]+)\)\s*$/);
    if (!codeM) continue;
    var code = codeM[1];
    if (seen[code]) continue;
    seen[code] = true;
    var name = fullText.replace(/\s*\([^)]*\)\s*$/, '').trim();
    items.push({ code: code, name: name, value: value });
  }
  return items;
}

var ulInner = findUlAfterLabel(html, label);
var discovered = [];
var discoveryError = null;
if (!ulInner) {
  discoveryError = 'label-or-ul-not-found';
} else if (model === 'html-table-v1') {
  discovered = extractHtmlTableV1(ulInner);
} else if (model === 'json-grid-v1') {
  discovered = extractJsonGridV1(ulInner);
} else {
  discoveryError = 'unknown-parser-model:' + model;
}

var cached = null;
if (cacheBody) {
  try { cached = (typeof cacheBody === 'string') ? JSON.parse(cacheBody) : cacheBody; }
  catch (e) { cached = null; }
}
var cachedCount = (cached && cached.businessUnits) ? cached.businessUnits.length : 0;
var cachedBUs = (cached && cached.businessUnits) ? cached.businessUnits : [];

var useLive = false, reason = '';
if (discovered.length === 0) {
  reason = 'discovered-zero';
} else if (cachedCount > 0 && discovered.length < Math.ceil(cachedCount * 0.5)) {
  reason = 'discovered-below-50pct-of-cache';
} else {
  useLive = true;
  reason = (cachedCount === 0) ? 'first-run' : 'sanity-pass';
}

var finalBUs = useLive ? discovered : cachedBUs;
var source = useLive ? 'live' : (cachedBUs.length > 0 ? 'cache' : 'none');

return {
  siteId: siteId,
  parserModel: model,
  source: source,
  reason: reason,
  discoveryError: discoveryError,
  discoveredCount: discovered.length,
  cachedCount: cachedCount,
  count: finalBUs.length,
  discoveredAt: now,
  businessUnits: finalBUs
};
