import type { PotholeReport, PriorityScore } from '../types';
export function calculatePriority(r:Pick<PotholeReport,'severity'|'reportCount'|'safetyHazard'|'createdAt'>, now=Date.now()):PriorityScore {
 const severityContribution={Low:10,Medium:25,High:40}[r.severity];
 const observationContribution=Math.min(20,Math.max(0,r.reportCount-1)*5);
 const safetyContribution=r.safetyHazard?20:0;
 const ageContribution=Math.min(15,Math.max(0,Math.floor((now-Date.parse(r.createdAt))/86400000)));
 return {total:severityContribution+observationContribution+safetyContribution+ageContribution,severityContribution,observationContribution,safetyContribution,ageContribution};
}
