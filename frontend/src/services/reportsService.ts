import {mockReportsAdapter} from '../adapters/mock';
import {calculatePriority} from './priorityService';
import type {PotholeReport} from '../types';
export const reportsService={list:async()=> (await mockReportsAdapter.list()).map(r=>({...r,priorityScore:calculatePriority(r).total})),get:async(id:string)=>(await mockReportsAdapter.list()).find(r=>r.id===id),save:mockReportsAdapter.persist,reset:mockReportsAdapter.reset};
export function updateReport(report:PotholeReport,patch:Partial<PotholeReport>){const updated={...report,...patch,updatedAt:new Date().toISOString()};return {...updated,priorityScore:calculatePriority(updated).total}}
