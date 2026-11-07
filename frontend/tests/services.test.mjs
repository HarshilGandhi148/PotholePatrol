import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'vite';
// Use Vite's existing TS loader; no additional test framework or packages.
const server=await createServer({server:{middlewareMode:true,hmr:false},appType:'custom'});
after(()=>server.close());
const {normalizeDetections,detectionService}=await server.ssrLoadModule('/src/services/detectionService.ts');
const {sampleReports,mockReportsAdapter,migrateLegacy}=await server.ssrLoadModule('/src/adapters/mock.ts');
const {reportsService}=await server.ssrLoadModule('/src/services/reportsService.ts');
const {queueReports}=await server.ssrLoadModule('/src/services/queueService.ts');
const {calculatePriority}=await server.ssrLoadModule('/src/services/priorityService.ts');
const fixture=JSON.parse((await readFile(new URL('../examples/detection-results.json',import.meta.url),'utf8')).replace(/^\uFEFF/,''));
const memory=new Map();globalThis.localStorage={getItem:key=>memory.get(key)??null,setItem:(key,value)=>memory.set(key,value),removeItem:key=>memory.delete(key)};

test('active queue excludes a fixed report even when its score is highest',()=>{
 const reports=[{...sampleReports[0],id:'fixed',status:'Fixed',priorityScore:95},{...sampleReports[1],id:'open',status:'Open',priorityScore:50},{...sampleReports[2],id:'ack',status:'Acknowledged',priorityScore:70}];
 assert.deepEqual(queueReports(reports,'active').map(r=>r.id),['ack','open']);
 assert.equal(queueReports(reports,'history')[0].id,'fixed');assert.equal(queueReports(reports,'all').length,3);
});
test('seed locations are explicit, unique and confined to the metro demo area',()=>{
 assert.equal(sampleReports.length,44);assert.equal(new Set(sampleReports.map(r=>r.id)).size,44);
 assert.equal(sampleReports.filter(r=>r.demoRegion==='fishers').length,20);
 for(const r of sampleReports){assert.ok(r.latitude>39.75&&r.latitude<40);assert.ok(r.longitude>-86.18&&r.longitude<-85.95);assert.match(r.address,/Approximate Demo Location/);assert.equal(r.source,'demo')}
});
test('migration removes legacy demo records and preserves personal reports',()=>{
 const local={...sampleReports[0],id:'LOCAL-old',source:'local',agencyId:'lafayette'};
 const migrated=migrateLegacy([{...sampleReports[1],id:'PP-1040'},local]);
 assert.equal(migrated.length,45);assert.equal(migrated[0].id,'LOCAL-old');assert.equal(migrated[0].agencyId,'unknown');assert.ok(!migrated.some(r=>r.id==='PP-1040'));
});
test('persistence separates sources, strips temporary URLs, and reset keeps personal reports',async()=>{
 memory.clear();memory.set('pothole-patrol-v1',JSON.stringify([{...sampleReports[1],id:'PP-1040'},{...sampleReports[0],id:'LOCAL-preserve',source:'local'}]));
 const migrated=await mockReportsAdapter.list();assert.equal(migrated.length,45);assert.ok(memory.has('pothole-patrol-v1'));
 await mockReportsAdapter.persist([{...sampleReports[0],status:'Fixed'},{...sampleReports[0],id:'IMPORTED-preserve',source:'imported',images:['blob:temporary','https://example.org/evidence.jpg']}]);
 const raw=JSON.parse(memory.get('pothole-patrol-v2'));assert.equal(raw.personal.length,1);assert.equal(raw.demo.length,1);
 const saved=await mockReportsAdapter.list();assert.deepEqual(saved[0].images,['https://example.org/evidence.jpg']);
 const reset=await mockReportsAdapter.reset();assert.equal(reset.length,45);assert.ok(reset.some(r=>r.id==='IMPORTED-preserve'));assert.equal(reset.find(r=>r.id===sampleReports[0].id).status,sampleReports[0].status);
});
test('normalization preserves actual model fields without fabricating GPS or severity',()=>{
 const result=normalizeDetections(fixture);assert.equal(result.demo,false);assert.equal(result.detections.length,2);
 const d=result.detections[0];assert.equal(d.className,'pothole');assert.equal(d.confidence,.87);assert.equal(d.frameTimestampMs,2400);assert.equal(d.location,undefined);assert.equal(d.severitySuggestion,undefined);assert.equal(d.imageUrl,undefined);assert.equal(d.source,'ios_coreml');
 assert.equal(normalizeDetections({...fixture,detections:[]}).detections.length,0);
});
test('optional GPS and accuracy survive normalization',()=>{
 const d={...fixture.detections[0],location:{latitude:39.957,longitude:-86.0145,accuracyMeters:12}};
 assert.deepEqual(normalizeDetections({...fixture,detections:[d]}).detections[0].location,d.location);
});
test('malformed model records are rejected rather than partially imported',()=>{
 const d=fixture.detections[0];
 for(const patch of [{confidence:87},{className:'unknown'},{capturedAt:'yesterday'},{capturedAt:'2026-11-07T12:15:00'},{location:{latitude:91,longitude:0}},{boundingBox:{x:.9,y:0,width:.2,height:.2}},{imageUrl:'javascript:alert(1)'},{frameTimestampMs:-1}])assert.throws(()=>normalizeDetections({...fixture,detections:[{...d,...patch}]}));
 assert.throws(()=>normalizeDetections({...fixture,schemaVersion:2}));assert.throws(()=>normalizeDetections({...fixture,detections:[d,d]}));assert.throws(()=>normalizeDetections(null));
});
test('invalid JSON and oversized imports return actionable errors',async()=>{
 await assert.rejects(()=>detectionService.importFile(new File(['{bad'],'invalid.json')),/Invalid JSON/);
 await assert.rejects(()=>detectionService.importFile({size:6*1024*1024}),/5 MB/);
});
test('priority is deterministic with an explicit clock and confidence has no effect',()=>{
 const r=sampleReports[0];const now=Date.parse('2026-11-07T17:00:00Z');assert.deepEqual(calculatePriority(r,now),calculatePriority({...r,confidence:1},now));
 const score=calculatePriority(r,now);assert.equal(score.total,score.severityContribution+score.observationContribution+score.safetyContribution+score.ageContribution);assert.ok(score.total<=95);
});

test('reports service reset preserves current personal reports through its public adapter boundary',async()=>{
 memory.clear();const personal={...sampleReports[0],id:'LOCAL-current',source:'local'};
 const reports=await reportsService.reset([personal,{...sampleReports[0],status:'Fixed'}]);
 assert.equal(reports.length,45);assert.ok(reports.some(r=>r.id==='LOCAL-current'));assert.equal((await reportsService.list()).length,45);
});
