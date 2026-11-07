import {useEffect,useRef,useState} from 'react';
import type {ReactNode} from 'react';
import type {Agency,AnalysisResult,DetectionResult,MediaAsset,PotholeReport,ReportDraft} from '../types';
import {reportsService,updateReport} from '../services/reportsService';
import {agencyService} from '../services/agencyService';
import {Context} from './context';
const empty:ReportDraft={address:'',latitude:'',longitude:'',severity:'Medium',description:'',agencyId:'unknown',safetyHazard:false};
function useStore(){const retainedMedia=useRef(new Set<string>());const [reports,setReports]=useState<PotholeReport[]>([]);const [agencies,setAgencies]=useState<Agency[]>([]);const [error,setError]=useState('');const [loading,setLoading]=useState(true);const [media,setMedia]=useState<MediaAsset>();const [draft,setDraft]=useState(empty);const [analysis,setAnalysis]=useState<AnalysisResult>();const [candidate,setCandidate]=useState<DetectionResult>();
useEffect(()=>{Promise.all([reportsService.list(),agencyService.list()]).then(([r,a])=>{setReports(r);setAgencies(a)}).catch(()=>setError('Unable to load demonstration reports. Reload to retry.')).finally(()=>setLoading(false))},[]);
useEffect(()=>()=>{if(media&&!retainedMedia.current.has(media.url))URL.revokeObjectURL(media.url)},[media]);
async function persist(next:PotholeReport[]){setReports(next);try{await reportsService.save(next)}catch{setError('Changes are available this session, but device storage is unavailable.')}}
return {reports,agencies,error,loading,media,setMedia,draft,setDraft,analysis,setAnalysis,candidate,setCandidate,clearDraft:()=>{setDraft(empty);setMedia(undefined);setAnalysis(undefined);setCandidate(undefined)},add:(r:PotholeReport)=>{r.images.filter(url=>url.startsWith('blob:')).forEach(url=>retainedMedia.current.add(url));return persist([r,...reports])},update:(id:string,p:Partial<PotholeReport>)=>persist(reports.map(r=>r.id===id?updateReport(r,p):r)),reset:async()=>{try{setReports(await reportsService.reset(reports));setError('')}catch{setError('Unable to reset demo data. Your local reports are unchanged.')}}}}
export type AppStore=ReturnType<typeof useStore>;
export function StoreProvider({children}:{children:ReactNode}){const store=useStore();return <Context.Provider value={store}>{children}</Context.Provider>}
