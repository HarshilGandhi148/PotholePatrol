import type { Agency,PotholeReport } from '../types';
import {calculatePriority} from '../services/priorityService';
export const agencies:Agency[]=[
 {id:'indy',name:'Indianapolis Department of Public Works',jurisdiction:'Indianapolis · unverified',reportingChannel:'Local preparation only',supportedSubmissionTypes:[]},
 {id:'fishers',name:'City of Fishers',jurisdiction:'Fishers · unverified',reportingChannel:'Local preparation only',supportedSubmissionTypes:[]},
 {id:'indot',name:'Indiana Department of Transportation',jurisdiction:'State jurisdiction · unverified',reportingChannel:'Local preparation only',supportedSubmissionTypes:[]},
 {id:'unknown',name:'Other / Unknown jurisdiction',jurisdiction:'Ownership requires verification',reportingChannel:'Local preparation only',supportedSubmissionTypes:[]}
];
// Explicit roadway points, not randomly scattered coordinates. All locations are approximate.
const roads:[string,number,number,'indy'|'fishers'][]=[
 ['Broad Ripple Ave',39.8692,-86.1414,'indy'],['Broad Ripple Ave',39.8693,-86.1378,'indy'],['N College Ave near Broad Ripple',39.8670,-86.1458,'indy'],['N College Ave near E 62nd St',39.8673,-86.1458,'indy'],
 ['N Meridian St near E 38th St',39.8252,-86.1578,'indy'],['N Meridian St near E 46th St',39.8404,-86.1577,'indy'],['N Meridian St near E 56th St',39.8555,-86.1576,'indy'],['N Meridian St near E 64th St',39.8740,-86.1576,'indy'],
 ['N Keystone Ave near E 52nd St',39.8476,-86.1213,'indy'],['N Keystone Ave near E 54th St',39.8517,-86.1213,'indy'],['N Keystone Ave near E 62nd St',39.8689,-86.1214,'indy'],['N Keystone Ave near E 71st St',39.8839,-86.1214,'indy'],
 ['E 82nd St west of Allisonville Rd',39.9068,-86.0825,'indy'],['E 82nd St east of Allisonville Rd',39.9068,-86.0720,'indy'],['E 82nd St near Dean Rd',39.9068,-86.0652,'indy'],['E 82nd St near Clearwater',39.9068,-86.1040,'indy'],
 ['Allisonville Rd near E 86th St',39.9138,-86.0742,'indy'],['Allisonville Rd near E 91st St',39.9215,-86.0680,'indy'],['E 96th St near Allisonville Rd',39.9279,-86.0660,'indy'],['E 96th St near Masters Rd',39.9279,-86.0528,'indy'],
 ['N Meridian St downtown',39.7760,-86.1580,'indy'],['N Delaware St downtown',39.7740,-86.1540,'indy'],['E Ohio St downtown',39.7694,-86.1510,'indy'],['E Washington St downtown',39.7670,-86.1480,'indy'],
 ['E 116th St near Lantern Rd',39.9570,-86.0145,'fishers'],['E 116th St west of Lantern Rd',39.9570,-86.0200,'fishers'],['E 116th St near Municipal Dr',39.9570,-86.0080,'fishers'],['E 116th St near Fishers Pointe',39.9570,-86.0270,'fishers'],
 ['Allisonville Rd near E 116th St',39.9570,-86.0410,'fishers'],['Allisonville Rd south of E 116th St',39.9500,-86.0440,'fishers'],['Allisonville Rd north of E 116th St',39.9630,-86.0380,'fishers'],['Allisonville Rd near E 126th St',39.9748,-86.0310,'fishers'],
 ['Lantern Rd south of E 116th St',39.9500,-86.0140,'fishers'],['Lantern Rd north of E 116th St',39.9630,-86.0140,'fishers'],['Lantern Rd near E 126th St',39.9750,-86.0140,'fishers'],['E 116th St near Fishers District',39.9570,-85.9700,'fishers'],
 ['E 116th St near IKEA Way',39.9570,-85.9780,'fishers'],['E 116th St east of I-69',39.9570,-85.9840,'fishers'],['E 96th St near Hague Rd',39.9280,-86.0320,'fishers'],['E 96th St east of I-69',39.9280,-86.0060,'fishers'],
 ['E 131st St near Lantern Rd',39.9850,-86.0140,'fishers'],['E 131st St near Cumberland Rd',39.9850,-85.9940,'fishers'],['E 131st St near Promise Rd',39.9850,-85.9700,'fishers'],['E 126th St near Cumberland Rd',39.9750,-85.9940,'fishers']
];
export const sampleReports:PotholeReport[]=roads.map(([road,latitude,longitude,agencyId],i)=>{
 const r:PotholeReport={id:`DEMO-INDY-${1040+i}`,address:`Near ${road}, ${agencyId==='indy'?'Indianapolis':'Fishers'} — Approximate Demo Location`,latitude,longitude,severity:(['High','Medium','Low'] as const)[i%3],status:(['Open','Open','Acknowledged','Fixed'] as const)[i%4],description:'Synthetic road damage record. Approximate location and illustrated sample evidence; field inspection required.',agencyId,reportCount:1+i%6,createdAt:new Date(Date.UTC(2026,9,21+i%16)).toISOString(),updatedAt:'2026-11-07T12:00:00Z',priorityScore:0,images:['/sample-road.svg'],observations:Array.from({length:1+i%6},(_,j)=>new Date(Date.UTC(2026,10,1+j)).toISOString()),source:'demo',demoRegion:agencyId,damageType:(['pothole','longitudinal_crack','transverse_crack','alligator_crack'] as const)[i%4],safetyHazard:i%5===0};
 return {...r,priorityScore:calculatePriority(r).total};
});
const key='pothole-patrol-v2';
const legacyKey='pothole-patrol-v1';
interface Stored {version:2; demo:PotholeReport[]; personal:PotholeReport[]}
function stored(reports:PotholeReport[]):Stored{return {version:2,demo:reports.filter(r=>r.source==='demo'),personal:reports.filter(r=>r.source!=='demo')}}
export function migrateLegacy(reports:PotholeReport[]){return [...reports.filter(r=>r.source!=='demo').map(r=>({...r,agencyId:agencies.some(a=>a.id===r.agencyId)?r.agencyId:'unknown'})),...sampleReports]}
export const mockReportsAdapter={
 async list(){let saved:string|null;try{saved=localStorage.getItem(key)}catch{return sampleReports;}if(saved){const value=JSON.parse(saved) as Stored;if(value.version!==2||!Array.isArray(value.demo)||!Array.isArray(value.personal))throw Error('Invalid saved report data');return [...value.personal,...value.demo]}
 const legacy=localStorage.getItem(legacyKey);const reports=legacy?migrateLegacy(JSON.parse(legacy) as PotholeReport[]):sampleReports;if(legacy){try{await this.persist(reports)}catch{/* Legacy key remains intact; reports are available this session. */}}return reports},
 async persist(reports:PotholeReport[]){localStorage.setItem(key,JSON.stringify(stored(reports.map(r=>({...r,images:r.images.filter(u=>!u.startsWith('blob:'))})))));},
 async reset(current?:PotholeReport[]){const personal=(current||await this.list()).filter(r=>r.source!=='demo');const next=[...personal,...sampleReports];await this.persist(next);return next}
};
