import type {AnalysisResult,DamageType,DetectionResult,DetectionSource,MediaAsset} from '../types';
const classes:DamageType[]=['pothole','longitudinal_crack','transverse_crack','alligator_crack'];
const sources:DetectionSource[]=['ios_coreml','desktop','backend','demo'];
function object(value:unknown):Record<string,unknown>{if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Expected a JSON object.');return value as Record<string,unknown>}
function number(value:unknown,min:number,max:number,label:string){if(typeof value!=='number'||!Number.isFinite(value)||value<min||value>max)throw Error(`Invalid ${label}. Expected ${min} to ${max}.`);return value}
export function normalizeDetections(input:unknown):AnalysisResult {
 const root=object(input);if(root.schemaVersion!==1)throw Error('Expected schemaVersion: 1.');
 if(!sources.includes(root.source as DetectionSource))throw Error('Unsupported detection source.');
 if(root.sessionId!==undefined&&(typeof root.sessionId!=='string'||!root.sessionId.trim()))throw Error('Invalid sessionId.');
 if(!Array.isArray(root.detections)||root.detections.length>1000)throw Error('Expected detections array (maximum 1,000 candidates).');
 const ids=new Set<string>();
 const detections=root.detections.map((value):DetectionResult=>{
  const r=object(value);if(typeof r.id!=='string'||!r.id.trim()||ids.has(r.id))throw Error('Detection IDs must be nonempty and unique.');ids.add(r.id);
  if(!classes.includes(r.className as DamageType))throw Error(`Unsupported damage class for ${r.id}.`);
  if(typeof r.capturedAt!=='string'||!/^\d{4}-\d\d-\d\dT.*(Z|[+-]\d\d:\d\d)$/.test(r.capturedAt)||!Number.isFinite(Date.parse(r.capturedAt)))throw Error(`Invalid capturedAt for ${r.id}; include timezone.`);
  const detection:DetectionResult={detectionId:r.id,source:root.source as DetectionSource,className:r.className as DamageType,capturedAt:r.capturedAt,sessionId:root.sessionId as string|undefined,sourceMediaType:r.frameTimestampMs==null?'photo':'video'};
  if(r.confidence!=null)detection.confidence=number(r.confidence,0,1,'confidence');
  if(r.frameTimestampMs!=null)detection.frameTimestampMs=number(r.frameTimestampMs,0,Number.MAX_SAFE_INTEGER,'frameTimestampMs');
  if(r.boundingBox!=null){const b=object(r.boundingBox);const x=number(b.x,0,1,'box x'),y=number(b.y,0,1,'box y'),width=number(b.width,Number.EPSILON,1,'box width'),height=number(b.height,Number.EPSILON,1,'box height');if(x+width>1.000001||y+height>1.000001)throw Error('Bounding box must fit within the image.');detection.boundingBox={x,y,width,height}}
  if(r.location!=null){const l=object(r.location);detection.location={latitude:number(l.latitude,-90,90,'latitude'),longitude:number(l.longitude,-180,180,'longitude')};if(l.accuracyMeters!=null)detection.location.accuracyMeters=number(l.accuracyMeters,0,Number.MAX_SAFE_INTEGER,'accuracyMeters')}
  if(r.imageUrl!=null){if(typeof r.imageUrl!=='string')throw Error('imageUrl must be a URL or null.');let url:URL;try{url=new URL(r.imageUrl)}catch{throw Error('imageUrl must be an absolute HTTPS URL.')}if(url.protocol!=='https:')throw Error('Only HTTPS evidence URLs are accepted.');detection.imageUrl=url.href}
  return detection;
 });
 return {demo:root.source==='demo',detections,possibleDuplicates:[]};
}
async function preview(media:MediaAsset):Promise<AnalysisResult>{const sessionId=crypto.randomUUID();return {demo:true,detections:Array.from({length:media.type==='video'?3:1},(_,i)=>({detectionId:`sample-${i}`,source:'demo' as const,className:(['pothole','longitudinal_crack','pothole'] as const)[i],capturedAt:new Date().toISOString(),sessionId,sourceMediaType:media.type,confidence:.87-i*.08,frameTimestampMs:media.type==='video'?2400+i*3100:undefined,severitySuggestion:'Medium' as const})),suggestedSeverity:'Medium',suggestedDescription:'Sample observation: road damage requiring human inspection.',possibleDuplicates:['DEMO-INDY-1040']}}
// Reserved configuration only. No HTTP endpoint exists or is invoked until its contract is agreed.
export const configuredApiBaseUrl=import.meta.env.VITE_API_BASE_URL as string|undefined;
export const detectionService={analyzePhoto:preview,analyzeVideo:preview,getResults:preview,normalize:normalizeDetections,async importFile(file:File){if(file.size>5*1024*1024)throw Error('JSON file exceeds 5 MB.');let input:unknown;try{input=JSON.parse(await file.text())}catch{throw Error('Invalid JSON file. Check JSON syntax.')}return normalizeDetections(input)}};
