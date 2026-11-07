import {createContext,useContext,useEffect,useState} from 'react';
import type {ReactNode} from 'react';
import type {Agency,MediaAsset,PotholeReport,ReportDraft} from '../types';
import {reportsService,updateReport} from '../services/reportsService';
import {agencyService} from '../services/agencyService';
const empty:ReportDraft={address:'',latitude:'',longitude:'',severity:'High',description:'',agencyId:'lafayette',safetyHazard:false};
function useStore(){const [reports,setReports]=useState<PotholeReport[]>([]);const [agencies,setAgencies]=useState<Agency[]>([]);const [error,setError]=useState('');const [loading,setLoading]=useState(true);const [media,setMedia]=useState<MediaAsset>();const [draft,setDraft]=useState(empty);
useEffect(()=>{Promise.all([reportsService.list(),agencyService.list()]).then(([r,a])=>{setReports(r);setAgencies(a)}).catch(()=>setError('Unable to load demonstration reports. Reload to retry.')).finally(()=>setLoading(false))},[]);
useEffect(()=>()=>{if(media)URL.revokeObjectURL(media.url)},[media]);
async function persist(next:PotholeReport[]){setReports(next);try{await reportsService.save(next)}catch{setError('Changes are available this session, but device storage is unavailable.')}}
return {reports,agencies,error,loading,media,setMedia,draft,setDraft,clearDraft:()=>{setDraft(empty);setMedia(undefined)},add:(r:PotholeReport)=>persist([r,...reports]),update:(id:string,p:Partial<PotholeReport>)=>persist(reports.map(r=>r.id===id?updateReport(r,p):r)),reset:async()=>{setReports(await reportsService.reset())}}}
const Context=createContext<ReturnType<typeof useStore>|null>(null);
export function StoreProvider({children}:{children:ReactNode}){const store=useStore();return <Context.Provider value={store}>{children}</Context.Provider>}
export function useApp(){return useContext(Context)!}
