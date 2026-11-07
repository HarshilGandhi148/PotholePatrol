import type {PotholeReport} from '../types';
export type QueueView='active'|'all'|'history';
export function queueReports(reports:PotholeReport[],view:QueueView){return reports.filter(r=>view==='all'||(view==='active'?r.status!=='Fixed':r.status==='Fixed')).sort((a,b)=>b.priorityScore-a.priorityScore||a.id.localeCompare(b.id))}
